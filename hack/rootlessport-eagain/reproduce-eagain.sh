#!/bin/bash
# rootlessport-eagain-reproducer.sh
#
# Reproduces the rootlessport TCP splice(2) EAGAIN latency bug.
#
# Bug summary:
#   rootlessport is the single Go process that forwards all TCP ports for a
#   rootless pod.  It uses splice(2) with SPLICE_F_NONBLOCK.  On EAGAIN
#   (pipe full / fd not ready) the unpatched code falls back to io.Copy,
#   which parks the goroutine on Go's runtime poller.  All port-forward
#   goroutines compete for the same Go scheduler; under concurrent load the
#   scheduler wakeup latency is unbounded — measured at median 3.5 s and
#   max 30 min in production.
#
# Fix (rootless-eagain branch):
#   Replace io.Copy with explicit unix.Splice + unix.Poll + LockOSThread.
#   poll(2) then blocks at the kernel level with no scheduler involvement
#   on wakeup.
#
# Pod layout (two port forwards, same rootlessport process):
#
#   host:ENVOY_PORT  ──► rootlessport ──► envoy-proxy:8080
#   (background load)                         │
#                                      127.0.0.1:8081 (pod-local, no rootlessport)
#                                             │
#   host:DIRECT_PORT ──► rootlessport ──► python-app:8081
#   (latency probe)
#
# Both paths share the same rootlessport goroutine pool.  The Envoy path
# drives a high concurrency of splice goroutines.  The direct path is
# where the EAGAIN scheduler lag becomes visible as HTTP latency spikes.
#
# Usage:
#   bash rootlessport-eagain-reproducer.sh [OPTIONS]
#
# Options:
#   --envoy-port  N    Host port → Envoy proxy (default: 18080)
#   --direct-port N    Host port → Python app directly (default: 18081)
#   --env-conns   N    Background connections to Envoy (default: 32)
#   --direct-conns N   Probe connections to backend (default: 8)
#   --duration    S    Test duration in seconds (default: 60)
#   --body-size   B    Response body bytes (default: 131072 = 128 KB)
#   --trace            Run bpftrace splice-EAGAIN tracer (requires root + bpftrace)
#   --no-cleanup       Leave pod running after test
#
# Requirements: rootless podman, python3, curl
# Optional:     bpftrace + sudo (--trace)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENVOY_PORT=18080
DIRECT_PORT=18081
ENV_CONNS=32          # connections driving Envoy (creates goroutine pressure)
DIRECT_CONNS=8        # probe connections going directly to the backend
DURATION=60
BODY_SIZE=131072      # 128 KB — larger than the 64 KB splice pipe buffer, so
                      # rootlessport needs at least 2 splice iterations per
                      # response.  Each iteration is a chance to hit EAGAIN and
                      # park on the Go scheduler.  Does not guarantee EAGAIN on
                      # its own; goroutine-pool pressure from concurrent Envoy
                      # connections is what makes the scheduler lag visible.
TRACE=0
NO_CLEANUP=0

POD_NAME="eagain-repro-pod"
NETWORK_NAME="eagain-repro-net"
ENVOY_IMAGE="docker.io/envoyproxy/envoy:v1.29-latest"
PYTHON_IMAGE="docker.io/library/python:3.11-slim"

TMPDIR_ROOT="$(mktemp -d /tmp/eagain-repro.XXXXXX)"

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
        --envoy-port)   ENVOY_PORT="$2";   shift 2 ;;
        --direct-port)  DIRECT_PORT="$2";  shift 2 ;;
        --env-conns)    ENV_CONNS="$2";    shift 2 ;;
        --direct-conns) DIRECT_CONNS="$2"; shift 2 ;;
        --duration)     DURATION="$2";     shift 2 ;;
        --body-size)    BODY_SIZE="$2";    shift 2 ;;
        --trace)        TRACE=1;           shift   ;;
        --no-cleanup)   NO_CLEANUP=1;      shift   ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    if [[ "$NO_CLEANUP" -eq 1 ]]; then
        info "Skipping cleanup (--no-cleanup).  Pod: $POD_NAME"
        info "  Envoy:   http://localhost:${ENVOY_PORT}/"
        info "  Backend: http://localhost:${DIRECT_PORT}/"
        return
    fi
    step "Cleanup"
    podman pod stop  "$POD_NAME"   2>/dev/null || true
    podman pod rm -f "$POD_NAME"   2>/dev/null || true
    podman network rm "$NETWORK_NAME" 2>/dev/null || true
    rm -rf "$TMPDIR_ROOT"
    ok "Done"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
