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

1. **Virtual audio sinks** — creates two PipeWire null sinks (`dw_a_to_b`, `dw_b_to_a`) via `pactl`
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
- **TXDELAY/TXTAIL**: Values of 3 (= 30 ms) are sufficient with no real PTT hardware. Real radio use requires 300 ms+ depending on the radio.
- **`--noipv6`**: Prevents IPv6 neighbor discovery from consuming bandwidth on the 1200-baud link.
- **Audio level**: Direwolf may warn "Audio input level is too high." This is cosmetic at loopback levels — decoding still works. Reduce the null sink volume with `pactl set-sink-volume dw_a_to_b 50%` if desired.
- **Audio stream routing**: `setup.sh` identifies each direwolf's PipeWire streams by taking a before/after snapshot of sink-input and source-output IDs. PipeWire's ALSA layer does not expose `application.process.id` for ALSA clients, so PID-based matching does not work.
- **Modem speed**: `MODEM 1200` (Bell 202 AFSK) on both instances. They must match.

---

## References

- [Direwolf](https://github.com/wb2osz/direwolf) — WB2OSZ
- [tncattach](https://github.com/markqvist/tncattach) — Mark Qvist
- [PipeWire](https://pipewire.org/) / PulseAudio compatibility layer
- [Direwolf User Guide](https://github.com/wb2osz/direwolf/tree/master/doc)
