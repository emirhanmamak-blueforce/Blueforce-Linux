#!/usr/bin/env bash
# Node exporter + textfile collector directory.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="12-monitoring"
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
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [12-monitoring] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
TEXTFILE_DIR="/var/lib/node_exporter/textfile"

if [[ "$CHECK_MODE" -eq 1 ]]; then
    systemctl is-enabled --quiet prometheus-node-exporter 2>/dev/null || systemctl is-enabled --quiet node_exporter 2>/dev/null         || { log "FAIL(check): node exporter not enabled"; exit 1; }
    [[ -d "$TEXTFILE_DIR" ]] || { log "FAIL(check): textfile dir missing"; exit 1; }
    log "OK(check): node exporter enabled, textfile dir present"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
dpkg -s prometheus-node-exporter >/dev/null 2>&1 || bf_apt_install prometheus-node-exporter

install -d -m 755 "$TEXTFILE_DIR"
# Ensure the textfile collector flag is set (package default may omit it).
OVERRIDE="/etc/systemd/system/prometheus-node-exporter.service.d/blueforce.conf"
mkdir -p "$(dirname "$OVERRIDE")"
printf '[Service]\nExecStart=\nExecStart=/usr/bin/prometheus-node-exporter --collector.textfile.directory=%s\n' "$TEXTFILE_DIR" > /tmp/override.bf
mv /tmp/override.bf "$OVERRIDE"
systemctl daemon-reload
systemctl enable --now prometheus-node-exporter 2>/dev/null || systemctl enable --now node_exporter
log "OK: node exporter enabled with textfile dir $TEXTFILE_DIR"
