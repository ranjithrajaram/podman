#!/bin/bash
# rootlessport-sustained-reproducer.sh
#
# Low-CPU, long-running variant of the rootlessport EAGAIN reproducer.
#
# Problem with the high-throughput reproducer:
#   The Python load generator runs in a tight loop, consuming 40-50% CPU.
#   That makes it impractical as a long-running background process.
#
# Key insight — goroutines are cheap to keep alive:
#   Each TCP connection through rootlessport holds two goroutines (splice
#   in + splice out) blocked in poll(2)/waitForFd, consuming no CPU.
#   We do NOT need a high request rate to create goroutine-pool pressure;
#   we need many CONNECTIONS OPEN simultaneously.
#
#   Strategy:
#     1. Maintain N persistent connections to Envoy (goroutines alive, idle).
#     2. Every BURST_INTERVAL seconds, fire a request on ALL of them at once
#        (synchronized burst).  All N goroutine-pairs wake simultaneously,
#        competing for Go's scheduler — this is where EAGAIN lag appears.
#     3. Foreground curl loop probes the direct backend at a human-readable
#        pace and prints each response time.
#
# Pod layout:
#   host:ENVOY_PORT  ──► rootlessport ──► envoy:8080 ──► python-app:8081
#   (sustained background, low CPU)      [pod-local after Envoy, no rootlessport]
#
#   host:DIRECT_PORT ──► rootlessport ──► python-app:8081
#   (curl probe — latency observed here)
#
# Usage:
#   bash rootlessport-sustained-reproducer.sh [OPTIONS]
#
# Options:
#   --envoy-port   N   Host port → Envoy (default: 18080)
#   --direct-port  N   Host port → Python app direct (default: 18081)
#   --conns        N   Persistent connections to Envoy (default: 48)
#   --rate         N   Max requests per second per connection (default: 5)
#                      Total Envoy req/s = conns × rate.  Controls CPU:
#                        --rate 2  → low    (~10% CPU, may not trigger bug)
#                        --rate 5  → medium (~20% CPU, recommended)
#                        --rate 10 → high   (~35% CPU, reliably triggers bug)
#                        --rate 0  → unlimited tight loop (original behaviour)
#   --probe-every  S   Seconds between curl probes (default: 3)
#   --body-size    B   Response bytes per request (default: 131072 = 128 KB)
#   --duration     S   Total run time in seconds, 0 = run until Ctrl+C (default: 0)
#   --strace           Attach strace to rootlessport and print EAGAIN→resume
#                      gaps directly to the console as they occur.
#                      Does NOT require root on owned processes (kernel ptrace_scope 1).
#   --gap-ms       N   Minimum EAGAIN→resume gap in ms to print (default: 100)
#   --strace-log   F   Also write [STRACE] lines to this file (default: strace-gaps.log
#                      in the script's temp dir). Use - to disable file logging.
#   --no-cleanup       Leave pod running after exit
#
# Requirements: rootless podman, python3, curl
# Optional:     strace (--strace flag)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENVOY_PORT=18080
DIRECT_PORT=18081
CONNS=48            # persistent connections to Envoy — goroutine pressure source
RATE=5              # max req/s per connection (0 = unlimited)
PROBE_EVERY=3       # curl probe interval in seconds
BODY_SIZE=1048576   # 1 MB — 32 EAGAIN events per response with 32 KB Envoy buffer
                    # (matches production: per_connection_buffer_limit_bytes=32768)
DURATION=0          # 0 = run until Ctrl+C
STRACE=0            # attach strace to rootlessport and print EAGAIN gaps
GAP_MS=100          # minimum EAGAIN→resume gap in ms to print
STRACE_LOG=""       # dedicated log file for [STRACE] lines (set after TMPDIR_ROOT is known)
NO_CLEANUP=0

POD_NAME="eagain-sustained-pod"
NETWORK_NAME="eagain-sustained-net"
ENVOY_IMAGE="docker.io/envoyproxy/envoy:v1.29-latest"
PYTHON_IMAGE="docker.io/library/python:3.11-slim"

