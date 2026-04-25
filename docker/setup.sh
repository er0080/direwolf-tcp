#!/usr/bin/env bash
# docker/setup.sh — prepare the host and build the Docker image
#
# Run once before "docker compose up":
#   sudo docker/setup.sh
#
# What this does:
#   1. Installs docker.io if not present
#   2. Loads the snd_aloop kernel module (ALSA loopback for audio cross-wiring)
#   3. Generates a test SSH key pair in docker/keys/ (gitignored)
#   4. Builds the Docker image

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "$(date '+%H:%M:%S') [setup] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"

# ── 1. Docker ─────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "installing docker.io..."
    apt-get update -q && apt-get install -y docker.io
    systemctl enable --now docker
    log "docker installed"
fi

# ── 2. ALSA loopback ─────────────────────────────────────────────────────────
# snd_aloop creates two virtual ALSA cards:
#   plughw:Loopback,0 TX → plughw:Loopback,1 RX  (node-a → node-b)
#   plughw:Loopback,1 TX → plughw:Loopback,0 RX  (node-b → node-a)
if ! aplay -l 2>/dev/null | grep -q Loopback; then
    log "loading snd_aloop..."
    modprobe snd_aloop
    # persist across reboots
    echo "snd_aloop" >> /etc/modules-load.d/dw-iface.conf 2>/dev/null || true
fi
aplay -l 2>/dev/null | grep -q Loopback || die "snd_aloop did not create Loopback devices"
log "ALSA loopback ready"

# ── 3. SSH test keys ─────────────────────────────────────────────────────────
# These keys are for container-to-container authentication only.
# They are gitignored and have no access to real systems.
KEY_DIR="$SCRIPT_DIR/keys"
mkdir -p "$KEY_DIR"
if [[ ! -f "$KEY_DIR/id_ed25519" ]]; then
    log "generating test SSH key pair in docker/keys/"
    ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "dw-iface-test-$(date +%Y%m%d)" -q
    chmod 600 "$KEY_DIR/id_ed25519"
    chmod 644 "$KEY_DIR/id_ed25519.pub"
fi
log "SSH keys ready"

# ── 4. Build image ────────────────────────────────────────────────────────────
log "building Docker image (this takes a few minutes the first time)..."
cd "$SCRIPT_DIR"
docker compose build

log ""
log "Setup complete. Start the link with:"
log "  sudo docker compose -f docker/compose.yml up -d"
log "Run tests with:"
log "  sudo docker/test.sh"