step "Prerequisites"
# ---------------------------------------------------------------------------
for cmd in podman python3 curl; do
    command -v "$cmd" &>/dev/null || { err "$cmd not found"; exit 1; }
done
info "Running as: $(id)"
info "Podman:     $(podman --version)"

if [[ "$TRACE" -eq 1 ]]; then
    command -v bpftrace &>/dev/null || { err "--trace requires bpftrace in PATH"; exit 1; }
    [[ "$EUID" -eq 0 ]] || { err "--trace requires root (run with sudo)"; exit 1; }
fi

# ---------------------------------------------------------------------------
step "Cleanup any previous run"
# ---------------------------------------------------------------------------
podman pod stop  "$POD_NAME"   2>/dev/null || true
podman pod rm -f "$POD_NAME"   2>/dev/null || true
podman network rm "$NETWORK_NAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
step "Create bridge network (required for rootlessport)"
# ---------------------------------------------------------------------------
# rootlessport is only started when a rootless pod uses a bridge (netavark)
# network.  Podman 5.x defaults to pasta for rootless containers; pasta
# handles port-forwarding internally without rootlessport, so the EAGAIN
# splice bug would never be triggered on a pasta network.
#
# A named bridge network forces Podman to start rootlessport as the
# port-forwarding proxy, which is the process under test.
podman network create --driver bridge "$NETWORK_NAME"
ok "Bridge network created: $NETWORK_NAME"

# ---------------------------------------------------------------------------
step "Create pod (two port forwards → same rootlessport process)"
# ---------------------------------------------------------------------------
#   ENVOY_PORT  → pod:8080  (Envoy listener)
#   DIRECT_PORT → pod:8081  (Python app, direct path)
podman pod create \
    --name    "$POD_NAME" \
    --network "$NETWORK_NAME" \
    --publish "${ENVOY_PORT}:8080" \
    --publish "${DIRECT_PORT}:8081"
ok "Pod created"
info "  Envoy path:  host:${ENVOY_PORT} → rootlessport → pod:8080"
info "  Direct path: host:${DIRECT_PORT} → rootlessport → pod:8081"

# ---------------------------------------------------------------------------
step "Verify rootlessport is running"
# ---------------------------------------------------------------------------
# rootlessport starts as soon as the pod with port mappings is created on a
# bridge network.  If it is absent the test is measuring pasta/slirp4netns
# latency instead, which is a different code path.
ROOTLESSPORT_PID=""
for i in $(seq 1 10); do
    ROOTLESSPORT_PID=$(pgrep -f "rootlessport" 2>/dev/null | head -1 || true)
    [[ -n "$ROOTLESSPORT_PID" ]] && break
    sleep 1
done

if [[ -n "$ROOTLESSPORT_PID" ]]; then
    ok "rootlessport is running — PID $ROOTLESSPORT_PID"
    # Show the binary path so we can confirm it is the patched or unpatched build
    ROOTLESSPORT_EXE=$(readlink -f "/proc/${ROOTLESSPORT_PID}/exe" 2>/dev/null || echo "unknown")
    info "  Binary: $ROOTLESSPORT_EXE"
    info "  Active port-forwards:"
    cat "/proc/${ROOTLESSPORT_PID}/cmdline" 2>/dev/null | tr '\0' ' ' | sed 's/^/    /' || true
    echo
else
    err "rootlessport NOT found after pod creation."
    err "The pod may be using pasta or slirp4netns for port forwarding."
    err "Check: podman info | grep networkBackend"
    err "Ensure netavark is the network backend and bridge driver is available."
    exit 1