TMPDIR_ROOT="$(mktemp -d /tmp/eagain-sustained.XXXXXX)"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
step()  { echo -e "\n${YLW}=== $* ===${NC}"; }
ok()    { echo -e "${GRN}[OK]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLU}[INFO]${NC} $*"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --envoy-port)  ENVOY_PORT="$2";  shift 2 ;;
        --direct-port) DIRECT_PORT="$2"; shift 2 ;;
        --conns)       CONNS="$2";       shift 2 ;;
        --rate)        RATE="$2";        shift 2 ;;
        --probe-every) PROBE_EVERY="$2"; shift 2 ;;
        --body-size)   BODY_SIZE="$2";   shift 2 ;;
        --duration)    DURATION="$2";    shift 2 ;;
        --strace)      STRACE=1;          shift   ;;
        --gap-ms)      GAP_MS="$2";       shift 2 ;;
        --strace-log)  STRACE_LOG="$2";   shift 2 ;;
        --no-cleanup)  NO_CLEANUP=1;     shift   ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
BG_PID=""
cleanup() {
    [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null || true
    if [[ "$NO_CLEANUP" -eq 1 ]]; then
        info "Skipping cleanup (--no-cleanup).  Pod: $POD_NAME"
        return
    fi
    step "Cleanup"
    podman pod stop  "$POD_NAME"    2>/dev/null || true
    podman pod rm -f "$POD_NAME"    2>/dev/null || true
    podman network rm "$NETWORK_NAME" 2>/dev/null || true
    rm -rf "$TMPDIR_ROOT"
    ok "Done"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
step "Prerequisites"
# ---------------------------------------------------------------------------
for cmd in podman python3 curl awk; do
    command -v "$cmd" &>/dev/null || { err "$cmd not found"; exit 1; }
done
info "Running as: $(id)"
info "Podman:     $(podman --version)"

# ---------------------------------------------------------------------------
step "Cleanup any previous run"
# ---------------------------------------------------------------------------
podman pod stop  "$POD_NAME"    2>/dev/null || true
podman pod rm -f "$POD_NAME"    2>/dev/null || true
podman network rm "$NETWORK_NAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
step "Create bridge network (required for rootlessport)"
# ---------------------------------------------------------------------------
podman network create --driver bridge "$NETWORK_NAME"
ok "Network: $NETWORK_NAME"

# ---------------------------------------------------------------------------
step "Create pod"
# ---------------------------------------------------------------------------
podman pod create \
    --name    "$POD_NAME" \
    --network "$NETWORK_NAME" \
    --publish "${ENVOY_PORT}:8080" \
    --publish "${DIRECT_PORT}:8081"
ok "Pod created"

# rootlessport starts when the first container runs, not at pod create.
# The check is deferred to after containers start (after readiness wait).

# ---------------------------------------------------------------------------
step "Write Envoy config"
# ---------------------------------------------------------------------------
ENVOY_CFG_DIR="$TMPDIR_ROOT/envoy"
mkdir -p "$ENVOY_CFG_DIR"
cat > "$ENVOY_CFG_DIR/envoy.yaml" <<'ENVOY_EOF'
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    # 32 KB downstream buffer — matches the problematic production configuration.
    # Envoy writes at most 32 KB to the downstream socket before pausing to
    # refill from upstream.  Because the splice pipe is 64 KB, rootlessport
    # hits EAGAIN on *every* 32 KB chunk: the pipe is never fully filled in
    # one shot.  Each EAGAIN parks a goroutine in Go's netpoller.  Under
    # concurrent load the parked goroutines pile up and the scheduler wakeup
    # latency becomes the dominant source of connection delay.
    per_connection_buffer_limit_bytes: 32768
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
          route_config:
            name: local_route
            virtual_hosts:
            - name: backend
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route:
                  cluster: python_app
                  timeout: 0s

  clusters:
  - name: python_app
    connect_timeout: 0.5s
    type: STATIC
    lb_policy: ROUND_ROBIN
    max_requests_per_connection: 1
    load_assignment:
      cluster_name: python_app
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 8081 }

admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: 9901 }
ENVOY_EOF

# ---------------------------------------------------------------------------
step "Start Envoy container"
# ---------------------------------------------------------------------------
podman run -d \
    --name envoy-proxy \
    --pod  "$POD_NAME" \
    --volume "$ENVOY_CFG_DIR:/etc/envoy:ro,z" \
    --entrypoint /usr/local/bin/envoy \
    "$ENVOY_IMAGE" \
    -c /etc/envoy/envoy.yaml --log-level warning
ok "Envoy started"

