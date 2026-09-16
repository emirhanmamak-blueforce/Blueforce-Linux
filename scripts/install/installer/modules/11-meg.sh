#!/usr/bin/env bash
# MEG placeholder: install vendor .deb if present, else SKIP + acceptance checklist.
# Idempotent: safe to re-run. Supports --check for read-only verification.
# Exit codes: 0 = OK, 3 = SKIP (optional step, nothing to do).
set -euo pipefail

MODULE="11-meg"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
DEALER_ID="${DEALER_ID:-}"
BF_HOSTNAME="${BF_HOSTNAME:-}"
BF_DEVICE="${BF_DEVICE:-}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"

log() {
    local msg="$1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [11-meg] $msg" | tee -a "$LOG_FILE"
}

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then CHECK_MODE=1; fi
MEG_DEB="${MEG_DEB:-$(ls /opt/blueforce/debs/meg*.deb /opt/blueforce/meg*.deb 2>/dev/null | head -1)}"
MEG_CONTAINER="${MEG_CONTAINER:-meg}"

acceptance_checklist() {
    local fails=0
    # Gate 2: pinned version, never latest.
    local img
    img=$(docker inspect --format '{{.Config.Image}}' "$MEG_CONTAINER" 2>/dev/null || echo "")
    if [[ -z "$img" ]]; then echo "CHECK container-running: SKIP (no container $MEG_CONTAINER yet)"; else echo "CHECK container-running: PASS ($img)"; fi
    if [[ "$img" == *":latest" ]]; then echo "CHECK pinned-tag: FAIL (latest forbidden)"; fails=$((fails+1)); else echo "CHECK pinned-tag: PASS"; fi
    # Gate 4: restart policy unless-stopped.
    if [[ -n "$img" ]]; then
        local pol
        pol=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$MEG_CONTAINER" 2>/dev/null)
        [[ "$pol" == "unless-stopped" ]] && echo "CHECK restart-policy: PASS" || { echo "CHECK restart-policy: FAIL ($pol)"; fails=$((fails+1)); }
    fi
    # Gate 5: no 0.0.0.0 port bind to the outside.
    if ss -tlnp 2>/dev/null | grep -q "0.0.0.0"; then echo "CHECK port-bind: WARN (external bind present — review)"; else echo "CHECK port-bind: PASS"; fi
    return "$fails"
}

if [[ "$CHECK_MODE" -eq 1 ]]; then
    if [[ -z "${MEG_DEB:-}" || ! -f "$MEG_DEB" ]] && ! dpkg -s meg >/dev/null 2>&1 && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$MEG_CONTAINER"; then
        log "OK(check): MEG not supplied yet (SKIP state)"
        exit 0
    fi
    acceptance_checklist || { log "FAIL(check): MEG acceptance checklist failed"; exit 1; }
    log "OK(check): MEG acceptance checklist passed"
    exit 0
fi

if [[ "${MEG_SKIP:-0}" == "1" ]]; then log "SKIP: MEG_SKIP=1"; exit 3; fi

if ! dpkg -s meg >/dev/null 2>&1 && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MEG_CONTAINER"; then
    if [[ -n "${MEG_DEB:-}" && -f "$MEG_DEB" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        dpkg -i "$MEG_DEB" || apt-get install -f -y
        log "MEG package installed from $MEG_DEB"
    else
        log "SKIP: no MEG .deb supplied — vendor package pending, continuing"
        exit 3
    fi
else
    log "MEG already present, keeping"
fi

if ! acceptance_checklist; then
    log "FAIL: MEG acceptance checklist failed — see output above"
    exit 1
fi
log "OK: MEG present and acceptance checklist passed"
