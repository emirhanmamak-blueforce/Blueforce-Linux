#!/usr/bin/env bash
# Base APT sources, disable unattended-upgrades, set timezone.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="02-system"
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
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [02-system] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
TIMEZONE="${TIMEZONE:-Europe/Istanbul}"
BASE_PKGS="curl wget ca-certificates gnupg lsb-release"

check_state() {
    local ok=1
    for p in $BASE_PKGS; do dpkg -s "$p" >/dev/null 2>&1 || { echo "missing package: $p"; ok=0; }; done
    grep -q '^APT::Periodic::Update-Package-Lists "0"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || { echo "20auto-upgrades not locked"; ok=0; }
    for t in apt-daily.service apt-daily.timer apt-daily-upgrade.timer; do
        systemctl is-enabled "$t" 2>/dev/null | grep -q "masked" || { echo "timer not masked: $t"; ok=0; }
    done
    [[ "$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null)" == "$TIMEZONE" ]] || { echo "timezone not $TIMEZONE"; ok=0; }
    return $((1 - ok))
}

if [[ "$CHECK_MODE" -eq 1 ]]; then
    if check_state; then log "OK(check): system baseline matches"; else log "FAIL(check): system baseline drift"; exit 1; fi
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
bf_apt update
# shellcheck disable=SC2086
bf_apt_install $BASE_PKGS

# Lock automatic updates OFF (fleet policy: no unapproved updates).
printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /tmp/20auto-upgrades.bf
mv /tmp/20auto-upgrades.bf /etc/apt/apt.conf.d/20auto-upgrades
for t in apt-daily.service apt-daily.timer apt-daily-upgrade.timer apt-daily-upgrade.service; do
    systemctl mask "$t" >/dev/null 2>&1 || true
done

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$TIMEZONE" || echo "$TIMEZONE" > /etc/timezone
else
    echo "$TIMEZONE" > /etc/timezone
fi
log "OK: base packages installed, unattended-upgrades disabled, timezone $TIMEZONE"