# ---------------------------------------------------------------------------
step "Write Python app"
# ---------------------------------------------------------------------------
APP_DIR="$TMPDIR_ROOT/app"
mkdir -p "$APP_DIR"
cat > "$APP_DIR/server.py" <<PYEOF
#!/usr/bin/env python3
import os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BODY_SIZE = int(os.environ.get("BODY_SIZE", "${BODY_SIZE}"))
BODY      = b"A" * BODY_SIZE

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(BODY_SIZE))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8081), Handler)
    print(f"Python app: {BODY_SIZE} B/response on :8081", flush=True)
    server.serve_forever()
PYEOF

podman run -d \
    --name python-app \
    --pod  "$POD_NAME" \
    --volume "$APP_DIR:/app:ro,z" \
    --env   "BODY_SIZE=${BODY_SIZE}" \
    "$PYTHON_IMAGE" \
    python3 /app/server.py
ok "Python app started"

# ---------------------------------------------------------------------------
step "Wait for readiness (up to 90 s)"
# ---------------------------------------------------------------------------
READY_ENVOY=0; READY_DIRECT=0
for i in $(seq 1 90); do
    [[ "$READY_ENVOY"  -eq 0 ]] && curl -sf --max-time 2 "http://localhost:${ENVOY_PORT}/"  -o /dev/null 2>/dev/null && READY_ENVOY=1  && ok "Envoy ready"
    [[ "$READY_DIRECT" -eq 0 ]] && curl -sf --max-time 2 "http://localhost:${DIRECT_PORT}/" -o /dev/null 2>/dev/null && READY_DIRECT=1 && ok "Backend direct ready"
    [[ "$READY_ENVOY" -eq 1 && "$READY_DIRECT" -eq 1 ]] && break
    sleep 1
    [[ $(( i % 15 )) -eq 0 ]] && info "  still waiting... ($i s)"
done
[[ "$READY_ENVOY" -eq 0 || "$READY_DIRECT" -eq 0 ]] && { err "Services not ready"; exit 1; }

# ---------------------------------------------------------------------------
step "Verify rootlessport is running"
# ---------------------------------------------------------------------------
# rootlessport starts when the first container in the pod runs.
# Use pgrep -f on the binary path so it matches regardless of comm truncation.
ROOTLESSPORT_PID=""
for i in $(seq 1 10); do
    ROOTLESSPORT_PID=$(pgrep -x rootlessport 2>/dev/null | head -1 || true)
    [[ -n "$ROOTLESSPORT_PID" ]] && break
    sleep 1
done
if [[ -n "$ROOTLESSPORT_PID" ]]; then
    ROOTLESSPORT_EXE=$(readlink -f "/proc/${ROOTLESSPORT_PID}/exe" 2>/dev/null || echo "unknown")
    ok "rootlessport PID $ROOTLESSPORT_PID  ($ROOTLESSPORT_EXE)"
    info "  Binary size: $(ls -lh "$ROOTLESSPORT_EXE" 2>/dev/null | awk '{print $5}')  (patched=3.0M unpatched=3.5M)"
else
    err "rootlessport not found — check 'podman info | grep networkBackend'"
    exit 1
fi

# ---------------------------------------------------------------------------
step "Write low-CPU background load generator"
# ---------------------------------------------------------------------------
# Design: CONNS persistent connections, idle between bursts.
#
# Goroutine lifecycle in rootlessport:
#   connection opens  → 2 goroutines spawned (splice in + splice out)
#   connection idle   → goroutines blocked in poll()/waitForFd — ZERO CPU
#   burst fires       → all goroutines wake simultaneously → scheduler contention
#   connection closes → goroutines exit
#
# By keeping connections alive but sending infrequently we hold the goroutine
# pool at CONNS×2 without burning CPU between bursts.
BG_SCRIPT="$TMPDIR_ROOT/bg_load.py"
cat > "$BG_SCRIPT" <<PYEOF
#!/usr/bin/env python3
"""
Rate-limited continuous load generator for rootlessport EAGAIN reproducer.

Why continuous instead of bursts:
  Scheduler pressure = goroutines in the RUNNABLE state competing for CPUs.
  Goroutines blocked in poll() are NOT in the run queue — they consume zero
  CPU and create zero scheduler pressure.  A burst approach has a 10% duty
  cycle; between bursts rootlessport's scheduler is idle and the curl probe
  sees no delay.

Why rate-limited instead of tight loop:
  A tight loop saturates the CPU of the load generator itself, leaving fewer
  cores for rootlessport to run its goroutines.  Rate limiting spreads the
  same goroutine pressure over time at lower CPU cost.

Mechanism:
  Each worker maintains one persistent HTTP/1.1 connection to Envoy.
  After each response it sleeps for (1/RATE - elapsed) seconds.
  Total Envoy req/s = CONNS * RATE.
  rootlessport holds CONNS*2 goroutines continuously transitioning between
  the run queue and poll, creating sustained scheduler pressure.
"""
import http.client, threading, time, os