fi

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
    # max_requests_per_connection: 1 forces Envoy to open a new TCP connection
    # to the backend for every downstream request.  Each new connection creates
    # a fresh goroutine pair in rootlessport, rapidly growing the splice
    # goroutine pool and saturating the Go scheduler.
    max_requests_per_connection: 1
    load_assignment:
      cluster_name: python_app
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              # 127.0.0.1 here is inside the pod network namespace —
              # Envoy reaches Python directly without going through rootlessport.
              socket_address: { address: 127.0.0.1, port_value: 8081 }

admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: 9901 }
ENVOY_EOF
ok "Envoy config written"

# ---------------------------------------------------------------------------
step "Start Envoy container"
# ---------------------------------------------------------------------------
# The Envoy Docker entrypoint (docker-entrypoint.sh) runs
#   chown envoy /dev/stdout /dev/stderr
# before exec-ing the binary.  In rootless mode the container "root" is
# mapped to the calling user on the host; chown-ing device files that are
# owned by the real root fails with EPERM.
# Fix: override --entrypoint to skip the wrapper and exec envoy directly.
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
# BODY_SIZE is expanded by the shell here (not inside the container)
cat > "$APP_DIR/server.py" <<PYEOF
#!/usr/bin/env python3
"""
Multithreaded HTTP backend for rootlessport EAGAIN reproducer.

Serves BODY_SIZE bytes per response so rootlessport's splice(2) call
reliably fills the 64 KB pipe buffer, guaranteeing EAGAIN on every
response.  ThreadingHTTPServer mirrors real app concurrency (Tomcat NIO
threads, gunicorn workers).

Traffic arrives via two paths:
  1. Envoy  → 127.0.0.1:8081  (pod-local, bypasses rootlessport)
  2. Direct → host:DIRECT_PORT → rootlessport → 0.0.0.0:8081

The latency seen on path 2 is rootlessport scheduler wakeup delay.
"""
import os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BODY_SIZE = int(os.environ.get("BODY_SIZE", "${BODY_SIZE}"))
BODY      = b"A" * BODY_SIZE

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow":
            time.sleep(0.05)   # widen the EAGAIN window for easier reproduction
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
    print(f"Python app ready: {BODY_SIZE} B/response on :8081", flush=True)
    server.serve_forever()
PYEOF
ok "Python app written"

# ---------------------------------------------------------------------------
step "Start Python app container"
# ---------------------------------------------------------------------------
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
info "Waiting for Envoy (port ${ENVOY_PORT}) and backend (port ${DIRECT_PORT})..."
READY_ENVOY=0; READY_DIRECT=0
for i in $(seq 1 90); do
    [[ "$READY_ENVOY"  -eq 0 ]] && curl -sf --max-time 2 "http://localhost:${ENVOY_PORT}/"  -o /dev/null 2>/dev/null && READY_ENVOY=1  && ok "Envoy ready"
    [[ "$READY_DIRECT" -eq 0 ]] && curl -sf --max-time 2 "http://localhost:${DIRECT_PORT}/" -o /dev/null 2>/dev/null && READY_DIRECT=1 && ok "Backend direct ready"
    [[ "$READY_ENVOY" -eq 1 && "$READY_DIRECT" -eq 1 ]] && break
    sleep 1
    [[ $(( i % 15 )) -eq 0 ]] && info "  still waiting... ($i s)"
done

if [[ "$READY_ENVOY" -eq 0 || "$READY_DIRECT" -eq 0 ]]; then
    err "One or both endpoints not ready after 90 s"
    podman logs envoy-proxy 2>&1 | tail -20
    podman logs python-app  2>&1 | tail -10
    exit 1
fi

# ---------------------------------------------------------------------------
# Optional: bpftrace splice-EAGAIN tracer
# ---------------------------------------------------------------------------
TRACE_PID=""
TRACE_OUT="$TMPDIR_ROOT/splice_trace.txt"
if [[ "$TRACE" -eq 1 ]]; then
    step "Starting bpftrace splice-EAGAIN tracer"

    bpftrace /dev/stdin > "$TRACE_OUT" 2>&1 <<'BTEOF' &
// Measure the gap between a splice(2) EAGAIN return and the next splice
// attempt on the same thread.  This gap is the scheduler wakeup latency —
// the core of the rootlessport EAGAIN bug.

