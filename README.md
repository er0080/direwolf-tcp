# direwolf-tcp

Point-to-point TCP/IP link test framework using [Direwolf](https://github.com/wb2osz/direwolf) TNC software, PipeWire/PulseAudio virtual audio cables, and [tncattach](https://github.com/markqvist/tncattach).

Two Direwolf instances simulate a full-duplex radio link over virtual audio. Each instance exposes a KISS-over-TCP port. `tncattach` binds those ports to Linux network interfaces, creating a routable `/30` point-to-point IP link — all without real radio hardware.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Single Linux Host                           │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ netns ns_a                                                   │    │
│  │   tnc0  10.0.0.1/30  ◄── tncattach fd ──► KISS/TCP:8001    │    │
│  └──────────────────────────────────┬────────────────┬─────────┘    │
│                           IP in/out │                │ KISS frames   │
│                                     │       ┌────────▼───────────┐  │
│                                     │       │    Direwolf A      │  │
│                                     │       │  ADEVICE default   │  │
│                                     │       └──────┬─────────────┘  │
│                                     │     TX audio │  ▲ RX audio    │
│                                     │   dw_a_to_b  │  │ dw_b_to_a  │
│                                     │       ┌──────▼──┴──────────┐  │
│                                     │       │  PipeWire null sinks│  │
│                                     │       │  dw_a_to_b         │  │
│                                     │       │  dw_b_to_a         │  │
│                                     │       └──────┬─────────────┘  │
│                                     │     RX audio │  ▲ TX audio    │
│                                     │   dw_a_to_b  │  │ dw_b_to_a  │
│                                     │       ┌──────▼─────────────┐  │
│                                     │       │    Direwolf B      │  │
│                                     │       │  ADEVICE default   │  │
│                                     │       └────────┬───────────┘  │
│                                     │                │ KISS frames   │
│  ┌──────────────────────────────────▼────────────────┴─────────┐    │
│  │ netns ns_b                                                   │    │
│  │   tnc1  10.0.0.2/30  ◄── tncattach fd ──► KISS/TCP:8002    │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

**Data flow (A→B ping):**
1. `ping` in `ns_a` sends ICMP echo request via `tnc0`
2. tncattach A wraps the IP packet in a KISS frame → Direwolf A (port 8001)
3. Direwolf A modulates AFSK audio → writes to `dw_a_to_b` PipeWire null sink
4. Direwolf B reads from `dw_a_to_b.monitor` → demodulates → KISS frame → tncattach B
5. tncattach B injects IP packet into `tnc1` inside `ns_b`
6. Kernel in `ns_b` generates ICMP reply; reply travels back via the same chain in reverse

**Why network namespaces?** Without isolation, both `10.0.0.1` and `10.0.0.2` are LOCAL addresses in the same kernel routing table. The kernel short-circuits ICMP replies via local delivery instead of routing them back through the radio chain — causing 100% packet loss. Each namespace has an isolated routing table with no conflicting entries.

**TAP fd across namespaces:** tncattach runs in the host namespace (connecting to `localhost` KISS ports normally). After the `tnc` interface is created, `setup.sh` moves it into the appropriate namespace with `ip link set tncN netns ns_X`. TAP file descriptors remain valid across namespace moves, so tncattach continues to read/write packets without modification.

---

## Prerequisites

```bash
# Debian/Ubuntu
sudo apt install direwolf pipewire-pulse \
                 build-essential git net-tools iproute2 iputils-ping
```

> **PipeWire note:** This framework runs on PipeWire with its PulseAudio compatibility layer. `pactl` commands work as-is. No `~/.asoundrc` changes or ALSA-pulse plugin are needed.

**tncattach** is included as a git submodule. Build it once after cloning:

```bash
git submodule update --init
cd tncattach && make
```

---

## Quick Start

All setup, testing, and teardown is handled by scripts in `scripts/`. They require `sudo`.

```bash
# Bring everything up
sudo ./scripts/setup.sh

# Run connectivity tests
sudo ./scripts/test.sh

# Tear everything down
sudo ./scripts/teardown.sh
```

---

## What `setup.sh` Does

1. **Virtual audio sinks** — creates two PipeWire null sinks (`dw_a_to_b`, `dw_b_to_a`) at 48000 Hz via `pactl`; sets each to 65% volume to keep Direwolf's input level ~55 (target: ~50)
2. **Direwolf A** — launches with `ADEVICE default default`; after startup, moves its audio streams to the correct sinks via `pactl move-sink-input` / `pactl move-source-output`
3. **Direwolf B** — same, with audio wired in the opposite direction
4. **Namespaces** — creates `ns_a` and `ns_b` with isolated routing tables
5. **tncattach A** — connects to `localhost:8001`; the resulting `tnc0` is moved into `ns_a` and configured as `10.0.0.1 ↔ 10.0.0.2`
6. **tncattach B** — connects to `localhost:8002`; the resulting `tnc0` (re-created after A's was moved) is moved into `ns_b`, renamed `tnc1`, and configured as `10.0.0.2 ↔ 10.0.0.1`

---

## Testing

`test.sh` checks interfaces, KISS ports, audio sinks, then runs pings both ways:

```bash
sudo ./scripts/test.sh
# or with a custom count:
sudo ./scripts/test.sh --count 10
```

Manual ping:
```bash
ip netns exec ns_a ping -c 4 10.0.0.2   # A→B
ip netns exec ns_b ping -c 4 10.0.0.1   # B→A
```

Manual throughput test:
```bash
ip netns exec ns_b iperf3 -s -B 10.0.0.2 &
ip netns exec ns_a iperf3 -c 10.0.0.2
```

Expected throughput at 1200 baud AFSK is approximately 100–150 bytes/sec effective payload.

---

## Port and Address Reference

| Component         | Parameter     | Value              |
|-------------------|---------------|--------------------|
| Direwolf A        | AGWPORT       | 8000               |
| Direwolf A        | KISSPORT      | 8001               |
| Direwolf B        | AGWPORT       | 8010               |
| Direwolf B        | KISSPORT      | 8002               |
| tncattach A       | Interface     | tnc0 (in ns_a)     |
| tncattach A       | IPv4          | 10.0.0.1/30        |
| tncattach A       | Peer          | 10.0.0.2           |
| tncattach B       | Interface     | tnc1 (in ns_b)     |
| tncattach B       | IPv4          | 10.0.0.2/30        |
| tncattach B       | Peer          | 10.0.0.1           |
| PipeWire sink     | A→B           | dw_a_to_b          |
| PipeWire monitor  | B reads A TX  | dw_a_to_b.monitor  |
| PipeWire sink     | B→A           | dw_b_to_a          |
| PipeWire monitor  | A reads B TX  | dw_b_to_a.monitor  |

---

## Tuning Notes

- **PACLEN vs MTU**: `PACLEN` in direwolf.conf must equal `tncattach --mtu` + 4. Current values: `PACLEN 240`, `--mtu 236`.
- **FULLDUP ON**: Required for this virtual loopback setup. Direwolf defaults to half-duplex CSMA (listen-before-talk with random backoff). Since A's TX and B's TX use separate, independent audio paths, there is no real contention — but without `FULLDUP ON`, Direwolf still waits for channel silence and random slot delays, causing ~2200 ms latency and ~40–60% packet loss. `FULLDUP ON` bypasses CSMA and transmits immediately, yielding the expected ~1300 ms RTT (two back-to-back 900 ms transmissions at 1200 baud). Note: Direwolf 1.7 requires `ON`/`OFF` — `1`/`0` is silently rejected. Do not use `FULLDUP ON` on a real shared radio channel.
- **TXDELAY/TXTAIL**: Values of 3 (= 30 ms) are sufficient with no real PTT hardware. Real radio use requires 300 ms+ depending on the radio.
- **`--noipv6`**: Prevents IPv6 neighbor discovery from consuming bandwidth on the 1200-baud link.
- **Audio level**: Direwolf recommends an input level of ~50. At 100% sink volume the level is ~199 (clipping), which corrupts the AFSK waveform and causes every frame to fail AX.25 CRC. PipeWire applies volume on a **cubic curve**: `gain = (pct/100)³`, so `25%` → gain 0.016×, not 0.25×. `setup.sh` sets sinks to 65% (gain ≈ 0.27×, level ≈ 55). If decode problems recur, check `logs/dw-*.log` for `audio level =` and re-tune: `target_pct = (target_level / current_level_at_100pct)^(1/3) × 100`.
- **Audio stream routing**: `setup.sh` identifies each direwolf's PipeWire streams by taking a before/after snapshot of sink-input and source-output IDs. PipeWire's ALSA layer does not expose `application.process.id` for ALSA clients, so PID-based matching does not work.
- **Modem speed**: `MODEM 1200` (Bell 202 AFSK) on both instances. They must match.
- **`(Not AX.25)` log messages**: tncattach passes raw IP packets through KISS without AX.25 callsign headers. Direwolf logs every received frame that doesn't parse as AX.25 as `(Not AX.25)` — this is expected and harmless. Direwolf still forwards the decoded frame to the KISS client (tncattach). These messages do not indicate packet loss.
- **Sample rate**: Both null sinks and both Direwolf instances use 48000 Hz (`ARATE 48000`). This matches PipeWire's native rate and avoids a resampling stage that could introduce audio artifacts.

---

## RF Deployment

`config/dw-rf.conf` is a ready-to-edit template for deploying one station on a real half-duplex radio link. Copy it to each machine, customise the fields marked with `←`, and point tncattach at `localhost:8001`.

### What changes from the virtual setup

| Parameter | Virtual | RF | Why |
|-----------|---------|-----|-----|
| `ADEVICE` | `default default` | `plughw:1,0 plughw:1,0` | Real sound card; PipeWire null sinks don't exist on RF machines |
| `ARATE` | `48000` | Match card native rate | Avoid resampling artifacts |
| `FULLDUP` | `ON` | **Omitted** (defaults OFF) | Radio is half-duplex; one station at a time |
| `TXDELAY` | `3` (30 ms) | `20` (200 ms) | Time for PTT to key up the radio before audio starts |
| `TXTAIL` | `3` (30 ms) | `5` (50 ms) | Audio decay time before PTT drops and radio returns to RX |
| `PERSIST` | not set | `255` | See below |
| `SLOTTIME` | not set | `1` (10 ms) | See below |
| `PTT` | omitted | hardware-specific | Must key the radio |

### PERSIST and SLOTTIME for a dedicated P2P link

Direwolf's default CSMA algorithm (p-persistent) draws a random number each slot and transmits only if it beats PERSIST. This is designed to reduce collisions on **shared** channels with many stations. On a **dedicated** point-to-point link there is no other traffic to collide with, so the random backoff only adds latency.

Setting `PERSIST 255` tells Direwolf to transmit immediately whenever it detects the channel is clear — no random wait. `SLOTTIME 1` (10 ms) adds just enough jitter that if both ends see the channel go clear at the exact same moment (possible during TCP bulk transfers with simultaneous data and ACK) they won't both fire in the same audio sample.

For a **shared** channel, lower PERSIST (e.g. 63) and increase SLOTTIME (e.g. 10–20) to reduce collision probability.

### PTT hardware options

```
PTT  /dev/ttyUSB0  RTS          # serial port, RTS pin
PTT  /dev/ttyUSB0  DTR          # serial port, DTR pin
PTT  /dev/ttyUSB0  RTS -        # add "-" to invert polarity
PTT  GPIO 17                    # Raspberry Pi BCM pin 17
PTT  GPIO -18                   # BCM pin 18, active-low
PTT  CM108                      # CM108/CM119 USB audio chip GPIO
```

### Audio levels on RF

Do **not** use the 65% PipeWire volume trick — that's specific to the virtual null-sink setup. On RF hardware, tune your radio's mic gain until Direwolf's log shows `audio level = ~50`. Too high causes AFSK clipping and CRC failures; too low causes missed frames.

### Expected performance

At 1200 baud AFSK with PERSIST 255 / SLOTTIME 1:

- **RTT**: ~1500–1700 ms (two back-to-back 900 ms transmissions + real TXDELAY/TXTAIL, no CSMA wait)
- **ICMP ping**: will show occasional packet loss — this is normal for any half-duplex RF medium
- **TCP**: handles retransmission at the transport layer; file transfers and SSH sessions work reliably despite occasional frame loss at the radio layer

---

## References

- [Direwolf](https://github.com/wb2osz/direwolf) — WB2OSZ
- [tncattach](https://github.com/markqvist/tncattach) — Mark Qvist
- [PipeWire](https://pipewire.org/) / PulseAudio compatibility layer
- [Direwolf User Guide](https://github.com/wb2osz/direwolf/tree/master/doc)
