# direwolf-tcp

Point-to-point TCP/IP link test framework using [Direwolf](https://github.com/wb2osz/direwolf) TNC software, PulseAudio virtual audio cables, and [tncattach](https://github.com/markqvist/tncattach).

Two Direwolf instances simulate a full-duplex radio link over virtual audio. Each instance exposes a KISS-over-TCP port. `tncattach` binds those ports to Linux network interfaces, creating a routable `/30` point-to-point IP link — all without real radio hardware.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Single Linux Host                        │
│                                                                 │
│  ┌──────────────┐    KISS/TCP:8001    ┌────────────────────┐   │
│  │  tncattach   │◄──────────────────►│    Direwolf A      │   │
│  │  tnc0        │                    │  MYCALL N0CALL-1   │   │
│  │  10.0.0.1/30 │                    │  ADEVICE dw_a_rx   │   │
│  └──────────────┘                    │          dw_a_tx   │   │
│                                      └────────┬───────────┘   │
│                                        RX from│  │TX to        │
│                                  dw_b_to_a.mon│  │dw_a_to_b    │
│                                               │  │             │
│                   ┌───────────────────────────┘  │             │
│                   │   PulseAudio Virtual Audio    │             │
│                   │   ┌──────────────────────┐   │             │
│                   │   │  null sink dw_a_to_b │◄──┘             │
│                   │   │  null sink dw_b_to_a │                 │
│                   │   └──────────────────────┘                 │
│                   │                           │                 │
│                   ▼ dw_a_to_b.monitor         ▼ dw_b_to_a      │
│                   ┌────────────────────────────────────────┐   │
│                   │    Direwolf B                          │   │
│                   │  MYCALL N0CALL-2                       │   │
│                   │  ADEVICE dw_b_rx  dw_b_tx              │   │
│                   └────────────────┬───────────────────────┘   │
│                          KISS/TCP:8002                          │
│                   ┌────────────────▼───────────────────────┐   │
│                   │  tncattach  tnc1  10.0.0.2/30          │   │
│                   └────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

**Data flow (A→B):** `ping` on `tnc0` → tncattach wraps IP in AX.25 → KISS/TCP to Direwolf A → Direwolf A modulates to AFSK audio → written to `dw_a_to_b` PulseAudio null sink → Direwolf B reads from `dw_a_to_b.monitor` → demodulates → KISS/TCP to tncattach on `tnc1` → IP packet delivered.

---

## Prerequisites

### Packages

```bash
# Debian/Ubuntu
sudo apt update
sudo apt install direwolf pulseaudio pulseaudio-utils \
                 build-essential git net-tools iputils-ping
```

### tncattach

```bash
git clone https://github.com/markqvist/tncattach.git
cd tncattach
make
sudo make install
```

---

## Setup

### 1. Create PulseAudio Virtual Audio Cables

Two null sinks model the full-duplex audio path between the two Direwolf instances.

```bash
# A→B direction: Direwolf A transmits, Direwolf B receives
pactl load-module module-null-sink \
    sink_name=dw_a_to_b \
    rate=44100 \
    sink_properties=device.description="DW_A_to_B"

# B→A direction: Direwolf B transmits, Direwolf A receives
pactl load-module module-null-sink \
    sink_name=dw_b_to_a \
    rate=44100 \
    sink_properties=device.description="DW_B_to_A"
```

Verify:
```bash
pactl list short sinks | grep dw_
pactl list short sources | grep dw_
# Expect: dw_a_to_b, dw_b_to_a (sinks) and their .monitor sources
```

### 2. Configure ALSA/PulseAudio Shims

Add to `~/.asoundrc`:

```
# Direwolf A: TX into dw_a_to_b, RX from dw_b_to_a.monitor
pcm.dw_a_tx { type pulse; device "dw_a_to_b"; }
pcm.dw_a_rx { type pulse; device "dw_b_to_a.monitor"; }

# Direwolf B: TX into dw_b_to_a, RX from dw_a_to_b.monitor
pcm.dw_b_tx { type pulse; device "dw_b_to_a"; }
pcm.dw_b_rx { type pulse; device "dw_a_to_b.monitor"; }
```

### 3. Direwolf Configuration Files

**`config/dw-a.conf`** — Direwolf instance A:

```
ADEVICE  dw_a_rx  dw_a_tx

CHANNEL 0
MYCALL  N0CALL-1
MODEM   1200
TXDELAY 3
TXTAIL  3
PACLEN  240

AGWPORT 8000
KISSPORT 8001
```

**`config/dw-b.conf`** — Direwolf instance B:

```
ADEVICE  dw_b_rx  dw_b_tx

CHANNEL 0
MYCALL  N0CALL-2
MODEM   1200
TXDELAY 3
TXTAIL  3
PACLEN  240

AGWPORT 8010
KISSPORT 8002
```

> `TXDELAY`/`TXTAIL` are in units of 10 ms. Values of 3 = 30 ms each are sufficient with no real PTT hardware. No `PTT` line is needed; omitting it disables PTT keying.

### 4. Launch Direwolf Instances

```bash
direwolf -c config/dw-a.conf &
direwolf -c config/dw-b.conf &
```

Confirm both KISS TCP ports are listening:
```bash
ss -tlnp | grep -E '800[12]'
```

### 5. Attach Network Interfaces with tncattach

```bash
# Interface tnc0 for Direwolf A — IP 10.0.0.1, peer 10.0.0.2
sudo tncattach -T -H localhost -P 8001 --mtu 236 --noipv6 --noup
sudo ifconfig tnc0 10.0.0.1 pointopoint 10.0.0.2 netmask 255.255.255.252 up

# Interface tnc1 for Direwolf B — IP 10.0.0.2, peer 10.0.0.1
sudo tncattach -T -H localhost -P 8002 --mtu 236 --noipv6 --noup
sudo ifconfig tnc1 10.0.0.2 pointopoint 10.0.0.1 netmask 255.255.255.252 up
```

Verify interfaces are up:
```bash
ip addr show tnc0
ip addr show tnc1
```

---

## Testing

### Ping

```bash
# Send ICMP from tnc0 (10.0.0.1) to tnc1 (10.0.0.2)
ping -c 4 -I tnc0 10.0.0.2

# Reverse direction
ping -c 4 -I tnc1 10.0.0.1
```

Each round-trip traverses: tncattach → KISS/TCP → Direwolf modulate → PulseAudio null sink → PulseAudio monitor → Direwolf demodulate → KISS/TCP → tncattach.

### Throughput

```bash
# Rough bandwidth test (requires iperf3 on both "ends")
# Since both sides are on the same host, use network namespaces or
# simply bind iperf3 to the interface addresses:
iperf3 -s -B 10.0.0.2 &
iperf3 -c 10.0.0.2 -B 10.0.0.1
```

Expected throughput at 1200 baud AFSK is approximately 100–150 bytes/sec effective payload.

---

## Port and Address Reference

| Component         | Parameter     | Value            |
|-------------------|---------------|------------------|
| Direwolf A        | AGWPORT       | 8000             |
| Direwolf A        | KISSPORT      | 8001             |
| Direwolf B        | AGWPORT       | 8010             |
| Direwolf B        | KISSPORT      | 8002             |
| tncattach A       | Interface     | tnc0             |
| tncattach A       | IPv4          | 10.0.0.1/30      |
| tncattach A       | Peer          | 10.0.0.2         |
| tncattach B       | Interface     | tnc1             |
| tncattach B       | IPv4          | 10.0.0.2/30      |
| tncattach B       | Peer          | 10.0.0.1         |
| PulseAudio sink   | A→B           | dw_a_to_b        |
| PulseAudio source | B reads A     | dw_a_to_b.monitor|
| PulseAudio sink   | B→A           | dw_b_to_a        |
| PulseAudio source | A reads B     | dw_b_to_a.monitor|

---

## Teardown

```bash
# Kill tncattach and direwolf
sudo pkill tncattach
pkill direwolf

# Remove virtual audio devices (replace module IDs with actual values from pactl list)
pactl unload-module module-null-sink
```

---

## Tuning Notes

- **PACLEN vs MTU**: `PACLEN` should equal `MTU + 4` to account for AX.25 framing. With `--mtu 236`, set `PACLEN 240`.
- **TXDELAY/TXTAIL**: In loopback testing with no real radio hardware, 30–50 ms (values 3–5) is sufficient. Real radio use typically requires 300 ms+ depending on the radio.
- **`--noipv6`**: Strongly recommended with tncattach to prevent IPv6 neighbor discovery traffic from consuming bandwidth on a 1200-baud link.
- **Audio underruns**: If packet loss occurs due to audio buffer issues, tune PulseAudio in `/etc/pulse/daemon.conf`:
  ```
  default-fragment-size-msec = 5
  default-fragments = 4
  ```
- **Modem speed**: `MODEM 1200` (Bell 202 AFSK) is the baseline. Both direwolf instances must use the same modem type and speed.
- **dhcpcd conflict** (Raspberry Pi / Debian): Prevent dhcpcd from managing the TNC interfaces:
  ```
  # /etc/dhcpcd.conf
  denyinterfaces tnc0 tnc1
  ```

---

## References

- [Direwolf](https://github.com/wb2osz/direwolf) — WB2OSZ
- [tncattach](https://github.com/markqvist/tncattach) — Mark Qvist
- [PulseAudio Modules](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/User/Modules/)
- [Direwolf User Guide](https://github.com/wb2osz/direwolf/tree/master/doc)
