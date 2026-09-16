#!/usr/bin/env bash
# WireGuard local identity: provisioning creates only a device keypair; enrollment owns wg0.conf.
set -euo pipefail
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"; WG_DIR="${WG_DIR:-/etc/wireguard}"; CHECK_MODE=0
[[ "${1:-}" == --check ]] && CHECK_MODE=1
OFFLINE="${BF_OFFLINE:-0}"
# READY freshness is checked by bf-check-ready with BF_WG_HANDSHAKE_MAX_AGE.
BF_WG_HANDSHAKE_MAX_AGE="${BF_WG_HANDSHAKE_MAX_AGE:-180}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [06-wireguard] $1" | tee -a "$LOG_FILE"; }
keypair() { [[ -s "$WG_DIR/privatekey" && -s "$WG_DIR/publickey" ]]; }
if [[ "$CHECK_MODE" == 1 ]]; then
  keypair || { log 'FAIL(check): WireGuard device keypair missing'; exit 1; }
  if [[ "$OFFLINE" == 1 ]]; then [[ ! -e "$WG_DIR/wg0.conf" ]] || { log 'FAIL(check): offline provisioning must not create wg0.conf'; exit 1; }; log 'OK(check): offline WireGuard identity only'; exit 0; fi
  [[ -f "$WG_DIR/wg0.conf" ]] || { log 'FAIL(check): enrollment WireGuard config missing'; exit 1; }
  systemctl is-enabled --quiet wg-quick@wg0 && systemctl is-active --quiet wg-quick@wg0 || { log 'FAIL(check): enrolled WireGuard inactive'; exit 1; }
  log 'OK(check): enrolled WireGuard active'; exit 0
fi
command -v wg >/dev/null 2>&1 || { [[ "$OFFLINE" == 1 ]] && { log 'FAIL: offline media must supply wireguard-tools'; exit 1; }; apt-get update && apt-get install -y wireguard-tools; }
install -d -m 700 "$WG_DIR"
if ! keypair; then umask 077; wg genkey | tee "$WG_DIR/privatekey" | wg pubkey > "$WG_DIR/publickey"; chmod 600 "$WG_DIR/privatekey" "$WG_DIR/publickey"; fi
if [[ "$OFFLINE" == 1 ]]; then rm -f "$WG_DIR/wg0.conf"; systemctl disable --now wg-quick@wg0 2>/dev/null || true; log 'OK: offline WireGuard keypair generated; hub configuration deferred to enrollment'; exit 0; fi
log 'OK: WireGuard keypair ready; use bf-enroll --token-stdin to obtain hub configuration'
