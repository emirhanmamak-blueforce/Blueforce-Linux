#!/usr/bin/env bash
# Network gates distinguish local link, Internet, and central enrollment reachability.
set -euo pipefail
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"; CHECK_MODE=0
[[ "${1:-}" == --check ]] && CHECK_MODE=1
OFFLINE="${BF_OFFLINE:-0}"; ENDPOINT="${BF_ENROLLMENT_ENDPOINT:-}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [05-network] $1" | tee -a "$LOG_FILE"; }
local_link() { ip -o link show up 2>/dev/null | grep -qv ' lo:'; }
internet() { getent hosts archive.ubuntu.com >/dev/null 2>&1 && (ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || curl --connect-timeout 3 -fsSI https://archive.ubuntu.com >/dev/null 2>&1); }
central() { [[ "$ENDPOINT" =~ ^https://[^[:space:]/]+ ]] && curl --connect-timeout 3 -fsSI "$ENDPOINT" >/dev/null 2>&1; }
local_link || { log 'FAIL: no local network link'; exit 1; }
log 'OK: local link present'
if [[ "$OFFLINE" == 1 ]]; then log 'OK: offline mode defers Internet and central endpoint checks'; exit 0; fi
internet || { log 'FAIL: Internet reachability unavailable'; exit 1; }
log 'OK: Internet reachable'
if [[ -n "$ENDPOINT" ]]; then central && log 'OK: central enrollment endpoint reachable' || log 'WARN: central enrollment endpoint unavailable (enrollment remains pending)'; else log 'INFO: central enrollment endpoint not configured'; fi
