#!/usr/bin/env bash
# Set hostname bf-<dealer-id> from validated dealer number.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="04-hostname"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
DEALER_ID="${DEALER_ID:-}"
BF_HOSTNAME="${BF_HOSTNAME:-}"
BF_DEVICE="${BF_DEVICE:-}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"

log() {
    local msg="$1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [04-hostname] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
[[ -n "$DEALER_ID" ]] || { log "FAIL: DEALER_ID env is empty"; echo "FAIL: DEALER_ID env is empty" >&2; exit 1; }
[[ "$DEALER_ID" =~ ^[0-9]{8}$ ]] || { log "FAIL: bad DEALER_ID format: $DEALER_ID"; echo "FAIL: bad DEALER_ID" >&2; exit 1; }
TARGET="bf-${DEALER_ID}"

if [[ "$CHECK_MODE" -eq 1 ]]; then
    [[ "$(hostname)" == "$TARGET" ]] || { log "FAIL(check): hostname is $(hostname), want $TARGET"; exit 1; }
    log "OK(check): hostname is $TARGET"
    exit 0
fi

if [[ "$(hostname)" == "$TARGET" ]]; then
    log "hostname already $TARGET, keeping"
else
    hostnamectl set-hostname "$TARGET"
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1\t$TARGET/" /etc/hosts
    else
        echo -e "127.0.1.1\t$TARGET" >> /etc/hosts
    fi
    log "hostname set to $TARGET"
fi
mkdir -p "$STATE_DIR"
echo "$DEALER_ID" > "$STATE_DIR/dealer-id"
echo "bf-${DEALER_ID}" > "$STATE_DIR/hostname"
echo "BF-${DEALER_ID}" > "$STATE_DIR/device-id"
log "OK: identity files written (BF-${DEALER_ID} / bf-${DEALER_ID})"
