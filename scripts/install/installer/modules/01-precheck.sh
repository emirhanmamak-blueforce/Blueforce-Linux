#!/usr/bin/env bash
# Pre-flight checks: root, Ubuntu 26.04, RAM/disk, internet.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="01-precheck"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
DEALER_ID="${DEALER_ID:-}"
BF_HOSTNAME="${BF_HOSTNAME:-}"
BF_DEVICE="${BF_DEVICE:-}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"

log() {
    local msg="$1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [01-precheck] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
MIN_RAM_MB=2048
MIN_DISK_MB=20480

fail() { log "FAIL: $1"; echo "FAIL: $1" >&2; exit 1; }

run_checks() {
    [[ "$(id -u)" -eq 0 ]] || fail "must run as root"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        [[ "${VERSION_ID:-}" == 26.04* ]] || fail "unsupported OS: ${NAME:-unknown} ${VERSION_ID:-unknown} (need Ubuntu 26.04)"
    else
        fail "/etc/os-release not found"
    fi
    local ram_mb disk_mb
    ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    [[ "$ram_mb" -ge "$MIN_RAM_MB" ]] || fail "RAM too low: ${ram_mb}MB (need >= ${MIN_RAM_MB}MB)"
    disk_mb=$(df -m / --output=avail | tail -1 | tr -d ' ')
    [[ "$disk_mb" -ge "$MIN_DISK_MB" ]] || fail "disk too low: ${disk_mb}MB free on / (need >= ${MIN_DISK_MB}MB)"
    if [[ "${BF_OFFLINE:-0}" != 1 ]] && ! getent hosts archive.ubuntu.com >/dev/null 2>&1 && ! ping -c1 -W5 1.1.1.1 >/dev/null 2>&1; then
        fail "no internet connectivity (DNS and ping both failed)"
    fi
    log "OK: precheck passed (Ubuntu ${VERSION_ID}, RAM ${ram_mb}MB, disk ${disk_mb}MB free; offline=${BF_OFFLINE:-0})"
}

run_checks
