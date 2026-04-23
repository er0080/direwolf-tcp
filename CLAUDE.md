# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Test framework for a simulated point-to-point TCP/IP link using two Direwolf TNC instances connected by PipeWire virtual audio cables, with `tncattach` creating `/30` network interfaces over KISS-over-TCP. No real radio hardware is required.

See `README.md` for full architecture, setup steps, and tuning notes.

## Key Components and Their Roles

| Component | Role |
|-----------|------|
| Direwolf A (`config/dw-a.conf`) | Modem instance A — KISS TCP port 8001, AGWPORT 8000, `ADEVICE default default` |
| Direwolf B (`config/dw-b.conf`) | Modem instance B — KISS TCP port 8002, AGWPORT 8010, `ADEVICE default default` |
| PipeWire null sinks | `dw_a_to_b` and `dw_b_to_a` — virtual full-duplex audio cable |
| `scripts/setup.sh` | Creates sinks, launches direwolf, routes audio streams, creates namespaces, attaches tncattach |
| `scripts/rf-setup.sh` | RF variant: launches Direwolf for IC-705 (ports 8000/8001) and IC-7300 (ports 8100/8101), creates namespaces, attaches tncattach — no PipeWire involved |
| `scripts/rf-teardown.sh` | Stops RF Direwolf instances and tncattach, removes namespaces |
| `scripts/rf-test.sh` | Pre-flight checks for RF link (interfaces, KISS ports, serial devices) then pings both ways |
| tncattach (`tncattach/tncattach`) | Bridges KISS/TCP → TAP interfaces; built from git submodule |
| Network namespaces | `ns_a` holds `tnc0` (10.0.0.1), `ns_b` holds `tnc1` (10.0.0.2) |

## Audio Wiring

```
Direwolf A TX → dw_a_to_b (sink) → dw_a_to_b.monitor → Direwolf B RX
Direwolf B TX → dw_b_to_a (sink) → dw_b_to_a.monitor → Direwolf A RX
```

Audio routing is done at runtime by `setup.sh` using `pactl move-sink-input` and `pactl move-source-output` — no `~/.asoundrc` changes are required. The system runs PipeWire with a PulseAudio compatibility layer; all `pactl` commands work as-is. PipeWire's ALSA clients do not expose `application.process.id`, so streams are identified by a before/after snapshot diff of sink-input and source-output IDs.

## Network Namespace Design

Both `10.0.0.1` (tnc0) and `10.0.0.2` (tnc1) would be LOCAL addresses in the same kernel routing table, causing ICMP replies to be delivered internally rather than traversing the radio chain. Each tncattach interface is moved into its own namespace (`ip link set tncN netns ns_X`) after creation. TAP file descriptors remain valid across namespace moves, so tncattach continues to function in the host namespace while the interface and its routing table are isolated.

## Common Commands

### Full setup
```bash
sudo ./scripts/setup.sh
```

### Test connectivity
```bash
sudo ./scripts/test.sh
ip netns exec ns_a ping -c 4 10.0.0.2   # A→B
ip netns exec ns_b ping -c 4 10.0.0.1   # B→A
```

### Teardown
```bash
sudo ./scripts/teardown.sh
```

### Build tncattach (first time only)
```bash
git submodule update --init
cd tncattach && make
```

### Diagnostics
```bash
ss -tlnp | grep -E '800[12]'                    # confirm KISS TCP ports
pactl list short sinks | grep dw_               # confirm audio sinks
ip netns exec ns_a ip addr show tnc0            # check tnc0 address
ip netns exec ns_b ip addr show tnc1            # check tnc1 address
tail -f logs/dw-a.log                           # direwolf A output
tail -f logs/dw-b.log                           # direwolf B output
```

## Critical Configuration Constraints

