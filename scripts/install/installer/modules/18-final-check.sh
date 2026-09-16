#!/usr/bin/env bash
# Final lifecycle gate: offline completes locally; READY requires enrolled remote proof.
set -euo pipefail
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"; STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"; CHECK_MODE=0
[[ "${1:-}" == --check ]] && CHECK_MODE=1
OFFLINE="${BF_OFFLINE:-0}"; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [18-final-check] $1" | tee -a "$LOG_FILE"; }
if [[ "$OFFLINE" == 1 ]]; then
  # Only local gates are meaningful offline. No central peer, handshake, or READY claim.
  for g in 01-precheck 02-system 03-user 04-hostname 05-network 06-wireguard 07-ssh 08-rdp 10-docker 11-meg 12-monitoring 13-firewall 14-update-policy 15-logrotate 16-gui 17-healthcheck; do
    LOG_FILE=/dev/null BF_OFFLINE=1 bash "$SCRIPT_DIR/$g.sh" --check >/dev/null || { log "FAIL: offline local gate $g failed"; exit 1; }
  done
  [[ "$CHECK_MODE" == 1 ]] && { log 'OK(check): offline local gates pass'; exit 0; }
  log 'OK: offline local gates pass; installer records PROVISIONED_OFFLINE'; exit 0
fi
[[ "$CHECK_MODE" == 1 ]] && exec /usr/local/bin/bf-check-ready
/usr/local/bin/bf-check-ready
python3 - "$STATE_DIR/state.json" <<'PY'
import json,os,sys,tempfile
p=sys.argv[1]; s=json.load(open(p));
if s.get('phase') not in ('ENROLLED','READY'): raise SystemExit('not enrolled')
s.update({'phase':'READY','fleet_status':'READY'})
fd,t=tempfile.mkstemp(prefix='state.json.',dir=os.path.dirname(p)); os.fchmod(fd,0o600)
with os.fdopen(fd,'w') as f: json.dump(s,f,sort_keys=True); f.write('\n')
os.replace(t,p)
PY
log 'OK: enrolled device has current handshake and remote checks; READY recorded'
