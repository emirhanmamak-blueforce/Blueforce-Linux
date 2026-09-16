#!/usr/bin/env bash
# journald caps + app logrotate policy.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="15-logrotate"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
DEALER_ID="${DEALER_ID:-}"
BF_HOSTNAME="${BF_HOSTNAME:-}"
BF_DEVICE="${BF_DEVICE:-}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"

log() {
    local msg="$1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [15-logrotate] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
JOURNAL_DROPIN="/etc/systemd/journald.conf.d/99-blueforce.conf"
APP_ROTATE="/etc/logrotate.d/blueforce"

if [[ "$CHECK_MODE" -eq 1 ]]; then
    [[ -f "$JOURNAL_DROPIN" && -f "$APP_ROTATE" ]] || { log "FAIL(check): logrotate configs missing"; exit 1; }
    log "OK(check): journald caps + app logrotate present"
    exit 0
fi

mkdir -p /etc/systemd/journald.conf.d
cat > /tmp/journald.bf <<'EOF'
# Managed by blueforce-installer (15-logrotate).
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
MaxRetentionSec=30day
ForwardToSyslog=no
EOF
mv /tmp/journald.bf "$JOURNAL_DROPIN"
systemctl restart systemd-journald 2>/dev/null || true

cat > /tmp/blueforce-rotate.bf <<'EOF'
# Managed by blueforce-installer (15-logrotate).
/var/log/blueforce*.log /var/log/bf-*.log {
    size 10M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
mv /tmp/blueforce-rotate.bf "$APP_ROTATE"
chmod 644 "$APP_ROTATE"
logrotate --debug "$APP_ROTATE" 2>&1 | head -3 || true
log "OK: journald capped (500M/30d), app logs rotate at 10M x5"
