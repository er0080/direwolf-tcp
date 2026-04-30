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
| `scripts/rf-burnin.sh` | Mixed-workload burn-in: ping, HTTP, interactive echo, bulk TCP transfer; runs for a configurable duration; logs to `logs/burnin/` |
| `scripts/dw-tune-sweep.sh` | OFAT CSMA parameter sweep — iterates DWAIT/PERSIST/SLOTTIME combinations, calls `dw-tune-run.sh` per point, appends to `logs/tune/sweep.csv` |
| `scripts/dw-tune-run.sh` | Single measurement run for the sweep: launches a Direwolf pair with a given config, runs mixed workload, emits JSON result |
| `scripts/dw-tune-analyze.py` | Reads `sweep.csv`, scores each config by composite metric, prints sorted table and per-factor OFAT effects |
| tncattach (`tncattach/tncattach`) | Bridges KISS/TCP → TAP interfaces; built from git submodule (host scripts only — the dw-iface package bundles its own copy) |
| Network namespaces | `ns_a` holds `tnc0` (10.0.0.1), `ns_b` holds `tnc1` (10.0.0.2) |

## dw-iface Package (`package/`)

The `dw-iface` branch adds a Debian package that wraps the RF link into a single `apt install`.

| Component | Role |
|-----------|------|
| `package/bin/dw-iface` | CLI dispatcher — `up`, `down`, `status`, `doctor` |
| `package/lib/dw-up.sh` | Starts Direwolf + tncattach, assigns IP; reads `/etc/dw-iface/dw-iface.conf` |
| `package/lib/dw-down.sh` | Graceful teardown |
| `package/lib/dw-status.sh` / `dw-doctor.sh` | Status display and pre-flight checks |
| `package/vendor/tncattach/` | Vendored tncattach source (MIT); compiled during `dpkg-buildpackage` |
| `package/systemd/dw-iface.service` | Systemd unit — installed but NOT enabled at package install time |
| `package/debian/` | Standard Debian packaging (debhelper 13, compat 13) |
| `.github/workflows/publish-deb.yml` | CI: builds `.deb` on every `v*` tag, publishes to GitHub Pages apt repo |

Key packaging constraints:
- **tncattach is vendored** in `package/vendor/tncattach/` and compiled via `override_dh_auto_build`. The package is self-contained — no external tncattach install needed.
- **Service is not enabled at install**: `dh_installsystemd --no-enable --no-start`. Treat dw-iface like a VPN — bring it up manually with `dw-iface up` or `systemctl enable --now dw-iface`.
- **`dpkg-buildpackage -d`** in CI skips the `build-essential:native` dep check since gcc/make are installed explicitly on the runner.
- **ALSA card resolution**: `dw-up.sh` checks `/proc/asound/cards` first, falls back to `/sys/class/sound/cardN/id` sysfs for Docker/restricted environments.

## Docker RF Test Harness (`docker/`)

Two containers with `network_mode: none` — the only path between them is the real IC-705 ↔ IC-7300 RF link.

| Component | Role |
|-----------|------|
| `docker/compose.yml` | Defines `dwiface-node-a` (IC-705) and `dwiface-node-b` (IC-7300); both `privileged: true` |
| `docker/Dockerfile` | Two-stage: builds `dw-iface` `.deb` from `package/`, installs it in the runtime image |
| `docker/entrypoint.sh` | Calls `dw-iface up`, waits for `tnc0`, starts sshd (and nginx on node-b) |
| `docker/setup.sh` | Resolves udev symlinks → `docker/.env`; generates SSH keys; builds image |
| `docker/teardown.sh` | Stops containers |
| `docker/test.sh` | Quick connectivity check: ping, SSH, SCP, HTTP |
| `docker/burnin.sh` | Sustained 30-min burn-in via `docker exec`; logs to `logs/burnin/`; exit 0 = pass |
| `docker/config/node-a.conf` | dw-iface config for IC-705 (10.0.0.1, DWAIT 25) |
| `docker/config/node-b.conf` | dw-iface config for IC-7300 (10.0.0.2, DWAIT 5) |

