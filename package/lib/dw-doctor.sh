#!/usr/bin/env bash
# dw-iface doctor — check prerequisites
set -uo pipefail

ok()   { printf "  \e[32m✓\e[0m  %s\n" "$*"; }
bad()  { printf "  \e[31m✗\e[0m  %s\n" "$*"; ISSUES=$((ISSUES+1)); }
warn() { printf "  \e[33m!\e[0m  %s\n" "$*"; }

ISSUES=0
echo "=== dw-iface doctor ==="

# Required binaries
for bin in direwolf ip nc; do
    command -v "$bin" &>/dev/null \
        && ok "$bin found: $(command -v "$bin")" \
        || bad "$bin not found — install: apt install $bin"
done
if command -v tncattach &>/dev/null; then
    ok "tncattach found: $(command -v tncattach)"
else
    bad "tncattach not found — build from source: https://github.com/markqvist/tncattach"
fi

# direwolf version
if command -v direwolf &>/dev/null; then
    ver=$(direwolf -v 2>&1 | head -1 | grep -oP 'version \K\S+' || echo "?")
    ok "direwolf version $ver"
fi

# Config
CONFIG="${DW_IFACE_CONFIG:-/etc/dw-iface/dw-iface.conf}"
if [[ -f "$CONFIG" ]]; then
    ok "config: $CONFIG"
    # shellcheck source=/dev/null
    source "$CONFIG"
    [[ "${MYCALL:-NOCALL}" != "NOCALL" ]] && ok "MYCALL: $MYCALL" \
        || bad "MYCALL not set — edit $CONFIG"
    if [[ -n "${AUDIO_DEVICE:-}" ]]; then
        ok "AUDIO_DEVICE: $AUDIO_DEVICE"
        if aplay -l 2>/dev/null | grep -q "${AUDIO_DEVICE#plughw:CARD=}"; then
            ok "audio device present"
        else
            warn "audio device may not be present (run: aplay -l)"
        fi
    else
        bad "AUDIO_DEVICE not set"
    fi
else
    bad "config not found: $CONFIG"
    warn "copy example: cp /etc/dw-iface/dw-iface.conf.example $CONFIG"
fi

# CAP_NET_ADMIN (needed for tncattach TAP creation)
if [[ $EUID -eq 0 ]]; then
    ok "running as root"
else
    warn "not root — 'dw-iface up' requires sudo"
fi

echo ""
if (( ISSUES == 0 )); then
    echo "All checks passed."
else
    echo "$ISSUES issue(s) found."
    exit 1
fi