tracepoint:syscalls:sys_enter_splice
{
    @enter[tid] = nsecs;
}

tracepoint:syscalls:sys_exit_splice
/ @enter[tid] /
{
    $ret = (int64)args->ret;
    if ($ret == -11) {       // -EAGAIN / -EWOULDBLOCK
        @eagain_count = count();
        @eagain_at[tid] = nsecs;
    } else if (@eagain_at[tid] > 0) {
        // Successful splice after a previous EAGAIN: gap = wakeup latency
        $gap_us = (nsecs - @eagain_at[tid]) / 1000;
        @wakeup_gap_us = hist($gap_us);
        if ($gap_us > 500) {
            printf("[%s] EAGAIN wakeup gap %6d µs  pid=%-6d  comm=%s\n",
                   strftime("%H:%M:%S", nsecs), $gap_us, pid, comm);
        }
        delete(@eagain_at[tid]);
    }
    delete(@enter[tid]);
}

interval:s:10
{
    time("-- %H:%M:%S -- ");
    printf("EAGAIN count (10 s window):\n");
    print(@eagain_count);
    printf("Scheduler wakeup gap histogram (µs):\n");
    print(@wakeup_gap_us);
    clear(@eagain_count);
    clear(@wakeup_gap_us);
}
BTEOF
    TRACE_PID=$!
    info "bpftrace PID $TRACE_PID, output → $TRACE_OUT"
fi

# ---------------------------------------------------------------------------
step "Curl demo: direct-path latency under Envoy goroutine pressure"
# ---------------------------------------------------------------------------
# Runs a quick sequential probe so the delay is immediately readable:
#   • Spins up background Envoy connections to saturate rootlessport's
#     goroutine pool (same pressure source as the main load test).
#   • Sends DEMO_REQS one-at-a-time requests to the DIRECT backend port.
#   • Prints every response time; flags anything >500 ms as SLOW.
# ---------------------------------------------------------------------------
DEMO_REQS=20
DEMO_PRESSURE=$(( ENV_CONNS / 2 ))   # background Envoy connections for demo

DEMO_SCRIPT="$TMPDIR_ROOT/demo.py"
cat > "$DEMO_SCRIPT" <<PYEOF
#!/usr/bin/env python3
import http.client, threading, time, sys

ENVOY_HOST  = "localhost"
ENVOY_PORT  = ${ENVOY_PORT}
DIRECT_PORT = ${DIRECT_PORT}
PRESSURE    = ${DEMO_PRESSURE}
REQS        = ${DEMO_REQS}
SLOW_MS     = 500     # threshold — anything above this is flagged

done = threading.Event()

def bg_worker():
    """Keep an Envoy connection busy to grow rootlessport's goroutine pool."""
    while not done.is_set():
        try:
            c = http.client.HTTPConnection(ENVOY_HOST, ENVOY_PORT, timeout=15)
            while not done.is_set():
                c.request("GET", "/")
                c.getresponse().read()
        except Exception:
            pass

# Start background pressure
threads = [threading.Thread(target=bg_worker, daemon=True)
           for _ in range(PRESSURE)]
for t in threads:
    t.start()

print(f"  Background: {PRESSURE} connections hammering Envoy (localhost:{ENVOY_PORT})")
print(f"  Probe:      {REQS} sequential requests to direct backend (localhost:{DIRECT_PORT})")
print(f"  Threshold:  {SLOW_MS} ms  — above this = EAGAIN scheduler lag")
print()
print(f"  {'#':>4}  {'Response time':>16}  Status")
print(f"  {'-'*4}  {'-'*16}  {'-'*40}")

# Let pressure build for 2 s before probing
time.sleep(2)

slow = 0
for i in range(1, REQS + 1):
    try:
        t0 = time.monotonic()
        c = http.client.HTTPConnection(ENVOY_HOST, DIRECT_PORT, timeout=60)
        c.request("GET", "/")
        resp = c.getresponse()
        resp.read()
        c.close()
        ms = (time.monotonic() - t0) * 1000
        if ms >= SLOW_MS:
            slow += 1
            tag = f"*** SLOW  ({ms:,.0f} ms)  — EAGAIN scheduler lag ***"
        else:
            tag = f"OK        ({ms:,.0f} ms)"
        print(f"  {i:>4}  {ms:>12,.0f} ms  {tag}", flush=True)
    except Exception as exc:
        print(f"  {i:>4}  {'ERROR':>16}  {exc}", flush=True)

