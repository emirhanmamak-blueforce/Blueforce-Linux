#!/usr/bin/env bash
# xRDP + GNOME session, terminal boot default, multi-user.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="08-rdp"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
DEALER_ID="${DEALER_ID:-}"
BF_HOSTNAME="${BF_HOSTNAME:-}"
BF_DEVICE="${BF_DEVICE:-}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"
# shellcheck source=../offline-apt.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/offline-apt.sh"

log() {
    local msg="$1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [08-rdp] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
if [[ "$CHECK_MODE" -eq 1 ]]; then
    dpkg -s xrdp >/dev/null 2>&1 || { log "FAIL(check): xrdp not installed"; exit 1; }
    systemctl is-enabled --quiet xrdp 2>/dev/null || { log "FAIL(check): xrdp not enabled"; exit 1; }
    systemctl is-active --quiet xrdp 2>/dev/null || { log "FAIL(check): xrdp not active"; exit 1; }
    systemctl is-enabled --quiet xrdp-sesman 2>/dev/null || { log "FAIL(check): xrdp-sesman not enabled"; exit 1; }
    systemctl is-active --quiet xrdp-sesman 2>/dev/null || { log "FAIL(check): xrdp-sesman not active"; exit 1; }
    [[ "$(systemctl get-default)" == "multi-user.target" ]] || { log "FAIL(check): default target is not multi-user"; exit 1; }
    log "OK(check): xrdp installed+enabled, terminal boot default"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
dpkg -s xrdp >/dev/null 2>&1 || bf_apt_install xrdp
dpkg -s gnome-session >/dev/null 2>&1 || bf_apt_install gnome-session

# Default GNOME session for RDP logins (per-user override still wins).
if [[ ! -f /etc/skel/.xsession ]]; then
    echo "gnome-session" > /etc/skel/.xsession
fi
if id blueforce >/dev/null 2>&1 && [[ ! -f /home/blueforce/.xsession ]]; then
    echo "gnome-session" > /home/blueforce/.xsession
    chown blueforce:blueforce /home/blueforce/.xsession
fi

# Module 13 starts xRDP only after the UFW WireGuard-only baseline succeeds.
systemctl set-default multi-user.target
log "OK: xrdp installed and configured; module 13 will enable it after firewall baseline"