- **PACLEN and MTU must match**: `PACLEN` in direwolf.conf must equal `tncattach --mtu` + 4. Current values: `PACLEN 240`, `--mtu 236`.
- **No PTT line**: Omit `PTT` from direwolf configs — there is no radio hardware to key.
- **`--noipv6` on tncattach**: Required to prevent IPv6 neighbor discovery from flooding the 1200-baud link.
- **AGWPORT must differ** between the two instances (8000 vs 8010) to avoid port conflicts on the same host.
- **pactl must run as the desktop user**: PipeWire sockets belong to the user session. When running under `sudo`, all `pactl` calls use `sudo -u $REAL_USER XDG_RUNTIME_DIR=/run/user/$REAL_UID pactl`.
- **Network namespaces are required**: Do not remove them. Without isolation, ICMP replies are locally delivered and pings fail with 100% packet loss.
- **`FULLDUP ON` is required**: Direwolf defaults to half-duplex CSMA. Without it, Direwolf waits for channel silence + random backoff before transmitting, causing ~2200 ms latency and ~40–60% packet loss even though the virtual audio paths are fully independent. `FULLDUP ON` bypasses CSMA entirely. Direwolf 1.7 requires `ON`/`OFF` — `1`/`0` is silently rejected with a startup error.
- **Audio volume must be 65%**: At 100% sink volume, Direwolf's input level is ~199 (clipping), causing all frames to fail CRC. PipeWire's volume is cubic: `gain = (pct/100)³`, so 65% → gain ≈ 0.27× → level ≈ 55. `setup.sh` sets this automatically.
- **Sample rate must be 48000 Hz**: Null sinks and `ARATE` must both use 48000 Hz to match PipeWire's native rate. Mismatches cause resampling artifacts that corrupt AFSK decoding.
- **`config/dw-rf.conf` is an RF deployment template**: do not modify it for virtual-testing purposes. The virtual test framework uses `dw-a.conf` / `dw-b.conf` only.
- **`(Not AX.25)` log messages are expected**: tncattach sends raw IP through KISS without AX.25 headers. Direwolf logs these as `(Not AX.25)` but still forwards them to the KISS client. This is normal for this setup.
- **Asymmetric DWAIT on RF**: `config/dw-705.conf` uses `DWAIT 5` (50 ms post-DCD delay); `config/dw-7300.conf` uses `DWAIT 0`. This gives IC-7300 priority — it wins the channel whenever both radios have queued frames. Do not set both to the same DWAIT value or collisions will recur.
- **RF ping interval must exceed RTT**: At 2400 baud QPSK with TXDELAY 20 + TXTAIL 10, frame air time is ~860 ms and RTT is ~1700 ms. Using `ping -i 1` (default) causes the transmit queue to grow and produces back-to-back collisions. Always use `ping -i 3` or longer when testing the RF link.
- **KISS has no flow control**: tncattach can feed frames faster than the radio can transmit. For sustained traffic, rate-limit with `tc tbf`. TCP self-limits via congestion control; ICMP does not.
- **2400 QPSK requires matched SSB filter bandwidth**: Both radios must have TX bandwidth wide enough (~2.4 kHz) and matched. A narrower filter on the transmitting radio will cause systematic FEC corrections on every received frame even at correct audio levels.

## ardop-ip Branch (ARDOP-tcpip)

Second-generation implementation: a single binary (`ardop-ip`) forked from
`ardopc` that owns its own TUN interface and uses ARDOP's OFDM PHY + ARQ
directly instead of going through KISS/Direwolf. Files live under `src/` and
the ARDOP sources are a submodule at `src/ardopc/`. Build with `make ardop-ip`.

### ardop-ip — RF test scripts

| Script | Purpose |
|--------|---------|
| `scripts/rf-ardop-ip-smoke.sh` | Quick 3-ping link check (~4 min) |
| `scripts/rf-ardop-ip-baseline.sh` | Fail-fast single-shot suite: ping reliability, TCP connect, UDP 1024 B, MTU 1432 (~10 min) |
| `scripts/rf-ardop-ip-stress.sh` | 5-min ping soak + post-soak MTU check (~7 min) |

Config: `config/ardop-ip-rf.conf`. All three scripts are sudo + namespace-based
and require `/dev/ic_705_a`, `/dev/ic_7300` udev aliases plus `CODEC_705` /
`CODEC_7300` ALSA cards. Each test is single-shot — on failure the suite exits
immediately so the bug can be investigated. Never re-run with retry loops.