HOST       = "localhost"
ENVOY_PORT = ${ENVOY_PORT}
CONNS      = ${CONNS}
RATE       = ${RATE}          # max req/s per connection (0 = unlimited)
MIN_SLEEP  = 1.0 / RATE if RATE > 0 else 0   # seconds per request minimum

done = threading.Event()
total_req  = 0
total_err  = 0
lock       = threading.Lock()

def worker(wid):
    global total_req, total_err
    while not done.is_set():
        try:
            conn = http.client.HTTPConnection(HOST, ENVOY_PORT, timeout=30)
            while not done.is_set():
                t0 = time.monotonic()
                conn.request("GET", "/")
                resp = conn.getresponse()
                resp.read()
                elapsed = time.monotonic() - t0
                with lock:
                    total_req += 1
                # Rate limiting: sleep the remainder of the per-request budget.
                # This keeps CPU proportional to RATE while goroutines in
                # rootlessport remain continuously active.
                if MIN_SLEEP > 0:
                    leftover = MIN_SLEEP - elapsed
                    if leftover > 0:
                        time.sleep(leftover)
        except Exception:
            with lock:
                total_err += 1
            time.sleep(0.5)

def reporter():
    """Print a periodic throughput line so the user can see load is running."""
    prev = 0
    while not done.is_set():
        time.sleep(10)
        with lock:
            cur = total_req
        rate = (cur - prev) / 10
        prev = cur
        print(f"[bg] {rate:.0f} req/s to Envoy:{ENVOY_PORT}  "
              f"total={cur}  errors={total_err}", flush=True)

threads = [threading.Thread(target=worker, args=(i,), daemon=True)
           for i in range(CONNS)]
for t in threads:
    t.start()

threading.Thread(target=reporter, daemon=True).start()

rate_str = f"{RATE} req/s/conn ({CONNS * RATE} req/s total)" if RATE > 0 else "unlimited"
print(f"[bg] {CONNS} connections → Envoy:{ENVOY_PORT}  rate={rate_str}  "
      f"(pid={os.getpid()})", flush=True)

try:
    while True:
        time.sleep(60)
except (KeyboardInterrupt, EOFError):
    pass
finally:
    done.set()
PYEOF

# ---------------------------------------------------------------------------
step "Start background load (low CPU)"
# ---------------------------------------------------------------------------
python3 "$BG_SCRIPT" &
BG_PID=$!
info "Background load PID: $BG_PID"
info "  $CONNS connections × ${RATE} req/s = $((CONNS * RATE)) req/s to Envoy"
info "  Goroutines in rootlessport: ~$((CONNS * 2)) continuously active"
info "  Expected CPU from load generator: ~$(( CONNS * RATE / 10 ))–$(( CONNS * RATE / 5 ))%"

# Give connections time to open and prime
sleep 5

# ---------------------------------------------------------------------------
# Optional: strace EAGAIN gap processor
# ---------------------------------------------------------------------------
STRACE_PID=""
if [[ "$STRACE" -eq 1 ]]; then
    step "Starting strace EAGAIN gap monitor"

    if ! command -v strace &>/dev/null; then
        err "strace not found — install with: sudo dnf install strace"
        STRACE=0
    else
        # Reuse PID already confirmed by the verification step
        RP_PID="$ROOTLESSPORT_PID"
        STRACE_PROC="$TMPDIR_ROOT/strace_proc.py"

        # Set default log path before the heredoc expands ${STRACE_LOG}
        [[ -z "$STRACE_LOG" ]] && STRACE_LOG="$TMPDIR_ROOT/strace-gaps.log"

        # Python processor: reads strace splice output line-by-line,
        # tracks per-fd EAGAIN timestamps, prints gaps > GAP_MS immediately.
        # Pre-filtering with grep --line-buffered keeps stdin volume low so
        # the processor does not slow rootlessport down.
        cat > "$STRACE_PROC" <<PYEOF
