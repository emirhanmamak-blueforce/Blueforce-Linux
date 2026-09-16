#!/usr/bin/env bash
# Docker CE + daemon.json with log rotation, service enabled.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="10-docker"
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
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [10-docker] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
DAEMON_JSON="/etc/docker/daemon.json"
WANT_JSON='{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "live-restore": true
}'

if [[ "$CHECK_MODE" -eq 1 ]]; then
    command -v docker >/dev/null 2>&1 || { log "FAIL(check): docker missing"; exit 1; }
    systemctl is-enabled --quiet docker 2>/dev/null || { log "FAIL(check): docker not enabled"; exit 1; }
    [[ -f "$DAEMON_JSON" ]] || { log "FAIL(check): daemon.json missing"; exit 1; }
    log "OK(check): docker installed, enabled, daemon.json present"
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    if [[ "${BF_OFFLINE:-0}" == 1 ]]; then
        bf_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        apt-get install -y ca-certificates curl gnupg
        if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
            install -d -m 0755 /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            . /etc/os-release
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
            apt-get update
        fi
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || apt-get install -y docker.io
    fi
fi

printf '%s\n' "$WANT_JSON" > /tmp/daemon.json.bf
mkdir -p /etc/docker
mv /tmp/daemon.json.bf "$DAEMON_JSON"
systemctl enable --now docker
systemctl is-active --quiet docker || { log "FAIL: docker installed but service not running"; exit 1; }
log "OK: docker ready with log rotation (10m x3) and live-restore"
