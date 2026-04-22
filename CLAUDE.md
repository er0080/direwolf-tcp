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
| `scripts/ardop-setup.sh` | ARDOP branch: launches ardopcf × 2 + KISS bridges × 2 + namespaces + tncattach |
| `scripts/ardop-teardown.sh` | Stops all ARDOP processes and cleans up namespaces |
| `scripts/ardop-test.sh` | Pre-flight checks for ARDOP RF link, pings both ways at 5-second interval |
| `scripts/ardop_kiss_bridge.py` | Python asyncio bridge: ARDOP FEC datagram ↔ standard KISS TCP (so tncattach works) |
| `ardopcf/` | ardopcf submodule (git clone of github.com/pflarue/ardop); build with `cd ardopcf && make` |
| `tests/test_ardop_kiss_bridge.py` | Unit tests for bridge KISS/ARDOP framing helpers (24 tests) |
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
- **ARDOP does not use standard KISS**: ardopcf speaks a proprietary host protocol (text commands on port N, length-prefixed binary frames on port N+1). `ardop_kiss_bridge.py` bridges this to standard KISS TCP so tncattach works unchanged. The bridge operates ardopcf in FEC (datagram) mode.
- **ardopcf PTT must be handled by the bridge, not ardopcf**: ardopcf's `OpenCOMPort` uses `O_NDELAY` and calls `COMClearDTR()` at startup. This sends `SET_CONTROL_LINE_STATE(DTR=0)` to CDC-ACM USB devices (IC-705 ttyACM), which interpret DTR=0 as "no host connected" and ignore all subsequent RTS changes. ardopcf's CI-V PTT (`-c --keystring`) has the same problem for ttyACM. The fix: run ardopcf without any PTT flag so it sends `PTT TRUE`/`PTT FALSE` to the host (bridge). The bridge handles PTT via pyserial RTS (`--ptt-port`), which sets DTR=True on open — radios respond correctly. IC-7300 (ttyUSB/FTDI) is unaffected by the DTR issue but uses bridge PTT for consistency. Both radios must have `SET → Connectors → USB SEND → RTS`.
- **ARDOP FEC vs ARQ**: FEC mode = connectionless datagrams (same model as Direwolf, no guaranteed delivery). ARQ mode = connected session with automatic retransmission but requires establishing a connection — not compatible with raw IP datagrams via tncattach. The bridge uses FEC mode.
- **ardop-test.sh uses --interval 5**: ARDOP frame overhead is higher than Direwolf (leader + FEC blocks); RTT may exceed 3s depending on FECMODE. Default 5-second interval prevents transmit queue stacking.
- **Run unit tests before field testing**: `python3 -m unittest discover -s tests -p "test_*.py"` validates all KISS/ARDOP framing helpers without hardware.
