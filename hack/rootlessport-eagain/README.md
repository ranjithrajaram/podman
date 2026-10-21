# rootlessport TCP splice EAGAIN latency reproducer

Reproducer scripts for the rootlessport EAGAIN scheduler-wakeup latency bug
and its fix in `vendor/github.com/rootless-containers/rootlesskit/v2/pkg/port/builtin/parent/tcp/tcp.go`.

## Bug summary

`rootlessport` is the Go process that forwards all TCP port mappings for a
rootless pod.  It proxies data using `splice(2)` with `SPLICE_F_NONBLOCK`.
When `splice` returns `EAGAIN` (pipe full or fd not ready), the unpatched code
falls through to `io.Copy`, which parks the goroutine on Go's runtime netpoller.

Under concurrent load, Go's M:N scheduler wakeup latency is unbounded.  Every
goroutine that hits `EAGAIN` joins the scheduler run queue.  When many
goroutines wake simultaneously (e.g. one burst of N connections) and the number
of runnable goroutines exceeds `GOMAXPROCS`, the scheduler delays some
goroutines by the duration of a full scheduling round — measured in production
at a median of 3.5 s and a maximum of 30 min.

### Traffic path

```
client
  │
  ▼
host:ENVOY_PORT ──► rootlessport goroutines (splice loop)
                         │
                         ▼ pod network
                    envoy-proxy:8080 ──► python-app:8081 (pod-local)

host:DIRECT_PORT ──► rootlessport goroutines (splice loop)
                         │
                         ▼ pod network
                    python-app:8081
```

Both port forwards share the **same rootlessport process and goroutine pool**.
The Envoy path creates goroutine pressure; the direct path is where the EAGAIN
scheduler lag becomes visible as HTTP latency spikes.

### Fix

Replace `io.Copy` with an explicit `unix.Splice` + `unix.Poll` loop pinned to
a dedicated OS thread via `runtime.LockOSThread`.  A quit-pipe is used to
interrupt `poll(2)` on connection teardown so the poll timeout can be set to
`-1` (infinite), eliminating periodic Go-scheduler wakeups entirely.

## Scripts

| Script | Purpose |
|---|---|
| `reproduce-eagain.sh` | High-throughput reproducer (50–60% CPU). Fastest way to trigger spikes. |
| `reproduce-eagain-sustained.sh` | Rate-limited sustained reproducer (~20% CPU). Runs for hours; curl output is human-readable. |
| `curl-latency-probe.sh` | Run from an **external node** to observe per-request latency against a live pod. |

## Requirements

- Rootless podman with **netavark** backend (bridge network)
  - `podman info | grep networkBackend` must show `netavark`
  - pasta (Podman 5.x default for rootless) does **not** start rootlessport
- python3
- curl
- Container images: `docker.io/envoyproxy/envoy:v1.29-latest`, `docker.io/library/python:3.11-slim`

## Reproducing the bug (unpatched binary)

### High-throughput (quick, ~60 s)

```bash
bash reproduce-eagain.sh
```

Expected output on unpatched rootlessport:

```
  Direct path (host:18081 → rootlessport → python):
    p99       :     1026.4 ms
    max       :    15310.6 ms

    <100 ms              18930  #################################################
    1s-5s                  341
    >5s  ←← SCHEDULER LAG   2
```

### Sustained (long-running, readable curl output)

```bash
# ~20% CPU — runs until Ctrl+C or --duration
bash reproduce-eagain-sustained.sh --conns 32 --rate 5 --probe-every 3

# More aggressive on 4+ vCPU nodes
bash reproduce-eagain-sustained.sh --conns 64 --rate 10 --probe-every 3
```

Expected output on unpatched rootlessport — intermittent spikes ~1 s:

```
  #20 14:32:01  0.3ms   1.1ms   1024.8ms  *** SLOW — EAGAIN scheduler lag ***
  #21 14:32:04  0.3ms   1.2ms      9.3ms  OK
```

### External node curl probe

Run while the reproducer is running on the target node:

```bash
# From a separate machine:
bash curl-latency-probe.sh <pod-host-ip> 18081 60
```

## Verifying the fix

Build the rootlessport binary from the `rootless-eagain` branch and replace
the system binary, then re-run:

```bash
# On the target node — restart pod to pick up the new binary
podman pod stop  <pod-name>
podman pod start <pod-name>

# Confirm the patched binary is running
ls -lh /proc/$(pgrep rootlessport)/exe
```

Expected output on **patched** rootlessport — all probes under 10 ms:

```
  Probes     : 41
  Slow >500ms: 0
  No spikes detected.
```

## Observed results (RHEL 9, Podman 5.8.2, 2 vCPU VM)

| Binary | Load | Slow requests | Max latency |
|---|---|---|---|
| Unpatched (io.Copy) | 640 req/s | 4/20 (20%) | 15 310 ms |
| Patched (splice+poll) | 640 req/s | 0/41 (0%) | 7 ms |

The ~1 s spike pattern (always near a multiple of 1024 ms) is the Go runtime
`sysmon` netpoller backoff reaching its maximum interval under scheduler
saturation.  The bimodal distribution (either <5 ms or >1000 ms, nothing
in between) is the distinguishing signature of a goroutine-scheduler wakeup
delay rather than a network or application bottleneck.
