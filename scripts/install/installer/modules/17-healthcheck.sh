#!/usr/bin/env bash
# Install diagnostics and enrollment commands without executing enrollment.
set -euo pipefail
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"; CHECK_MODE=0
[[ "${1:-}" == --check ]] && CHECK_MODE=1
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [17-healthcheck] $1" | tee -a "$LOG_FILE"; }
BINS=(bf-status bf-enroll bf-enroll-now bf-enrollment-status bf-release bf-remote-status bf-check-local bf-check-enrollment bf-check-ready)
if [[ "$CHECK_MODE" == 1 ]]; then
  for bin in "${BINS[@]}"; do [[ -x "/usr/local/bin/$bin" ]] || { log "FAIL(check): $bin missing"; exit 1; }; done
  [[ -f /etc/systemd/system/blueforce-enroll.service && -f /etc/systemd/system/blueforce-enroll.timer ]] || { log 'FAIL(check): enrollment units missing'; exit 1; }
  log 'OK(check): diagnostics and enrollment trigger installed'; exit 0
fi
install -d -m 700 "$STATE_DIR" /etc/blueforce
for bin in "${BINS[@]}"; do install -m 755 "$SCRIPT_ROOT/diagnostics/$bin" "/usr/local/bin/$bin"; done
install -m 644 "$SCRIPT_ROOT/../config/systemd/blueforce-enroll.service" /etc/systemd/system/blueforce-enroll.service
install -m 644 "$SCRIPT_ROOT/../config/systemd/blueforce-enroll.timer" /etc/systemd/system/blueforce-enroll.timer
[[ -f "$SCRIPT_ROOT/../provisioning/release/manifest.yaml" ]] && install -m 644 "$SCRIPT_ROOT/../provisioning/release/manifest.yaml" /etc/blueforce/release-manifest.yaml
systemctl daemon-reload
systemctl enable blueforce-enroll.timer >/dev/null 2>&1 || true
log 'OK: diagnostics installed; enrollment remains pending until an operator supplies a one-time token'
