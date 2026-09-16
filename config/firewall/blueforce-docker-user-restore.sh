#!/usr/bin/env bash
# Apply Blueforce's reviewed Docker published-port policy to DOCKER-USER.
set -euo pipefail

ALLOWLIST="${DOCKER_ALLOWLIST:-/etc/blueforce/docker-published-port-allowlist.conf}"
CHECK_MODE=0
[[ "${1:-}" == "--check" ]] && CHECK_MODE=1

fail() { printf 'blueforce-docker-firewall: %s\n' "$*" >&2; exit 1; }
parse_allowlist() {
    local callback="$1" raw line protocol port extra
    [[ -r "$ALLOWLIST" ]] || fail "allowlist is missing or unreadable: $ALLOWLIST"
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line="${raw%%#*}"
        line="$(printf '%s' "$line" | xargs)"
        [[ -z "$line" ]] && continue
        read -r protocol port extra <<< "$line"
        [[ -z "${extra:-}" && "$protocol" =~ ^(tcp|udp)$ && "$port" =~ ^[0-9]{1,5}$ ]] || fail "invalid allowlist entry '$raw'; use 'tcp PORT' or 'udp PORT'"
        ((10#$port >= 1 && 10#$port <= 65535)) || fail "port out of range in '$raw'"
        "$callback" "$protocol" "$port"
    done < "$ALLOWLIST"
}

validate_allowlist() { parse_allowlist :; }
install_allow_rule() {
    local protocol="$1" port="$2"
    # Docker DNAT precedes DOCKER-USER; match the original reviewed published port.
    iptables -I DOCKER-USER -p "$protocol" -m conntrack --ctorigdstport "$port" -j ACCEPT
}
verify_allow_rule() {
    local protocol="$1" port="$2"
    iptables -C DOCKER-USER -p "$protocol" -m conntrack --ctorigdstport "$port" -j ACCEPT || fail "allowlist rule missing: $protocol $port"
}

validate_allowlist
command -v iptables >/dev/null 2>&1 || fail "iptables is required"
iptables -S DOCKER-USER >/dev/null 2>&1 || fail "DOCKER-USER chain is unavailable; start Docker first"

if [[ "$CHECK_MODE" -eq 1 ]]; then
    iptables -C DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || fail "established/related rule missing"
    iptables -C DOCKER-USER -i docker0 -j RETURN || fail "docker0 outbound return rule missing"
    iptables -C DOCKER-USER -i br+ -j RETURN || fail "user-defined bridge outbound return rule missing"
    parse_allowlist verify_allow_rule
    iptables -C DOCKER-USER -j DROP || fail "default published-port deny rule missing"
    exit 0
fi

# Blueforce owns DOCKER-USER so an old permissive rule cannot bypass the deny.
iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# Container-to-Internet packets enter FORWARD from Docker bridges; inbound published-port
# packets enter from an external interface, so these returns do not bypass the deny below.
iptables -A DOCKER-USER -i docker0 -j RETURN
iptables -A DOCKER-USER -i br+ -j RETURN
# Insert every parsed allowlist exception before the final default drop.
parse_allowlist install_allow_rule
iptables -A DOCKER-USER -j DROP
