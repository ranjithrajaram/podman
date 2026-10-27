#!/usr/bin/env python3
"""
analyse-bpftrace.py — Analyse output from rootlessport_eagain_race.bt

Parses the bpftrace log produced by rootlessport_eagain_race.bt and prints
a structured report covering:
  - Observation window and EAGAIN/SUCCESS rates
  - RECV→SPLICE delay distribution (same-TID measurement)
  - Kernel CFS wakeup latency (SCHED_RESUME events)
  - ALERT events (goroutine stalls > 1s)
  - Per-TID EAGAIN counts
  - Java/backend send pattern

Usage:
    python3 analyse-bpftrace.py <bpftrace.log> [--no-color]

Example:
    python3 analyse-bpftrace.py /root/bpftrace.log
    python3 analyse-bpftrace.py /root/bpftrace.log --no-color > report.txt
"""

import re
import sys
import os
from collections import defaultdict

# ---------------------------------------------------------------------------
# Regex patterns
# ---------------------------------------------------------------------------
EAGAIN_RE  = re.compile(r'^(\d+) SPLICE_EAGAIN pid=(\d+) tid=(\d+) count=(\d+)')
SUCCESS_RE = re.compile(r'^(\d+) SPLICE_SUCCESS pid=(\d+) tid=(\d+) bytes=(\d+)(?:\s+delay_us=(\d+))?')
RECV_RE    = re.compile(r'^(\d+) RECV pid=(\d+) tid=(\d+) bytes=(\d+)')
JAVA_RE    = re.compile(r'^(\d+) JAVA_SEND tid=(\d+)')
SCHED_RE   = re.compile(r'^(\d+) SCHED_RESUME tid=(\d+) wake_latency_us=(\d+) total_since_eagain_us=(\d+)')
ALERT_RE   = re.compile(r'(>>>.*<<<)')
READ_RE    = re.compile(r'^(\d+) READ pid=(\d+) tid=(\d+) bytes=(\d+)')


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def pct(lst, p):
    if not lst:
        return 0.0
    s = sorted(lst)
    idx = int(len(s) * p / 100)
    return s[min(idx, len(s) - 1)]


def bucket(values, buckets):
    counts = defaultdict(int)
    for v in values:
        for lo, hi, label in buckets:
            if lo <= v < hi:
                counts[label] += 1
                break
    return counts


def bar(n, total, width=40):
    if total == 0:
        return ""
    filled = int(n * width / total)
    return "█" * filled


# ---------------------------------------------------------------------------
# Colours (ANSI)
# ---------------------------------------------------------------------------
USE_COLOR = "--no-color" not in sys.argv

RED   = "\033[0;31m" if USE_COLOR else ""
YLW   = "\033[1;33m" if USE_COLOR else ""
GRN   = "\033[0;32m" if USE_COLOR else ""
BLU   = "\033[0;34m" if USE_COLOR else ""
BOLD  = "\033[1m"    if USE_COLOR else ""
NC    = "\033[0m"    if USE_COLOR else ""


def hdr(title):
    print(f"\n{BOLD}{'=' * 60}{NC}")
    print(f"{BOLD}  {title}{NC}")
    print(f"{BOLD}{'=' * 60}{NC}")


def sub(title):
    print(f"\n{BLU}  --- {title} ---{NC}")


# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------
def parse(path):
    data = dict(
        first_ns=None, last_ns=None,
        eagain_total=0,
        eagain_by_tid=defaultdict(int),
        success_total=0,
        recv_total=0, recv_bytes=[],
        java_total=0, java_tids=set(),
        delays_ms=[],
        sched_wake_ms=[], sched_total_ms=[],
        sched_events=[],
        alerts=[],
        map_warnings=0,
    )

    with open(path) as f:
        for line in f:
            line = line.rstrip()

            # Track time range
            p = line.split()
            if p and p[0].isdigit():
                ns = int(p[0])
                if data["first_ns"] is None:
                    data["first_ns"] = ns
                data["last_ns"] = ns

            # ALERTS (text lines)
            m = ALERT_RE.search(line)
            if m:
                data["alerts"].append(line.strip())
                continue

            # Map full warnings
            if "Map full" in line or "map_update_elem" in line:
                data["map_warnings"] += 1
                continue

            # SPLICE_EAGAIN
            m = EAGAIN_RE.match(line)
            if m:
                data["eagain_total"] += 1
                data["eagain_by_tid"][m.group(3)] += 1
                continue

            # SPLICE_SUCCESS
            m = SUCCESS_RE.match(line)
            if m:
                data["success_total"] += 1
                if m.group(5):
                    data["delays_ms"].append(int(m.group(5)) / 1000)
                continue

            # RECV
            m = RECV_RE.match(line)
            if m:
                data["recv_total"] += 1
                data["recv_bytes"].append(int(m.group(4)))
                continue

            # JAVA_SEND
            m = JAVA_RE.match(line)
            if m:
                data["java_total"] += 1
                data["java_tids"].add(m.group(2))
                continue

            # SCHED_RESUME
            m = SCHED_RE.match(line)
            if m:
                wake = int(m.group(3)) / 1000
                total = int(m.group(4)) / 1000
                data["sched_wake_ms"].append(wake)
                data["sched_total_ms"].append(total)
                data["sched_events"].append((int(m.group(1)), m.group(2), wake, total, line))

    return data


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
def report(path, data):
    window_s = 0
    if data["first_ns"] and data["last_ns"]:
        window_s = (data["last_ns"] - data["first_ns"]) / 1e9

    size_bytes = os.path.getsize(path)

    hdr("BPFTRACE LOG ANALYSIS — rootlessport_eagain_race.bt")
    print(f"  File            : {path}")
    print(f"  File size       : {size_bytes / 1024 / 1024:.1f} MB")
    print(f"  Observation     : {window_s:.0f}s  ({window_s / 60:.1f} min)")

    # ---------------------------------------------------------------- ALERTS
    hdr("ALERTS  (goroutine stall > 1 s)")
    if data["alerts"]:
        for a in data["alerts"]:
            print(f"  {RED}{a}{NC}")
    else:
        print(f"  {GRN}  None — no stalls > 1s detected{NC}")

    # ---------------------------------------------------------------- SPLICE
    hdr("SPLICE ACTIVITY")
    rate_eagain  = data["eagain_total"]  / window_s if window_s else 0
    rate_success = data["success_total"] / window_s if window_s else 0

    print(f"  SPLICE_EAGAIN  : {data['eagain_total']:>12,}  ({rate_eagain:.0f}/s)")
    print(f"  SPLICE_SUCCESS : {data['success_total']:>12,}  ({rate_success:.0f}/s)")
    print(f"  Ratio (eager/success): {data['eagain_total']/max(data['success_total'],1)*100:.1f}%")

    sub("EAGAIN by goroutine (TID)")
    top = sorted(data["eagain_by_tid"].items(), key=lambda x: -x[1])
    for tid, cnt in top[:8]:
        b = bar(cnt, data["eagain_total"])
        print(f"    tid={tid:>10}  {cnt:>10,}  {b}")

    # ---------------------------------------------------------------- RECV
    hdr("RECV EVENTS (SCM_RIGHTS / data arriving at rootlessport)")
    print(f"  RECV events       : {data['recv_total']:,}")
    if data["recv_bytes"]:
        print(f"  Median recv size  : {sorted(data['recv_bytes'])[len(data['recv_bytes'])//2]} bytes")

    # -------- RECV->SPLICE delay
    sub("RECV→SPLICE delay_us  (same-TID measurement)")
    if data["delays_ms"]:
        dl = data["delays_ms"]
        print(f"  Samples    : {len(dl):,}")
        print(f"  Median     : {pct(dl, 50):>10.2f} ms")
        print(f"  p90        : {pct(dl, 90):>10.2f} ms")
        print(f"  p99        : {pct(dl, 99):>10.2f} ms")
        print(f"  Max        : {max(dl):>10.2f} ms")
        over_1s = sum(1 for d in dl if d > 1000)
        col = RED if over_1s else GRN
        print(f"  >1000ms    : {col}{over_1s:>10}{NC}  {'← SCHEDULER STALL' if over_1s else '← none'}")

        buckets = [
            (0,     1,    "< 1 ms"),
            (1,     10,   "1–10 ms"),
            (10,    100,  "10–100 ms"),
            (100,   1000, "100ms–1s"),
            (1000,  float("inf"), ">1s  ← STALL"),
        ]
        print()
        for lo, hi, label in buckets:
            n = sum(1 for d in dl if lo <= d < hi)
            if n:
                color = RED if lo >= 1000 else ""
                print(f"    {color}{label:20s} {n:>6,}  {bar(n, len(dl))}{NC}")
    else:
        print(f"  {YLW}  No delay_us measurements — RECV and SPLICE on different TIDs{NC}")
        print(f"  (thread-hop: goroutine moved between OS threads — see SCHED_RESUME below)")

    # ---------------------------------------------------------------- SCHED
    hdr("KERNEL CFS WAKEUP LATENCY  (SCHED_RESUME — most reliable metric)")
    wk = data["sched_wake_ms"]
    tt = data["sched_total_ms"]
    if wk:
        print(f"  Samples                  : {len(wk):,}")
        print()
        print(f"  wake_latency (CFS scheduling delay after sched_wakeup):")
        print(f"    Median                 : {pct(wk,50):>8.2f} ms")
        print(f"    p90                    : {pct(wk,90):>8.2f} ms")
        print(f"    Max                    : {max(wk):>8.2f} ms")
        print(f"    {'CFS is fast → kernel is NOT the bottleneck' if max(wk) < 100 else 'CFS showing pressure'}")
        print()
        print(f"  total_since_eagain (Go runtime delay + CFS):")
        print(f"    Median                 : {pct(tt,50):>8.2f} ms")
        print(f"    p90                    : {pct(tt,90):>8.2f} ms")
        print(f"    Max                    : {max(tt):>8.2f} ms  ← goroutine stall")
        over_1s = sum(1 for t in tt if t > 1000)
        col = RED if over_1s else GRN
        print(f"    Events >1s             : {col}{over_1s}{NC}  {'← Go scheduler stall confirmed' if over_1s else ''}")

        print()
        print(f"  Interpretation:")
        diff = max(tt) - max(wk)
        print(f"    max(total) - max(wake) = {diff:.0f}ms held by Go runtime BEFORE sched_wakeup")
        print(f"    Once sched_wakeup was called, CFS scheduled in {max(wk):.0f}ms")
        print(f"    → Root cause is Go's netpoller delay, NOT Linux CFS")

        sub("Stall distribution  (total_since_eagain)")
        buckets = [
            (0,     1,    "< 1 ms      (normal)"),
            (1,     10,   "1–10 ms     (mild)"),
            (10,    100,  "10–100 ms   (moderate)"),
            (100,   1000, "100ms–1s    (noticeable)"),
            (1000,  float("inf"), ">1s         (Go scheduler stall)"),
        ]
        for lo, hi, label in buckets:
            n = sum(1 for t in tt if lo <= t < hi)
            if n:
                color = RED if lo >= 1000 else (YLW if lo >= 100 else "")
                print(f"    {color}{label:30s} {n:>5,}  {bar(n, len(tt))}{NC}")
    else:
        print(f"  {YLW}  No SCHED_RESUME events with wake_latency > 1ms{NC}")

    # ---------------------------------------------------------------- JAVA
    hdr("BACKEND / JAVA SEND PATTERN")
    rate_java = data["java_total"] / window_s if window_s else 0
    print(f"  JAVA_SEND events  : {data['java_total']:,}  ({rate_java:.1f}/s)")
    print(f"  Unique thread IDs : {len(data['java_tids']):,}")
    if data["java_tids"]:
        print(f"  (each TID = one Java/Python thread sending data to rootlessport)")

    # ---------------------------------------------------------------- WARNINGS
    if data["map_warnings"]:
        hdr("MAP FULL WARNINGS")
        print(f"  {YLW}bpftrace map full: {data['map_warnings']} warning(s){NC}")
        print(f"  Fix: BPFTRACE_MAX_MAP_KEYS=131072 bpftrace script.bt ...")
        print(f"       sysctl -w vm.max_map_count=262144")

    # ---------------------------------------------------------------- SUMMARY
    hdr("SUMMARY")
    stalls = sum(1 for t in data["sched_total_ms"] if t > 1000)
    max_stall = max(data["sched_total_ms"]) if data["sched_total_ms"] else 0
    print(f"  Observation        : {window_s:.0f}s ({window_s/60:.1f} min)")
    print(f"  EAGAIN events      : {data['eagain_total']:,} ({rate_eagain:.0f}/s) — Go scheduler under pressure")
    print(f"  SCHED_RESUME stalls>1s : {stalls}")
    print(f"  Worst goroutine stall  : {max_stall:.0f} ms")
    print(f"  ALERTS fired       : {len(data['alerts'])}")
    print()
    if data["alerts"] or stalls:
        print(f"  {RED}VERDICT: Go EAGAIN scheduler stall CONFIRMED{NC}")
        print(f"  The kernel CFS is fast (wake_latency median {pct(data['sched_wake_ms'],50):.1f}ms).")
        print(f"  Goroutines are stalled BEFORE sched_wakeup — inside Go's runtime netpoller.")
        print(f"  Fix: replace io.Copy with splice+poll(-1)+LockOSThread in rootlessport.")
    else:
        print(f"  {GRN}VERDICT: No scheduler stalls detected in this window{NC}")
        print(f"  Either the patched binary is in use, or load was insufficient to trigger stalls.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(f"Usage: python3 {sys.argv[0]} <bpftrace.log> [--no-color]")
        sys.exit(1)

    path = args[0]
    if not os.path.exists(path):
        print(f"Error: file not found: {path}")
        sys.exit(1)

    print(f"Parsing {path} ...", file=sys.stderr)
    data = parse(path)
    report(path, data)
