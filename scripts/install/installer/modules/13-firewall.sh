#!/usr/bin/env bash
# Apply UFW deny-in baseline and persist Docker published-port policy.
set -euo pipefail
MODULE="13-firewall"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
CHECK_MODE=0
[[ "${1:-}" == "--check" ]] && CHECK_MODE=1
SSH_PORT="${SSH_PORT:-22}"
RDP_PORT="${RDP_PORT:-3389}"
DOCKER_ALLOWLIST="/etc/blueforce/docker-published-port-allowlist.conf"
DOCKER_POLICY_BIN="/usr/local/sbin/blueforce-docker-firewall"
DOCKER_POLICY_UNIT="blueforce-docker-firewall.service"
DOCKER_POLICY_DROPIN="/etc/systemd/system/docker.service.d/blueforce-docker-firewall.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../offline-apt.sh
source "$SCRIPT_DIR/../offline-apt.sh"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [13-firewall] $1" | tee -a "$LOG_FILE"; }

if [[ "$CHECK_MODE" -eq 1 ]]; then
    ufw status 2>/dev/null | grep -q 'Status: active' || { log "FAIL(check): ufw not active"; exit 1; }
    ufw status 2>/dev/null | grep -Eq "${SSH_PORT}/tcp.*on wg0|${SSH_PORT}/tcp.*wg0" || { log "FAIL(check): SSH is not restricted to wg0"; exit 1; }
    ufw status 2>/dev/null | grep -Eq "${RDP_PORT}/tcp.*on wg0|${RDP_PORT}/tcp.*wg0" || { log "FAIL(check): RDP is not restricted to wg0"; exit 1; }
    [[ -f "$DOCKER_ALLOWLIST" && -x "$DOCKER_POLICY_BIN" && -f "$DOCKER_POLICY_DROPIN" ]] || { log "FAIL(check): persistent Docker firewall assets missing"; exit 1; }
    systemctl is-enabled --quiet "$DOCKER_POLICY_UNIT" || { log "FAIL(check): persistent Docker firewall unit is not enabled"; exit 1; }
    "$DOCKER_POLICY_BIN" --check || { log "FAIL(check): Docker published-port policy is not enforced"; exit 1; }
    log "OK(check): SSH/RDP restricted to wg0 and Docker policy persists through systemd"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
command -v ufw >/dev/null 2>&1 || bf_apt_install ufw
command -v iptables >/dev/null 2>&1 || bf_apt_install iptables
ufw default deny incoming
ufw default allow outgoing
ufw delete allow "$SSH_PORT/tcp" 2>/dev/null || true
ufw delete allow "$RDP_PORT/tcp" 2>/dev/null || true
ufw allow in on wg0 to any port "$SSH_PORT" proto tcp comment 'SSH over WireGuard only'
ufw allow in on wg0 to any port "$RDP_PORT" proto tcp comment 'RDP over WireGuard only'
install -d -m 755 /etc/blueforce /etc/iptables
if [[ ! -f "$DOCKER_ALLOWLIST" ]]; then
    cat > "$DOCKER_ALLOWLIST" <<'EOF'
# Explicit Docker published-port exceptions. One reviewed entry per line:
# tcp 8443
# udp 51820
# This allowlist intentionally permits no externally published Docker ports by default.
EOF
fi
chown root:root "$DOCKER_ALLOWLIST"
chmod 640 "$DOCKER_ALLOWLIST"
install -o root -g root -m 700 "$REPO_ROOT/config/firewall/blueforce-docker-user-restore.sh" "$DOCKER_POLICY_BIN"
install -o root -g root -m 644 "$REPO_ROOT/config/systemd/blueforce-docker-firewall.service" "/etc/systemd/system/$DOCKER_POLICY_UNIT"
install -d -m 755 "$(dirname "$DOCKER_POLICY_DROPIN")"
install -o root -g root -m 644 "$REPO_ROOT/config/systemd/docker.service.d/blueforce-docker-firewall.conf" "$DOCKER_POLICY_DROPIN"
systemctl daemon-reload
systemctl enable "$DOCKER_POLICY_UNIT"
# Docker creates DOCKER-USER during startup; applying now proves the parsed policy.
systemctl start docker
"$DOCKER_POLICY_BIN"
ufw --force enable
# xRDP remains stopped until the deny-in/WireGuard-only rules are active.
systemctl enable xrdp xrdp-sesman >/dev/null 2>&1 || systemctl enable xrdp
systemctl start xrdp xrdp-sesman >/dev/null 2>&1 || systemctl start xrdp
systemctl is-enabled --quiet xrdp && systemctl is-active --quiet xrdp || { log 'FAIL: xrdp did not start after firewall baseline'; exit 1; }
log "OK: UFW allows SSH/RDP only on wg0; xrdp started only after firewall baseline; persisted Docker policy denies all unapproved published ports"