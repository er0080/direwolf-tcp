# Patches against upstream `src/ardopc/` submodule

The ardop-ip build depends on local modifications to the upstream
`DigitalHERMES/ardopc` submodule. These are captured here as patch files so
the changes are tracked in this repo even though the submodule tree is dirty
locally.

## Applying

```bash
git submodule update --init
cd src/ardopc
git apply ../../patches/ardopc-tcpip.patch
cd ../..
make ardop-ip
```

## `ardopc-tcpip.patch`

Four files modified:

- `ardop2ofdm/ALSASound.c` — guard `main()` with `#ifndef ARDOP_IP` so our
  own entry point in `src/main.c` is used instead.
- `ardop2ofdm/ARDOPC.c` — declare `TUNHostPoll()` and call it at the top of
  the event loop (`#ifdef ARDOP_IP`) so `bytDataToSendLength` is up to date
  before any received frame is processed.
- `ardop2ofdm/ARQ.c` — refresh TUN state via `TUNHostPoll()` at the entry
  of the IDLE-received handler, immediately before the BREAK-vs-ACK check.
  Without this, an IRS with a kernel-queued reply (SYN-ACK, ICMP echo
  reply) ACKs instead of breaking, and the reply stalls indefinitely.
- `ardop2ofdm/HostInterface.c` — hook `AddTagToDataAndSendToHost` to
  `TUNDeliverToHost` in ARDOP_IP builds.

## Regenerating after further edits

```bash
cd src/ardopc && git diff > ../../patches/ardopc-tcpip.patch
```
