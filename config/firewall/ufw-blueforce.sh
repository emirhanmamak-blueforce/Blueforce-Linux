#!/usr/bin/env bash
# Apply field-device UFW baseline. SSH/RDP are accepted only on wg0.
set -euo pipefail
WG_IF="wg0"
WG_PORT="51820"
DOCKER_ALLOWLIST="/etc/blueforce/docker-published-port-allowlist.conf"
DOCKER_POLICY_BIN="/usr/local/sbin/blueforce-docker-firewall"
DOCKER_POLICY_UNIT="blueforce-docker-firewall.service"
rule_exists() { ufw status | grep -Fq "$1"; }
ensure_rule() { local match="$1"; shift; rule_exists "$match" && echo "keep: $match" || ufw "$@"; }

install_docker_policy() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  install -d -m 755 /etc/blueforce /etc/iptables
  if [[ ! -f "$DOCKER_ALLOWLIST" ]]; then
    printf '%s\n' '# Explicit reviewed Docker published-port exceptions: tcp PORT or udp PORT.' '# Default: deny every externally published Docker port.' > "$DOCKER_ALLOWLIST"
  fi
  chown root:root "$DOCKER_ALLOWLIST"
  chmod 640 "$DOCKER_ALLOWLIST"
  install -o root -g root -m 700 "$root/config/firewall/blueforce-docker-user-restore.sh" "$DOCKER_POLICY_BIN"
  install -o root -g root -m 644 "$root/config/systemd/blueforce-docker-firewall.service" "/etc/systemd/system/$DOCKER_POLICY_UNIT"
  systemctl daemon-reload
  systemctl enable "$DOCKER_POLICY_UNIT"
  systemctl start docker
  "$DOCKER_POLICY_BIN"
}
cmd_apply() {
  ufw default deny incoming
  ufw default allow outgoing
  ensure_rule "${WG_PORT}/udp" allow "${WG_PORT}/udp" comment 'WireGuard hub'
  ensure_rule "22/tcp on ${WG_IF}" allow in on "${WG_IF}" to any port 22 proto tcp comment 'SSH over WireGuard'
  ensure_rule "3389/tcp on ${WG_IF}" allow in on "${WG_IF}" to any port 3389 proto tcp comment 'RDP over WireGuard'
  install_docker_policy
  ufw --force enable
  ufw status verbose
}
cmd_reset() { ufw --force reset; ufw default deny incoming; ufw default allow outgoing; ufw --force enable; ufw status verbose; }
cmd_status() { ufw status verbose; "$DOCKER_POLICY_BIN" --check; iptables -S DOCKER-USER; }
case "${1:-apply}" in apply) cmd_apply ;; reset) cmd_reset ;; status) cmd_status ;; *) echo "Usage: $0 {apply|reset|status}" >&2; exit 1 ;; esac