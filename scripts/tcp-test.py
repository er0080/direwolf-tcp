#!/usr/bin/env python3
"""
tcp-test.py — TCP traffic tests over the RF link

Measures common low-throughput patterns and reports goodput, latency,
and protocol efficiency for link tuning and optimization.

Orchestrator usage (run as root):
    sudo python3 scripts/tcp-test.py [OPTIONS]

    --ns-a NS       source namespace        (default: ns_a)
    --ns-b NS       dest namespace          (default: ns_b)
    --addr-a ADDR   IP address in ns_a      (default: 10.0.0.1)
    --addr-b ADDR   IP address in ns_b      (default: 10.0.0.2)
    --tests LIST    comma-separated subset  (default: all)
                    choices: connect echo upload download reqresp
    --nodelay       set TCP_NODELAY on all sockets
    --timeout S     per-test wall-clock timeout (default: 300)

Internal modes (spawned by orchestrator, not for direct use):
    --server PORT SCENARIO [--nodelay]
    --client HOST PORT SCENARIO [--nodelay]

Tests and what they measure
───────────────────────────
  connect    TCP 3-way handshake RTT.  Baseline for all latency estimates.
             A half-RTT ≈ one ARDOP frame time + bridge hold-off.

  echo       N×64 B ping-pong exchanges with explicit ACK before next send.
             Reveals true half-duplex round-trip and per-message overhead.
             With TCP_NODELAY: shows Nagle-off cost/benefit.

  upload     2 KB A→B bulk transfer; waits for server application ACK.
             Duration includes one final ACK round-trip; goodput = useful
             data rate as seen by the application.

  download   A sends 1-byte trigger; B streams 2 KB back.
             TTFB shows request-to-first-byte latency (≈1 half-RTT +
             server processing).  Goodput shows sustained receive rate.

  reqresp    128 B request → 1 KB response.  Models HTTP GET / APRS query.
             Most realistic pattern for interactive low-bandwidth use.

Efficiency
──────────
  goodput_bps / raw_frame_capacity  where raw_frame_capacity is estimated
  from the connect test as: 508 B × 8 / (connect_ms/2 ms).
  Values well below 50% indicate significant ACK or header overhead.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import socket
import subprocess
import sys
import time
from datetime import datetime
from typing import Any, Optional

# ── test parameters ────────────────────────────────────────────────────────────

ECHO_MESSAGES  = 3      # echo exchanges per run
ECHO_SIZE      = 64     # bytes per message

UPLOAD_SIZE    = 2048   # bytes sent A→B
DOWNLOAD_SIZE  = 2048   # bytes streamed B→A

REQ_SIZE       = 128    # request bytes  (req/resp pattern)
RESP_SIZE      = 1024   # response bytes (req/resp pattern)

CONNECT_TIMEOUT = 60    # seconds — generous for ~10 s ARDOP handshake
RECV_TIMEOUT    = 300   # seconds — per recv() call

ALL_TESTS  = ['connect', 'echo', 'upload', 'download', 'reqresp']
BASE_PORT  = 9100       # ports: BASE_PORT + index(test)

# ── shared helper ──────────────────────────────────────────────────────────────

def recv_exactly(sock: socket.socket, n: int) -> bytes:
    """Receive exactly n bytes, blocking until all arrive or EOF."""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(min(4096, n - len(buf)))
        if not chunk:
            raise ConnectionError(f'connection closed after {len(buf)}/{n} bytes')
        buf.extend(chunk)
    return bytes(buf)


# ── server ─────────────────────────────────────────────────────────────────────

def _serve(conn: socket.socket, scenario: str) -> None:
    conn.settimeout(RECV_TIMEOUT)

    if scenario == 'connect':
        pass  # accept + close is the whole test

    elif scenario == 'echo':
        for _ in range(ECHO_MESSAGES):
            conn.sendall(recv_exactly(conn, ECHO_SIZE))

    elif scenario == 'upload':
        recv_exactly(conn, UPLOAD_SIZE)
        conn.sendall(b'\x06')           # application-level ACK (ASCII ACK)

    elif scenario == 'download':
        recv_exactly(conn, 1)           # trigger byte
        conn.sendall(os.urandom(DOWNLOAD_SIZE))

    elif scenario == 'reqresp':
        recv_exactly(conn, REQ_SIZE)
        conn.sendall(os.urandom(RESP_SIZE))

    conn.close()


def run_server(port: int, scenario: str, nodelay: bool) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', port))
    srv.listen(1)
    print('READY', flush=True)          # signal orchestrator before blocking
    conn, _ = srv.accept()
    if nodelay:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    _serve(conn, scenario)
    srv.close()


# ── client ─────────────────────────────────────────────────────────────────────

def _measure(sock: socket.socket, scenario: str) -> dict[str, Any]:
    """Run the client side of a scenario; return raw metric dict."""
    sock.settimeout(RECV_TIMEOUT)

    if scenario == 'connect':
        return {}   # connect_ms is added by run_client()

    if scenario == 'echo':
        payload = os.urandom(ECHO_SIZE)
        rtts_ms: list[int] = []
        t_total = time.monotonic()
        for _ in range(ECHO_MESSAGES):
            t0 = time.monotonic()
            sock.sendall(payload)
            recv_exactly(sock, ECHO_SIZE)
            rtts_ms.append(round((time.monotonic() - t0) * 1000))
        total_s = time.monotonic() - t_total
        total_b = ECHO_SIZE * ECHO_MESSAGES
        return {
            'payload_b':    total_b,
            'rtt_ms':       rtts_ms,
            'mean_rtt_ms':  round(sum(rtts_ms) / len(rtts_ms)),
            'min_rtt_ms':   min(rtts_ms),
            'max_rtt_ms':   max(rtts_ms),
            'duration_s':   round(total_s, 2),
            'goodput_bps':  round(total_b * 8 / total_s) if total_s else 0,
        }

    if scenario == 'upload':
        payload = os.urandom(UPLOAD_SIZE)
        t0 = time.monotonic()
        sock.sendall(payload)
        recv_exactly(sock, 1)           # wait for server ACK
        elapsed = time.monotonic() - t0
        return {
            'payload_b':   UPLOAD_SIZE,
            'duration_s':  round(elapsed, 2),
            'goodput_bps': round(UPLOAD_SIZE * 8 / elapsed),
        }

    if scenario == 'download':
        t0 = time.monotonic()
        sock.sendall(b'\x01')           # trigger
        first = sock.recv(1)
        if not first:
            raise ConnectionError('server closed before sending data')
        ttfb_ms = round((time.monotonic() - t0) * 1000)
        recv_exactly(sock, DOWNLOAD_SIZE - 1)
        elapsed = time.monotonic() - t0
        return {
            'payload_b':   DOWNLOAD_SIZE,
            'ttfb_ms':     ttfb_ms,
            'duration_s':  round(elapsed, 2),
            'goodput_bps': round(DOWNLOAD_SIZE * 8 / elapsed),
        }

    if scenario == 'reqresp':
        t0 = time.monotonic()
        sock.sendall(os.urandom(REQ_SIZE))
        first = sock.recv(1)
        if not first:
            raise ConnectionError('server closed before sending response')
        ttfb_ms = round((time.monotonic() - t0) * 1000)
        recv_exactly(sock, RESP_SIZE - 1)
        elapsed = time.monotonic() - t0
        return {
            'req_b':       REQ_SIZE,
            'resp_b':      RESP_SIZE,
            'total_b':     REQ_SIZE + RESP_SIZE,
            'ttfb_ms':     ttfb_ms,
            'duration_s':  round(elapsed, 2),
            'goodput_bps': round((REQ_SIZE + RESP_SIZE) * 8 / elapsed),
        }

    raise ValueError(f'unknown scenario: {scenario}')


def run_client(host: str, port: int, scenario: str, nodelay: bool) -> None:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if nodelay:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(CONNECT_TIMEOUT)
        t0 = time.monotonic()
        sock.connect((host, port))
        connect_ms = round((time.monotonic() - t0) * 1000)
        sock.settimeout(None)

        try:
            m = _measure(sock, scenario)
        finally:
            try:
                sock.close()
            except OSError:
                pass

        m['test'] = scenario
        m['connect_ms'] = connect_ms
        print(json.dumps(m), flush=True)
    except Exception as exc:
        print(json.dumps({'test': scenario, 'error': str(exc)}), flush=True)
        sys.exit(1)


# ── orchestrator helpers ───────────────────────────────────────────────────────

def ns_exec(ns: str, *cmd: str) -> list[str]:
    return ['ip', 'netns', 'exec', ns, *cmd]


def preflight(ns_a: str, ns_b: str) -> None:
    r = subprocess.run(['ip', 'netns', 'list'], capture_output=True, text=True)
    for ns in (ns_a, ns_b):
        if ns not in r.stdout:
            sys.exit(f'ERROR: namespace {ns!r} not found — is the link up?')


def tune_tcp_for_ardop(ns_a: str, ns_b: str, addr_a: str, addr_b: str) -> None:
    """
    Tune TCP in both namespaces for ARDOP's ~13 s round-trip link.

    Default TCP RTO starts at 1 s and doubles on each retransmit.  With an
    ARDOP frame taking ~8 s to transmit (4.5 s air + 3 s yield), TCP fires
    multiple retransmissions before the first one is even on-air.  Those
    duplicates queue behind the original and starve subsequent tests of
    queue capacity, causing every test after 'connect' to time out.

    Fix: set rto_min to 60 s so TCP will not retransmit data until well
    after the ARDOP link has had time to deliver and ACK it.
    """
    # Try the host route first, then the /30 subnet route — one will exist.
    for ns, dev, peer in ((ns_a, 'tnc0', addr_b), (ns_b, 'tnc1', addr_a)):
        tuned = False
        for dst in (peer, '10.0.0.0/30'):
            r = subprocess.run(
                ['ip', 'netns', 'exec', ns, 'ip', 'route', 'change',
                 dst, 'dev', dev, 'rto_min', '60000'],
                capture_output=True,
            )
            if r.returncode == 0:
                tuned = True
                break
        if tuned:
            print(f'  TCP rto_min=60s set on {ns}/{dev} route to {peer}')
        else:
            print(f'  WARNING: could not set rto_min on {ns}/{dev} — '
                  'retransmit flooding may occur', file=sys.stderr)


def _wait_ready(proc: subprocess.Popen, timeout: float = 30.0) -> bool:
    """Return True if proc prints 'READY' within timeout seconds."""
    readable, _, _ = select.select([proc.stdout], [], [], timeout)
    if not readable:
        return False
    line = proc.stdout.readline().decode().strip()
    return line == 'READY'


def run_one(test: str, ns_a: str, ns_b: str, addr_b: str,
            nodelay: bool, timeout: int) -> dict[str, Any]:
    port   = BASE_PORT + ALL_TESTS.index(test)
    script = os.path.abspath(__file__)
    extra  = ['--nodelay'] if nodelay else []

    srv_cmd = ns_exec(ns_b, sys.executable, script,
                      '--server', str(port), test, *extra)
    cli_cmd = ns_exec(ns_a, sys.executable, script,
                      '--client', addr_b, str(port), test, *extra)

    srv = subprocess.Popen(srv_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    if not _wait_ready(srv, timeout=30):
        srv.kill(); srv.wait()
        return {'test': test, 'error': 'server did not become ready within 30 s'}

    cli = subprocess.Popen(cli_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        out, _ = cli.communicate(timeout=timeout)
        m = json.loads(out.decode().strip())
    except subprocess.TimeoutExpired:
        cli.kill()
        m = {'test': test, 'error': f'client timed out after {timeout} s'}
    except (json.JSONDecodeError, ValueError) as exc:
        m = {'test': test, 'error': f'bad client output: {exc}'}
    except Exception as exc:
        m = {'test': test, 'error': str(exc)}
    finally:
        srv.kill()
        srv.wait()

    return m


# ── report ─────────────────────────────────────────────────────────────────────

def _bps(bps: Optional[int]) -> str:
    if bps is None:
        return '—'
    if bps >= 10_000:
        return f'{bps/1000:.1f} kbps'
    return f'{bps:,} bps'


def _ms(ms: Optional[int]) -> str:
    if ms is None:
        return '—'
    if ms >= 10_000:
        return f'{ms/1000:.0f} s'
    if ms >= 1_000:
        return f'{ms/1000:.1f} s'
    return f'{ms} ms'


def print_report(results: list[dict], nodelay: bool,
                 ns_a: str, ns_b: str, addr_a: str, addr_b: str) -> None:
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    nd = '  [TCP_NODELAY]' if nodelay else ''
    W  = 74

    print()
    print('=' * W)
    print(f'  TCP Link Performance  ·  {ts}{nd}')
    print(f'  {ns_a} {addr_a} ↔ {ns_b} {addr_b}')
    print('=' * W)
    print()

    COL = f'  {"Test":<14} {"Payload":>8}  {"Duration":>10}  {"Goodput":>12}  {"Connect":>9}  Notes'
    print(COL)
    print('  ' + '─' * (W - 2))

    for m in results:
        test  = m.get('test', '?')
        error = m.get('error')
        conn  = _ms(m.get('connect_ms'))

        if error:
            print(f'  {test:<14} {"ERROR":>8}  {error}')
            continue

        if test == 'connect':
            print(f'  {test:<14} {"—":>8}  {"—":>10}  {"—":>12}  {conn:>9}  TCP handshake RTT')

        elif test == 'echo':
            payload = f"{m.get('payload_b', 0)} B"
            dur     = f"{m.get('duration_s', 0):.1f} s"
            gput    = _bps(m.get('goodput_bps'))
            rtt     = _ms(m.get('mean_rtt_ms'))
            spread  = f"{_ms(m.get('min_rtt_ms'))}–{_ms(m.get('max_rtt_ms'))}"
            print(f'  {test:<14} {payload:>8}  {dur:>10}  {gput:>12}  {conn:>9}  '
                  f'mean RTT {rtt}  ({spread})')

        elif test == 'upload':
            payload = f"{m.get('payload_b', 0)} B"
            dur     = f"{m.get('duration_s', 0):.1f} s"
            gput    = _bps(m.get('goodput_bps'))
            print(f'  {test:<14} {payload:>8}  {dur:>10}  {gput:>12}  {conn:>9}')

        elif test == 'download':
            payload = f"{m.get('payload_b', 0)} B"
            dur     = f"{m.get('duration_s', 0):.1f} s"
            gput    = _bps(m.get('goodput_bps'))
            ttfb    = _ms(m.get('ttfb_ms'))
            print(f'  {test:<14} {payload:>8}  {dur:>10}  {gput:>12}  {conn:>9}  TTFB {ttfb}')

        elif test == 'reqresp':
            payload = f"{m.get('total_b', 0)} B"
            dur     = f"{m.get('duration_s', 0):.1f} s"
            gput    = _bps(m.get('goodput_bps'))
            ttfb    = _ms(m.get('ttfb_ms'))
            print(f'  {test:<14} {payload:>8}  {dur:>10}  {gput:>12}  {conn:>9}  TTFB {ttfb}')

    print('  ' + '─' * (W - 2))

    # --- efficiency summary ---
    conn_r = next((r for r in results
                   if r.get('test') == 'connect' and 'connect_ms' in r
                   and not r.get('error')), None)
    if conn_r:
        rtt_s       = conn_r['connect_ms'] / 1000
        half_rtt_s  = rtt_s / 2
        # Each ARDOP frame carries up to MTU bytes in one direction.
        # raw capacity = MTU * 8 / half_rtt  (single-direction throughput).
        raw_bps     = round(508 * 8 / half_rtt_s) if half_rtt_s > 0 else 0
        print()
        print(f'  Estimated half-RTT:       {half_rtt_s:.1f} s  '
              f'(from connect time {_ms(conn_r["connect_ms"])})')
        print(f'  Raw frame capacity (est): {_bps(raw_bps)}  (508 B / {half_rtt_s:.1f} s)')

        best_bps = max(
            (r.get('goodput_bps', 0) for r in results if not r.get('error')),
            default=0,
        )
        if best_bps and raw_bps:
            eff = round(best_bps / raw_bps * 100)
            print(f'  Best observed goodput:    {_bps(best_bps)}  ({eff}% of raw frame capacity)')
            if eff < 30:
                print('  ↳ Low efficiency — ACK overhead dominates; try larger transfer sizes.')
            elif eff < 60:
                print('  ↳ Moderate efficiency — typical for half-duplex with TCP ACKs.')
            else:
                print('  ↳ Good efficiency.')

    print()
    print('  Optimization levers:')
    print('    --nodelay                              disable Nagle (echo/reqresp)')
    print('    --fecmode 4PSK.500.100                narrower BW, more robust')
    print('    ardop-setup.sh --fecmode 8PSK.2000.100  higher throughput attempt')
    print()
    print('  Live diagnostics:')
    print(f'    ip netns exec {ns_a} ss -t -i dst {addr_b}    # cwnd, RTT, retransmits')
    print(f'    ip netns exec {ns_a} tc -s qdisc show dev tnc0  # TX queue depth')
    print()
    print('=' * W)
    print()


# ── argument parsing + dispatch ────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description='TCP link performance tests',
        add_help=False,
    )
    # internal modes
    ap.add_argument('--server',   nargs=2, metavar=('PORT', 'SCENARIO'))
    ap.add_argument('--client',   nargs=3, metavar=('HOST', 'PORT', 'SCENARIO'))
    # orchestrator options
    ap.add_argument('--ns-a',     default='ns_a')
    ap.add_argument('--ns-b',     default='ns_b')
    ap.add_argument('--addr-a',   default='10.0.0.1')
    ap.add_argument('--addr-b',   default='10.0.0.2')
    ap.add_argument('--tests',    default=','.join(ALL_TESTS))
    ap.add_argument('--nodelay',  action='store_true')
    ap.add_argument('--timeout',  type=int, default=300)
    ap.add_argument('--help', '-h', action='store_true')
    args = ap.parse_args()

    if args.help:
        print(__doc__)
        sys.exit(0)

    # ── internal: server mode ──────────────────────────────────────────────────
    if args.server:
        port, scenario = int(args.server[0]), args.server[1]
        run_server(port, scenario, args.nodelay)
        return

    # ── internal: client mode ──────────────────────────────────────────────────
    if args.client:
        host, port, scenario = args.client[0], int(args.client[1]), args.client[2]
        run_client(host, port, scenario, args.nodelay)
        return

    # ── orchestrator ───────────────────────────────────────────────────────────
    if os.geteuid() != 0:
        sys.exit('ERROR: orchestrator must run as root (sudo)')

    tests = [t.strip() for t in args.tests.split(',') if t.strip()]
    bad   = [t for t in tests if t not in ALL_TESTS]
    if bad:
        sys.exit(f'ERROR: unknown test(s): {", ".join(bad)}\n'
                 f'Available: {", ".join(ALL_TESTS)}')

    preflight(args.ns_a, args.ns_b)
    tune_tcp_for_ardop(args.ns_a, args.ns_b, args.addr_a, args.addr_b)

    nd_note = '  TCP_NODELAY on' if args.nodelay else ''
    print(f'Running {len(tests)} test(s): {", ".join(tests)}{nd_note}')
    print(f'Namespace: {args.ns_a} ({args.addr_a}) → {args.ns_b} ({args.addr_b})')
    print(f'Per-test timeout: {args.timeout} s')
    print()

    results: list[dict] = []
    for i, test in enumerate(tests):
        print(f'  [{i+1}/{len(tests)}] {test}...', end=' ', flush=True)
        m = run_one(test, args.ns_a, args.ns_b, args.addr_b,
                    args.nodelay, args.timeout)
        if m.get('error'):
            print(f'ERROR: {m["error"]}')
        elif test == 'connect':
            print(f'connected in {_ms(m.get("connect_ms"))}')
        elif test == 'echo':
            print(f'mean RTT {_ms(m.get("mean_rtt_ms"))}')
        else:
            print(f'{m.get("duration_s", "?"):.1f} s  '
                  f'{_bps(m.get("goodput_bps"))}')
        results.append(m)
        if i < len(tests) - 1:
            time.sleep(45)  # drain leftover SYN retransmits + FIN/ACK teardown frames
                            # (~8 s/frame × 5 frames max = 40 s; 45 s gives 5 s margin)

    print_report(results, args.nodelay, args.ns_a, args.ns_b, args.addr_a, args.addr_b)


if __name__ == '__main__':
    main()