Key Docker constraints:
- **`docker/setup.sh` must run before `docker compose up`**: it resolves `/dev/ic_705_b` → `/dev/ttyACMx` and writes `docker/.env`. Docker `devices:` does not follow udev symlinks.
- **Stale RF direwolf instances block ALSA**: if `scripts/rf-setup.sh` was run earlier, its direwolf processes hold the audio cards. Run `sudo scripts/rf-teardown.sh` before starting containers.
- **`burnin.sh` uses `docker exec NODE CMD` directly for timeout-wrapped calls** — bash functions cannot be passed as the command to `timeout` (timeout exec()s its argument as a binary).
- **`docker/.env` is gitignored** — it contains machine-specific resolved device paths.

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
- **Asymmetric DWAIT on RF**: `config/dw-705.conf` uses `DWAIT 25` (250 ms post-DCD delay); `config/dw-7300.conf` uses `DWAIT 5` (50 ms). IC-7300 still gets channel priority over IC-705, but the 50 ms dead time prevents IC-7300 from keying during IC-705's TXDELAY silence window (200 ms during which IC-705 has raised PTT but not yet started audio, making the channel appear clear to IC-7300). Do not set both to the same DWAIT value or collisions will recur.
- **PERSIST and SLOTTIME on RF**: Both configs use `PERSIST 127` (≈50% TX probability per slot) and `SLOTTIME 5` (50 ms slots). This was determined by an OFAT sweep (`scripts/dw-tune-sweep.sh`) and yielded 6% frame loss vs 81% at the PERSIST=255/SLOTTIME=1 default. `PERSIST 255` + `SLOTTIME 1` causes both radios to key simultaneously the instant the channel clears, producing systematic collisions.
- **RF ping interval must exceed RTT**: At 2400 baud QPSK with TXDELAY 20 + TXTAIL 10, frame air time is ~860 ms and RTT is ~1700 ms. Using `ping -i 1` (default) causes the transmit queue to grow and produces back-to-back collisions. Always use `ping -i 3` or longer when testing the RF link.
- **KISS has no flow control**: tncattach can feed frames faster than the radio can transmit. For sustained traffic, rate-limit with `tc tbf`. TCP self-limits via congestion control; ICMP does not.
- **tc tbf burst and latency must be sized correctly for bulk transfers**: `burst` must be at least one MTU (508 B); `latency` controls the queue limit (`queue = burst + rate×latency/8`). Use `burst 4096 latency 10s` — this gives a ~5.6 KB queue (≈11 MTUs), enough for TCP to build a usable initial window without drops. The old example value of `burst 512 latency 500ms` gives only ~1.2 KB (2.5 MTUs) and causes constant TCP drops and retransmits that waste half the link budget.
- **Rate-limiting is still needed for TCP bulk transfers**: TCP congestion control prevents KISS queue overflow, but it does not prevent TXDELAY-window collisions. During TCP bulk flow the sender transmits back-to-back frames; each 200 ms TXDELAY silence window looks like a clear channel to the receiving radio, which keys up into the upcoming burst. The `tc tbf` rate limit at 1200 bps creates ~3.4 s inter-frame gaps at MTU 508 B, giving the remote radio time to send its ACKs between sender frames.
- **nc -N is required for accurate bulk transfer timing**: `nc -N` sends a TCP FIN when stdin reaches EOF (half-close), so the receiver exits as soon as all bytes drain. Without `-N`, the sender's `nc` process stays open, the receiver never sees EOF, and the drain-wait loop times out prematurely — causing apparent short transfers.
- **Bulk transfer drain timeout must cover the full link budget**: At 1200 bps rate limit, 32 KB takes ~218 s to drain. Any drain-wait timeout shorter than this truncates the transfer. Compute dynamically: `bytes × 8 / effective_bps × 1.5 + 120` (1.5× headroom + 2 min safety margin).
- **2400 QPSK requires matched SSB filter bandwidth**: Both radios must have TX bandwidth wide enough (~2.4 kHz) and matched. A narrower filter on the transmitting radio will cause systematic FEC corrections on every received frame even at correct audio levels.