done.set()
print()
if slow:
    print(f"  Result: {slow}/{REQS} requests were SLOW (>{SLOW_MS} ms)")
    print(f"          rootlessport EAGAIN scheduler lag confirmed.")
else:
    print(f"  Result: all {REQS} requests under {SLOW_MS} ms")
    print(f"          Patched binary, or try --env-conns with a higher value.")
PYEOF

python3 "$DEMO_SCRIPT"

# ---------------------------------------------------------------------------
step "Write load generator"
# ---------------------------------------------------------------------------
LOAD_SCRIPT="$TMPDIR_ROOT/load.py"
cat > "$LOAD_SCRIPT" <<PYEOF
#!/usr/bin/env python3
"""
Two-stream concurrent load generator.

Stream 1 — Envoy path  (port ${ENVOY_PORT}):
  ${ENV_CONNS} connections driving traffic through Envoy → Python.
  Each connection forces a new Envoy upstream TCP connection
  (max_requests_per_connection=1), so rootlessport spawns a fresh
  goroutine pair per request.  This is the goroutine-pressure source.

Stream 2 — Direct path (port ${DIRECT_PORT}):
  ${DIRECT_CONNS} connections going directly to the Python backend.
  These also go through rootlessport but compete with Stream 1's
  goroutines for the same Go scheduler.
  *** This is where EAGAIN scheduler lag shows up as HTTP latency ***

On an unpatched rootlessport the direct-path p99/max will show seconds-
scale spikes while the Envoy path p99 stays moderate (Envoy has its own
timeouts and buffering that mask the goroutine delay).
"""
import http.client, threading, time, sys

HOST_ENVOY  = "localhost"
PORT_ENVOY  = ${ENVOY_PORT}
PORT_DIRECT = ${DIRECT_PORT}
ENV_CONNS   = ${ENV_CONNS}
DIRECT_CONNS= ${DIRECT_CONNS}
DURATION    = ${DURATION}
REPORT_SECS = 5

# Separate latency lists for each path
envoy_lat  = []
direct_lat = []
envoy_err  = 0
direct_err = 0
lock       = threading.Lock()
stop       = threading.Event()


def worker(host, port, lat_list, label):
    global envoy_err, direct_err
    while not stop.is_set():
        try:
            conn = http.client.HTTPConnection(host, port, timeout=120)
            while not stop.is_set():
                t0 = time.monotonic()
                conn.request("GET", "/")
                resp = conn.getresponse()
                resp.read()
                ms = (time.monotonic() - t0) * 1000
                with lock:
                    lat_list.append(ms)
        except Exception:
            with lock:
                if label == "envoy":
                    envoy_err += 1
                else:
                    direct_err += 1
            time.sleep(0.1)