#!/usr/bin/env python3
"""
Real-time strace EAGAIN gap processor.

Reads strace -e trace=splice -T -tt output from stdin.
For every source fd that shows EAGAIN followed by a successful splice,
prints the gap — the time the goroutine spent parked in Go's scheduler
(unpatched) or blocked in poll(2) waiting for data (patched).

GAP_MS threshold: only gaps above this value are printed.
Thread-hop detection: if the resume happens on a different OS thread
(pid) than the EAGAIN, it is labelled — this is the signature of Go's
M:N scheduler moving the goroutine to a different OS thread after the
netpoller wakes it.
"""
import sys, re

GAP_MS      = ${GAP_MS}
EAGAIN_RE   = re.compile(r'\[pid\s+(\d+)\]\s+(\d+:\d+:\d+\.\d+)\s+splice\((\d+).*EAGAIN')
RESUME_RE   = re.compile(r'\[pid\s+(\d+)\]\s+(\d+:\d+:\d+\.\d+)\s+splice\((\d+)[^=]+=\s+([1-9]\d*)')

RED   = "\033[0;31m"
YLW   = "\033[1;33m"
GRN   = "\033[0;32m"
NC    = "\033[0m"

LOG_FILE = '${STRACE_LOG}'   # path to dedicated log file, or empty / "-" to disable

def to_sec(ts):
    h, m, rest = ts.split(':')
    return int(h) * 3600 + int(m) * 60 + float(rest)

# Open the strace log file if requested
_logf = None
if LOG_FILE and LOG_FILE != "-":
    try:
        _logf = open(LOG_FILE, "a", buffering=1)
        _logf.write(f"# strace EAGAIN gap log — started {__import__('datetime').datetime.now()}\n")
    except OSError as e:
        print(f"WARNING: cannot open strace log {LOG_FILE}: {e}", file=sys.stderr)

def emit(msg_color, msg_plain):
    # Print coloured line to stdout and plain line to log file.
    print(msg_color, flush=True)
    if _logf:
        _logf.write(msg_plain + "\n")

eagain = {}   # fd -> (time_sec, ts_str, pid_str)

# Track EAGAIN by (srcFd, dstFd) pair — the fill direction is splice(srcFd → dstFd=pipeWrite).
# Matching on both fds avoids false positives where the drain goroutine
# (splice pipe→dstFd) on the same srcFd is mistaken for a resume of the
# fill goroutine.  Pattern: splice(A, NULL, B, NULL, ...) EAGAIN means
# the *fill* of pipe B from source A was blocked.
EAGAIN_PAIR_RE = re.compile(
    r'\[pid\s+(\d+)\]\s+(\d+:\d+:\d+\.\d+)\s+splice\((\d+), NULL, (\d+), NULL.*EAGAIN')
RESUME_PAIR_RE = re.compile(
    r'\[pid\s+(\d+)\]\s+(\d+:\d+:\d+\.\d+)\s+splice\((\d+), NULL, (\d+), NULL[^=]+=\s+([1-9]\d*)')

# eagain keyed by (srcFd, dstFd) pair to match direction
eagain_pair = {}

for line in sys.stdin:
    m = EAGAIN_PAIR_RE.search(line)
    if m:
        pid, ts, src, dst = m.group(1), m.group(2), m.group(3), m.group(4)
        key = (src, dst)
        eagain_pair[key] = (to_sec(ts), ts, pid)
        continue

    m = RESUME_PAIR_RE.search(line)
    if m:
        pid, ts, src, dst = m.group(1), m.group(2), m.group(3), m.group(4)
        key = (src, dst)
        if key in eagain_pair:
            t0, ts0, pid0 = eagain_pair.pop(key)
            gap_ms = (to_sec(ts) - t0) * 1000
            if gap_ms >= GAP_MS:
                # Thread-hop on the SAME direction = genuine Go scheduler rescheduling
                hop_color = f"  {YLW}[thread-hop {pid0}→{pid}]{NC}" if pid != pid0 else ""
                hop_plain = f"  [thread-hop {pid0}→{pid}]"          if pid != pid0 else ""
                sev = RED if gap_ms >= 500 else YLW
                emit(
                    f"{sev}[STRACE {ts}]{NC} fd={src:>4}→{dst}  "
                    f"EAGAIN→resume: {sev}{gap_ms:>8.0f} ms{NC}{hop_color}",
                    f"[STRACE {ts}] fd={src:>4}→{dst}  EAGAIN→resume: {gap_ms:>8.0f} ms{hop_plain}"
                )
