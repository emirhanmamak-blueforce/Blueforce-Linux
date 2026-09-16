#!/usr/bin/env bash
# APT holds + disable automatic update timers.
set -euo pipefail
MODULE="14-update-policy"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
CHECK_MODE=0
[[ "${1:-}" == "--check" ]] && CHECK_MODE=1
APT_HOLDS="${APT_HOLDS:-}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [14-update-policy] $1" | tee -a "$LOG_FILE"; }
if [[ "$CHECK_MODE" -eq 1 ]]; then
    for t in apt-daily.timer apt-daily-upgrade.timer; do systemctl is-enabled "$t" 2>/dev/null | grep -q masked || { log "FAIL(check): $t not masked"; exit 1; }; done
    log "OK(check): update timers masked"; exit 0
fi
for t in apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer; do systemctl mask "$t" >/dev/null 2>&1 || true; systemctl stop "$t" >/dev/null 2>&1 || true; done
printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\nAPT::Periodic::Enable "0";\n' > /tmp/20auto-upgrades.bf
mv /tmp/20auto-upgrades.bf /etc/apt/apt.conf.d/20auto-upgrades
if [[ -n "$APT_HOLDS" ]]; then
    read -r -a apt_holds <<< "$APT_HOLDS"
    ((${#apt_holds[@]})) && apt-mark hold -- "${apt_holds[@]}"
    log "holds applied: ${apt_holds[*]}"
fi
log "OK: automatic updates locked off (timers masked, periodic=0)"