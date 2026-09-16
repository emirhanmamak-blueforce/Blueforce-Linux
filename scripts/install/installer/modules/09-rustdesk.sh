#!/usr/bin/env bash
# RustDesk is a required remote channel: only a pinned supplied package is accepted.
set -euo pipefail
MODULE="09-rustdesk"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"
# shellcheck source=../offline-apt.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/offline-apt.sh"
CHECK_MODE=0
[[ "${1:-}" == "--check" ]] && CHECK_MODE=1
RUSTDESK_SERVER="${RUSTDESK_SERVER:-}"
RUSTDESK_DEB="${RUSTDESK_DEB:-}"
SYSTEM_CONFIG="/etc/rustdesk/RustDesk2.toml"
USER_CONFIG="/home/blueforce/.config/RustDesk/RustDesk2.toml"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [09-rustdesk] $1" | tee -a "$LOG_FILE"; }
valid_server() {
    local endpoint="$1" host port
    [[ -n "$endpoint" ]] || return 1
    [[ "$endpoint" != *example* && "$endpoint" != *invalid* && "$endpoint" != *REPLACE* && "$endpoint" != *replace* && "$endpoint" != *'<'* && "$endpoint" != *'>'* && "$endpoint" != localhost* ]] || return 1
    [[ "$endpoint" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[1-9][0-9]{0,4})?$ ]] || return 1
    host="${endpoint%%:*}"
    [[ -n "$host" ]] || return 1
    if [[ "$endpoint" == *:* ]]; then
        port="${endpoint##*:}"
        ((10#$port <= 65535)) || return 1
    fi
}
config_endpoint() {
    sed -n "s/^rendezvous-server = '\([^']*\)'$/\1/p" "$SYSTEM_CONFIG" 2>/dev/null | head -n 1
}
configured() {
    local endpoint
    endpoint="$(config_endpoint)"
    valid_server "$endpoint" || return 1
    grep -Fqx "rendezvous-server = '${endpoint}'" "$SYSTEM_CONFIG" >/dev/null 2>&1 &&
    grep -Fqx "relay-server = '${endpoint}'" "$SYSTEM_CONFIG" >/dev/null 2>&1 &&
    grep -Fqx "rendezvous-server = '${endpoint}'" "$USER_CONFIG" >/dev/null 2>&1 &&
    grep -Fqx "relay-server = '${endpoint}'" "$USER_CONFIG" >/dev/null 2>&1
}
if [[ "$CHECK_MODE" -eq 1 ]]; then
    dpkg -s rustdesk >/dev/null 2>&1 || { log "FAIL(check): rustdesk remote channel is not installed"; exit 1; }
    configured || { log "FAIL(check): RustDesk client config is missing, inconsistent, or uses a placeholder/non-self-hosted endpoint"; exit 1; }
    rustdesk --get-id 2>/dev/null | grep -qE '^[0-9]+$' || { log "FAIL(check): RustDesk client cannot provide a device ID"; exit 1; }
    log "OK(check): RustDesk remote channel is installed with a self-hosted client configuration"
    exit 0
fi
valid_server "$RUSTDESK_SERVER" || { log "FAIL: RUSTDESK_SERVER must be a non-placeholder self-hosted host or host:port"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
if [[ "${BF_OFFLINE:-0}" == 1 ]]; then
    dpkg -s rustdesk >/dev/null 2>&1 || bf_apt_install rustdesk
else
    [[ -n "$RUSTDESK_DEB" && -f "$RUSTDESK_DEB" ]] || { log "FAIL: RUSTDESK_DEB must name a supplied pinned RustDesk .deb; apt sources are not used"; exit 1; }
    dpkg -s rustdesk >/dev/null 2>&1 || { dpkg -i "$RUSTDESK_DEB" || apt-get install -f -y; }
fi
for cfgdir in /etc/rustdesk /home/blueforce/.config/RustDesk; do
    install -d -m 700 "$cfgdir"
    cat > "$cfgdir/RustDesk2.toml" <<EOF
# Managed by blueforce-installer (09-rustdesk).
rendezvous-server = '${RUSTDESK_SERVER}'
relay-server = '${RUSTDESK_SERVER}'
nat-type = 1
EOF
done
chown -R blueforce:blueforce /home/blueforce/.config 2>/dev/null || true
configured || { log "FAIL: RustDesk client configuration did not persist"; exit 1; }
install -d -m 700 "$STATE_DIR"
rustdesk --get-id 2>/dev/null | head -1 > "$STATE_DIR/rustdesk-id" || true
[[ -s "$STATE_DIR/rustdesk-id" ]] || { log "FAIL: RustDesk client did not provide a device ID"; exit 1; }
log "OK: RustDesk pinned package installed and self-hosted channel configured"