# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Test framework for a simulated point-to-point TCP/IP link using two Direwolf TNC instances connected by a PulseAudio virtual audio cable, with `tncattach` creating `/30` network interfaces over KISS-over-TCP. No real radio hardware is required.

See `README.md` for full architecture, setup steps, and tuning notes.

## Key Components and Their Roles

| Component | Role |
|-----------|------|
| Direwolf A (`config/dw-a.conf`) | Modem instance A — KISS TCP port 8001, AGWPORT 8000, audio devices `dw_a_rx`/`dw_a_tx` |
| Direwolf B (`config/dw-b.conf`) | Modem instance B — KISS TCP port 8002, AGWPORT 8010, audio devices `dw_b_rx`/`dw_b_tx` |
| PulseAudio null sinks | `dw_a_to_b` and `dw_b_to_a` — virtual full-duplex audio cable between the two Direwolf instances |
| ALSA shims (`~/.asoundrc`) | Maps `dw_a_rx/tx` and `dw_b_rx/tx` ALSA device names to the PulseAudio sinks/monitors |
| tncattach | Bridges KISS/TCP → Linux network interfaces (`tnc0` = 10.0.0.1, `tnc1` = 10.0.0.2) |

## Audio Wiring

```
Direwolf A TX → dw_a_to_b (sink) → dw_a_to_b.monitor → Direwolf B RX
Direwolf B TX → dw_b_to_a (sink) → dw_b_to_a.monitor → Direwolf A RX
```

## Common Commands

### Start virtual audio cables
```bash
pactl load-module module-null-sink sink_name=dw_a_to_b rate=44100 sink_properties=device.description="DW_A_to_B"
pactl load-module module-null-sink sink_name=dw_b_to_a rate=44100 sink_properties=device.description="DW_B_to_A"
```

### Start Direwolf instances
```bash
direwolf -c config/dw-a.conf &
direwolf -c config/dw-b.conf &
```

### Attach network interfaces
```bash
sudo tncattach -T -H localhost -P 8001 --mtu 236 --noipv6 --noup
sudo ifconfig tnc0 10.0.0.1 pointopoint 10.0.0.2 netmask 255.255.255.252 up

sudo tncattach -T -H localhost -P 8002 --mtu 236 --noipv6 --noup
sudo ifconfig tnc1 10.0.0.2 pointopoint 10.0.0.1 netmask 255.255.255.252 up
```

### Verify and test
```bash
ss -tlnp | grep -E '800[12]'          # confirm KISS TCP ports are listening
pactl list short sinks | grep dw_      # confirm virtual audio sinks exist
ping -c 4 -I tnc0 10.0.0.2            # test A→B path
ping -c 4 -I tnc1 10.0.0.1            # test B→A path
```

### Teardown
```bash
sudo pkill tncattach
pkill direwolf
pactl unload-module module-null-sink
```

## Critical Configuration Constraints

- **PACLEN and MTU must match**: `PACLEN` in direwolf.conf must equal `tncattach --mtu` + 4. Current values: `PACLEN 240`, `--mtu 236`.
- **No PTT line**: Omit `PTT` from direwolf configs — there is no radio hardware to key.
- **`--noipv6` on tncattach**: Required to prevent IPv6 neighbor discovery from flooding the 1200-baud link.
- **AGWPORT must differ** between the two instances (8000 vs 8010) to avoid port conflicts on the same host.