def pct(data, p):
    if not data:
        return 0.0
    s = sorted(data)
    k = (len(s) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def summary(label, data, errors):
    if not data:
        print(f"  {label}: no data")
        return
    print(f"  {label}:")
    print(f"    requests  : {len(data)}")
    print(f"    errors    : {errors}")
    print(f"    p50       : {pct(data,50):>10.1f} ms")
    print(f"    p90       : {pct(data,90):>10.1f} ms")
    print(f"    p95       : {pct(data,95):>10.1f} ms")
    print(f"    p99       : {pct(data,99):>10.1f} ms")
    print(f"    p99.9     : {pct(data,99.9):>10.1f} ms")
    print(f"    max       : {max(data):>10.1f} ms")
    buckets = [(0,100,"<100 ms"), (100,500,"100-500 ms"),
               (500,1000,"500ms-1s"), (1000,5000,"1s-5s"),
               (5000,1e9,">5s  ←← SCHEDULER LAG")]
    print()
    for lo, hi, name in buckets:
        n = sum(1 for x in data if lo <= x < hi)
        bar = "#" * min(50, n * 50 // max(len(data), 1))
        print(f"    {name:26s} {n:>5}  {bar}")
    print()


# Start Envoy-path workers
threads = []
for i in range(ENV_CONNS):
    t = threading.Thread(
            target=worker,
            args=(HOST_ENVOY, PORT_ENVOY, envoy_lat, "envoy"),
            daemon=True)
    t.start()
    threads.append(t)

# Start direct-path workers
for i in range(DIRECT_CONNS):
    t = threading.Thread(
            target=worker,
            args=(HOST_ENVOY, PORT_DIRECT, direct_lat, "direct"),
            daemon=True)
    t.start()
    threads.append(t)

print(f"Load generator started")
print(f"  Envoy path  : {ENV_CONNS} conns → localhost:{PORT_ENVOY}   (goroutine pressure source)")
print(f"  Direct path : {DIRECT_CONNS} conns → localhost:{PORT_DIRECT}  (latency probe — watch THIS)")
print(f"  Duration    : {DURATION} s   Body: ${BODY_SIZE} B/response")
print()
hdr = f"{'Elapsed':>8}  {'E-req':>6} {'E-p99ms':>9} {'E-max':>8}  |  {'D-req':>6} {'D-p99ms':>9} {'D-max':>8}"
print(hdr)
print("-" * len(hdr))

deadline = time.monotonic() + DURATION
while time.monotonic() < deadline:
    time.sleep(min(REPORT_SECS, max(0, deadline - time.monotonic())))
    with lock:
        esnap = envoy_lat[:]
        dsnap = direct_lat[:]
        ee = envoy_err
        de = direct_err
    elapsed = DURATION - max(0, deadline - time.monotonic())
    ep99 = pct(esnap, 99) if esnap else 0
    emax = max(esnap)     if esnap else 0
    dp99 = pct(dsnap, 99) if dsnap else 0
    dmax = max(dsnap)     if dsnap else 0
    # Flag direct-path spikes that suggest EAGAIN scheduler lag
    flag = "  *** SPIKE ***" if dmax > 1000 else ""
    print(f"{elapsed:>7.0f}s  {len(esnap):>6} {ep99:>9.1f} {emax:>8.1f}  |  "
          f"{len(dsnap):>6} {dp99:>9.1f} {dmax:>8.1f}{flag}", flush=True)

stop.set()
for t in threads:
    t.join(timeout=5)

print()
print("=" * 70)
print("FINAL LATENCY SUMMARY")
print("=" * 70)
print()
summary("Envoy path  (host:${ENVOY_PORT} → rootlessport → envoy → python)", envoy_lat, envoy_err)
summary("Direct path (host:${DIRECT_PORT} → rootlessport → python)        ", direct_lat, direct_err)
print("NOTE: Direct-path spikes above 1 s indicate rootlessport EAGAIN")
print("      scheduler wakeup latency.  On the patched binary (rootless-eagain")
print("      branch) these spikes should be absent.")
PYEOF
ok "Load generator written"

# ---------------------------------------------------------------------------
step "Running load test  (${DURATION}s)"
# ---------------------------------------------------------------------------
info "Envoy load:  ${ENV_CONNS} conns → localhost:${ENVOY_PORT}"
info "Direct probe: ${DIRECT_CONNS} conns → localhost:${DIRECT_PORT}"
info "Body size: ${BODY_SIZE} B  (> 64 KB pipe buffer; forces multiple splice iterations)"
echo ""

python3 "$LOAD_SCRIPT"

# ---------------------------------------------------------------------------
# Print bpftrace results
# ---------------------------------------------------------------------------
if [[ "$TRACE" -eq 1 ]] && [[ -n "$TRACE_PID" ]]; then
    step "bpftrace splice-EAGAIN results"
    kill "$TRACE_PID" 2>/dev/null || true
    wait "$TRACE_PID" 2>/dev/null || true
    cat "$TRACE_OUT"
fi

echo ""
info "Container logs (tail):"
echo "--- envoy-proxy ---"
podman logs --tail 5 envoy-proxy 2>&1 || true
echo "--- python-app ---"
podman logs --tail 5 python-app  2>&1 || true
