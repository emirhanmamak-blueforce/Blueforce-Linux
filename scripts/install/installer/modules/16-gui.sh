#!/usr/bin/env bash
# GNOME minimal and maintained GUI maintenance tools; terminal boot remains default.
set -euo pipefail
MODULE="16-gui"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
CHECK_MODE=0
[[ "${1:-}" == "--check" ]] && CHECK_MODE=1
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [16-gui] $1" | tee -a "$LOG_FILE"; }
if [[ "$CHECK_MODE" -eq 1 ]]; then
    dpkg -s ubuntu-desktop-minimal >/dev/null 2>&1 || { log "FAIL(check): ubuntu-desktop-minimal missing"; exit 1; }
    [[ -x /usr/local/bin/bf-gui-on && -x /usr/local/bin/bf-gui-off ]] || { log "FAIL(check): maintained bf-gui switches missing"; exit 1; }
    [[ -f /etc/systemd/system/bf-gui-on.service && -f /etc/systemd/system/bf-gui-off.service ]] || { log "FAIL(check): manual GUI service units missing"; exit 1; }
    [[ "$(systemctl get-default)" == multi-user.target ]] || { log "FAIL(check): terminal boot default was changed"; exit 1; }
    log "OK(check): GNOME minimal, maintained switches, and terminal boot default present"; exit 0
fi
export DEBIAN_FRONTEND=noninteractive
dpkg -s ubuntu-desktop-minimal >/dev/null 2>&1 || apt-get install -y ubuntu-desktop-minimal
for tool in bf-gui-on bf-gui-off; do install -m 755 "$SCRIPT_ROOT/maintenance/$tool" "/usr/local/bin/$tool"; done
for unit in bf-gui-on.service bf-gui-off.service; do install -m 644 "$SCRIPT_ROOT/../config/systemd/$unit" "/etc/systemd/system/$unit"; done
systemctl daemon-reload
systemctl set-default multi-user.target
systemctl disable gdm3 2>/dev/null || systemctl disable gdm 2>/dev/null || true
log "OK: maintained GUI tools and manual units installed; boot default is multi-user"