### ardop-ip — Critical constraints (RF only)

- **CI-V port raises DTR on open**: Linux's default tty open asserts DTR (and
  RTS). The IC-705 / IC-7300 "USB Send" menus map DTR → PTT, so opening the
  CI-V port would key the radio for the entire session until close. Fixed in
  `src/civ_control.c::civ_open()` with `TIOCMBIC` right after `OpenCOMPort`.
- **CI-V PTT-off on exit**: `ardop-ip` installs a SIGINT/SIGTERM handler that
  writes the CI-V PTT-off frame synchronously (via `write()`, which is
  async-signal-safe), plus an `atexit()` hook. The cleanup in each test script
  also sends a direct CI-V rescue frame after SIGKILL. A stuck-key radio is
  always a bug — if it happens, something bypassed both paths.
- **TUN poll ordering matters**: In `ardopmain()` the loop is
  `TUNHostPoll → PollReceivedSamples → … → TUNHostPoll`. The pre-poll is
  load-bearing: without it, the IRS sees a stale `bytDataToSendLength=0`
  when processing a received IDLE, ACKs instead of BREAKing, and the kernel's
  just-queued reply (SYN-ACK, ICMP reply) sits in the TUN buffer indefinitely.
  A redundant call at the top of the IDLE handler in `ARQ.c` is belt and
  suspenders.
- **Fail-fast test philosophy**: Test scripts use `fail() { echo FAIL; exit 1; }`
  — any test that misses its acceptance criterion stops the suite. Previous
  `return "$rc"` in EXIT traps occasionally turned PASS into exit-1; all three
  scripts now use `exit "$rc"` in the cleanup trap.
- **UDP for throughput tests**: TCP's `tcp_syn_retries`-based abort timer
  (~127 s) is shorter than the worst-case ARDOP RTT on multi-frame transfers,
  so sustained TCP bulk transfers abort mid-handshake. UDP avoids this; use
  TCP for control-plane tests only (e.g. single `nc -zv`).
- **Goodput ceiling on 14.103 MHz with default gearshift**: ~125 bps raw during
  active transfer, ~40 bps end-to-end including ARQ establishment. PSK16 +
  single-frame ARQ window. Higher throughput requires ARDOP protocol work
  (ARQ window > 1, 16QAM/32QAM modes) — see Phase 5b in the plan.
- **Radio setup**: Both radios on 14.103 MHz USB-D, matched SSB TX filter ≥
  2.4 kHz, TX power ≤ 5 W for same-building testing.
- **Phase 6.2b wire-format break — carrier-count signalling byte**: ardop-ip
  emits one extra 4FSK byte (4 symbols @ 50 baud, ~80 ms, 960 samples @
  12 kHz) between the leader/SYNC/2-byte frame-type and the OFDM reference
  symbol, carrying `(carriers_sent - 1)` in bits 0..5 with a 2-bit parity
  in bits 6..7 computed by `ComputeTypeParity`.  The decoder reads the
  byte in the new `AcquireCarrierCount` state and overrides `intNumCar`
  before `InitDemodOFDM` runs.  This is an on-air wire-format break vs.
  Phase 6.1 and earlier peers (upstream ardopc): they have no state to
  consume the extra 4FSK byte and will see misaligned OFDM reference
  samples, leading to failed decodes.  BOTH ends must run Phase 6.2b or
  later.  Non-OFDM frames (4PSK, 4FSK control, QAM, OFDMACK, Pkt*) are
  unaffected — the byte is only inserted for OFDM data frames
  (strMod == "OFDM" AND IsDataFrame).
- **Phase 6.2b parity is detect-only**: the 2-bit parity field catches
  single bit errors but cannot correct them.  A corrupted signalling byte
  causes the RX to drop the frame and fall through to the sender's
  frame-repeat path.  On-air bit-error robustness is validated by the
  Phase 6.5 RF test suite.
