#!/usr/bin/env bash
# docker/setup.sh — prepare the host and build the Docker image
#
# Run once before "docker compose up":
#   sudo docker/setup.sh
#
# What this does:
#   1. Installs docker.io if not present
#   2. Checks that the radio USB devices are present
#   3. Generates a test SSH key pair in docker/keys/ (gitignored)
#   4. Builds the Docker image — this also builds and installs the dw-iface
#      .deb inside the image, proving the packaging end-to-end

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "$(date '+%H:%M:%S') [setup] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"

# ── 1. Docker ─────────────────────────────────────────────────────────────────
command -v docker &>/dev/null || die "docker not found — install docker.io first"
docker info &>/dev/null || die "docker daemon not running (try: systemctl start docker)"

# ── 2. Radio hardware check ───────────────────────────────────────────────────
log "checking radio devices..."
missing=0
for dev in /dev/ic_705_b /dev/ic_7300; do
    if [[ -e "$dev" ]]; then
        log "  $dev OK (→ $(readlink -f "$dev"))"
    else
        log "  WARNING: $dev not found — is the radio plugged in?"
        (( missing++ )) || true
    fi
done
if ! aplay -l 2>/dev/null | grep -q CODEC_705; then
    log "  WARNING: IC-705 audio (CODEC_705) not found in aplay -l"
    (( missing++ )) || true
fi
if ! aplay -l 2>/dev/null | grep -q CODEC_7300; then
    log "  WARNING: IC-7300 audio (CODEC_7300) not found in aplay -l"
    (( missing++ )) || true
fi
(( missing == 0 )) && log "all radio devices present" \
    || log "WARNING: $missing device(s) missing — check USB connections before starting containers"

# ── 3. Resolve PTT device symlinks ───────────────────────────────────────────
# Docker's devices: section does not follow symlinks on the host — it needs a
# real device node. Resolve udev symlinks to their underlying tty* paths and
# write docker/.env so compose picks them up automatically.
log "resolving PTT device symlinks..."
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -e /dev/ic_705_b ]]; then
    IC705_RESOLVED=$(readlink -f /dev/ic_705_b)
    log "  IC705_PTT=$IC705_RESOLVED"
else
    IC705_RESOLVED=/dev/ic_705_b
    log "  WARNING: /dev/ic_705_b not found, using as-is"
fi
if [[ -e /dev/ic_7300 ]]; then
    IC7300_RESOLVED=$(readlink -f /dev/ic_7300)
    log "  IC7300_PTT=$IC7300_RESOLVED"
else
    IC7300_RESOLVED=/dev/ic_7300
    log "  WARNING: /dev/ic_7300 not found, using as-is"
fi
printf 'IC705_PTT=%s\nIC7300_PTT=%s\n' "$IC705_RESOLVED" "$IC7300_RESOLVED" > "$ENV_FILE"

# ── 4. SSH test keys ─────────────────────────────────────────────────────────
# These keys are used for container-to-container SSH authentication only.
# They are gitignored and have no access to real systems.
KEY_DIR="$SCRIPT_DIR/keys"
mkdir -p "$KEY_DIR"
if [[ ! -f "$KEY_DIR/id_ed25519" ]]; then
    log "generating test SSH key pair in docker/keys/"
    ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" \
        -C "dw-iface-test-only-$(date +%Y%m%d)" -q
    chmod 600 "$KEY_DIR/id_ed25519"
    chmod 644 "$KEY_DIR/id_ed25519.pub"
fi
log "SSH keys ready"

# ── 5. Build image ────────────────────────────────────────────────────────────
# The Dockerfile builds tncattach from source, builds the dw-iface .deb from
# package/, then installs both into the runtime image. A successful image build
# means 'dpkg -i dw-iface.deb' completed cleanly — the package is proven.
log "building Docker image..."
log "(stage 2 builds dw-iface.deb from package/ and installs it — watch for errors)"
cd "$SCRIPT_DIR"
docker compose build

log ""
log "Setup complete."
log "Start the link:  sudo docker compose -f docker/compose.yml up -d"
log "Run tests:       sudo docker/test.sh"
log "Stop:            sudo docker/teardown.sh"
