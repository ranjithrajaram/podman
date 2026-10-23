#!/usr/bin/env python3
"""
rootlessport-client.py — slow-receive HTTP client for rootlessport EAGAIN reproducer.

Maintains N persistent connections to the Envoy endpoint and reads each response
body in small 4 KB chunks with a configurable sleep between reads.  This keeps
each connection's TCP receive window small, which causes rootlessport's splice(2)
to return EAGAIN on every chunk.  With many concurrent connections all doing this
simultaneously, the Go scheduler run queue fills with parked goroutines and the
wakeup latency becomes the dominant source of latency — matching the production
behaviour observed in the eBPF trace.

No tc bandwidth throttling is needed: the slow recv loop controls the flow rate
at the application level without requiring root on the client machine.

Usage:
    python3 rootlessport-client.py [OPTIONS]

Options:
    --host        HOST   Target IP/hostname (default: 192.168.122.192)
    --port        PORT   Envoy port (default: 18080)
    --conns       N      Concurrent connections (default: 200)
    --recv-sleep  S      Seconds between 4 KB reads (default: 0.002)
                         Controls effective per-connection bandwidth:
                           0.001 → ~4 MB/s per conn
                           0.002 → ~2 MB/s per conn  (recommended)
                           0.005 → ~0.8 MB/s per conn
    --burst-every S      If set, synchronise all threads to fire simultaneously
                         every S seconds (simulates Java thread pool batch wakeup).
                         Omit for continuous unsynchronised load.
    --duration    S      Stop after S seconds (default: 0 = run until Ctrl+C)

Examples:
    # Continuous slow-receive load — mirrors Java EE thread pool behaviour
    python3 rootlessport-client.py --host 192.168.122.192 --conns 200

    # Bursty mode — all 200 threads fire at once every 30 seconds
    python3 rootlessport-client.py --host 192.168.122.192 --conns 200 --burst-every 30
"""

import argparse
import socket
import sys
import threading
import time


def parse_args():
    p = argparse.ArgumentParser(
        description="Slow-receive HTTP client for rootlessport EAGAIN reproducer"
    )
    p.add_argument("--host",        default="192.168.122.192")
    p.add_argument("--port",        type=int,   default=18080)
    p.add_argument("--conns",       type=int,   default=200)
    p.add_argument("--recv-sleep",  type=float, default=0.002,
                   help="seconds between 4 KB reads (default 0.002 = ~2 MB/s per conn)")
    p.add_argument("--burst-every", type=float, default=0,
                   help="synchronised burst interval in seconds (0 = continuous)")
    p.add_argument("--duration",    type=int,   default=0,
                   help="stop after N seconds (0 = run until Ctrl+C)")
    return p.parse_args()


def recv_headers(sock):
    """Read until the HTTP response header block ends."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            return buf, 0
        buf += chunk

    header_block, rest = buf.split(b"\r\n\r\n", 1)
    content_length = 0
    for line in header_block.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            try:
                content_length = int(line.split(b":", 1)[1].strip())
            except ValueError:
                pass
    return rest, content_length


def do_request(sock, host, port):
    """Send one GET request and read the full response body slowly."""
    request = (
        b"GET / HTTP/1.1\r\n"
        b"Host: " + host.encode() + b":" + str(port).encode() + b"\r\n"
        b"Connection: keep-alive\r\n"
        b"\r\n"
    )
    sock.sendall(request)

    body_start, content_length = recv_headers(sock)

    # Slow body consumption — the core of the reproducer.
    # Reading 4 KB at a time with recv_sleep between reads keeps the TCP
    # receive window small.  rootlessport hits splice(2) EAGAIN after each
    # 4 KB chunk because the client hasn't opened the window for more data yet.
    received = len(body_start)
    while received < content_length:
        chunk = sock.recv(4096)
        if not chunk:
            break
        received += len(chunk)
        time.sleep(RECV_SLEEP)


def continuous_worker(host, port, stop_event):
    """Keep one persistent connection alive, sending requests in a tight loop."""
    while not stop_event.is_set():
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(60)
            sock.connect((host, port))
            while not stop_event.is_set():
                do_request(sock, host, port)
        except Exception:
            pass
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass
        if not stop_event.is_set():
            time.sleep(0.1)


def burst_worker(host, port, barrier, stop_event):
    """
    Bursty mode: block at a barrier between bursts so all threads fire
    simultaneously.  This simulates a Java EE thread pool waking all threads
    at the same instant (e.g., a scheduled task or batch processing cycle).
    """
    while not stop_event.is_set():
        try:
            barrier.wait(timeout=10)
        except threading.BrokenBarrierError:
            continue

        if stop_event.is_set():
            break

        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(60)
            sock.connect((host, port))
            do_request(sock, host, port)
        except Exception:
            pass
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass


def burst_clock(barrier, interval, stop_event):
    """Periodically reset the barrier to release all waiting threads at once."""
    while not stop_event.is_set():
        time.sleep(interval)
        try:
            barrier.reset()
        except Exception:
            pass


def main():
    args = parse_args()

    global RECV_SLEEP
    RECV_SLEEP = args.recv_sleep

    effective_bw_mb = 4096 / args.recv_sleep / 1024 / 1024
    print(f"rootlessport EAGAIN slow-receive client")
    print(f"  Target          : {args.host}:{args.port}")
    print(f"  Connections     : {args.conns}")
    print(f"  Recv sleep      : {args.recv_sleep * 1000:.1f} ms / 4 KB chunk")
    print(f"  Per-conn bw     : ~{effective_bw_mb:.1f} MB/s")
    print(f"  Mode            : {'burst every ' + str(args.burst_every) + 's' if args.burst_every else 'continuous'}")
    if args.duration:
        print(f"  Duration        : {args.duration}s")
    print()

    stop_event = threading.Event()
    threads = []

    if args.burst_every:
        barrier = threading.Barrier(args.conns)
        clock = threading.Thread(
            target=burst_clock,
            args=(barrier, args.burst_every, stop_event),
            daemon=True,
        )
        clock.start()
        for _ in range(args.conns):
            t = threading.Thread(
                target=burst_worker,
                args=(args.host, args.port, barrier, stop_event),
                daemon=True,
            )
            t.start()
            threads.append(t)
        print(f"Burst mode: {args.conns} threads will fire together every {args.burst_every}s")
    else:
        for _ in range(args.conns):
            t = threading.Thread(
                target=continuous_worker,
                args=(args.host, args.port, stop_event),
                daemon=True,
            )
            t.start()
            threads.append(t)
        print(f"Continuous mode: {args.conns} persistent connections running")

    print("Press Ctrl+C to stop.\n")

    try:
        if args.duration:
            time.sleep(args.duration)
            stop_event.set()
        else:
            while True:
                time.sleep(1)
    except KeyboardInterrupt:
        print("\nStopping...")
        stop_event.set()

    for t in threads:
        t.join(timeout=2)
    print("Done.")


if __name__ == "__main__":
    main()
