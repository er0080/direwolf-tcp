#!/usr/bin/env bash
# docker/teardown.sh — stop containers and optionally unload ALSA loopback
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "$(date '+%H:%M:%S') [teardown] $*"; }

cd "$SCRIPT_DIR"
log "stopping containers..."
docker compose down 2>/dev/null || true

if [[ "${1:-}" == "--unload-audio" ]]; then
    log "unloading snd_aloop..."
    modprobe -r snd_aloop 2>/dev/null || true
fi

log "done"