PYEOF

        # Start strace piped to the processor — both run in background.
        # grep pre-filters to only EAGAIN and successful splice lines,
        # dramatically cutting the data volume the processor sees.
        # Run strace pipeline in background; errors are non-fatal (wrapped to
        # prevent set -e from aborting the script if strace exits early).
        { strace -f -p "$RP_PID" -e trace=splice -T -tt 2>&1 | \
            grep --line-buffered -E "EAGAIN|= [1-9]" | \
            python3 "$STRACE_PROC"; } &
        STRACE_PID=$!
        ok "strace processor running (rootlessport PID $RP_PID, gap threshold ${GAP_MS} ms)"
        info "  [STRACE] lines appear whenever EAGAIN→resume gap ≥ ${GAP_MS} ms"
        info "  Strace gap log: $STRACE_LOG"
    fi
fi

# ---------------------------------------------------------------------------
step "Curl probe loop — direct backend latency"
# ---------------------------------------------------------------------------
DURATION_MSG="until Ctrl+C"
[[ "$DURATION" -gt 0 ]] && DURATION_MSG="${DURATION}s"
info "Probing http://localhost:${DIRECT_PORT}/ every ${PROBE_EVERY}s  ($DURATION_MSG)"
echo ""
printf "  ${YLW}%-18s  %-12s  %-12s  %s${NC}\n" \
    "Probe#  Time" "Connect ms" "Total ms" "Note"
printf "  %-18s  %-12s  %-12s  %s\n" \
    "------------------" "----------" "----------" "----"

PROBE=0
SLOW=0
START=$(date +%s)

while true; do
    PROBE=$((PROBE + 1))

    RESULT=$(curl -s -o /dev/null \
        -w "%{time_connect} %{time_total} %{http_code}" \
        "http://localhost:${DIRECT_PORT}/" 2>/dev/null) || RESULT="0 0 ERR"

    CONN_S=$( awk '{print $1}' <<< "$RESULT")
    TOTAL_S=$(awk '{print $2}' <<< "$RESULT")
    CODE=$(   awk '{print $3}' <<< "$RESULT")

    CONN_MS=$(  awk "BEGIN {printf \"%.1f\", $CONN_S  * 1000}")
    TOTAL_MS=$( awk "BEGIN {printf \"%.1f\", $TOTAL_S * 1000}")
    IS_SLOW=$(  awk "BEGIN {print ($TOTAL_MS > 500) ? 1 : 0}")
    TS=$(date +"%H:%M:%S")

    if [[ "$CODE" == "ERR" ]]; then
        printf "  %-18s  %-12s  %-12s  " "#${PROBE} ${TS}" "-" "-"
        echo -e "${RED}[ERROR]${NC}"
    elif [[ "$IS_SLOW" -eq 1 ]]; then
        SLOW=$((SLOW + 1))
        printf "  %-18s  %-12s  %-12s  " \
            "#${PROBE} ${TS}" "${CONN_MS}ms" "${TOTAL_MS}ms"
        echo -e "${RED}[CURL] SLOW — HTTP-level delay visible${NC}"
    else
        printf "  %-18s  %-12s  %-12s\n" \
            "#${PROBE} ${TS}" "${CONN_MS}ms" "${TOTAL_MS}ms"
    fi

    if [[ "$DURATION" -gt 0 ]]; then
        NOW=$(date +%s)
        [[ $(( NOW - START )) -ge "$DURATION" ]] && break
    fi

    sleep "$PROBE_EVERY"
done

# ---------------------------------------------------------------------------
[[ -n "$STRACE_PID" ]] && kill "$STRACE_PID" 2>/dev/null || true

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo "  Probes          : $PROBE"
echo "  CURL slow >500ms: $SLOW"
[[ "$SLOW" -gt 0 ]] && \
    echo -e "  ${RED}HTTP-level EAGAIN lag confirmed via curl probe.${NC}" || \
    echo -e "  ${GRN}No curl-level spikes — check [STRACE] lines above for kernel evidence.${NC}"
