#!/usr/bin/env bash
# Blueforce one-click installer — single entry point for field setup.
set -euo pipefail
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$INSTALLER_DIR/installer/modules"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"
STATE_FILE="$STATE_DIR/install-state"
MODULES=(01-precheck 02-system 03-user 04-hostname 05-network 06-wireguard 07-ssh 08-rdp 09-rustdesk 10-docker 11-meg 12-monitoring 13-firewall 14-update-policy 15-logrotate 16-gui 17-healthcheck 18-final-check)
DEALER_ID="" FROM="" ONLY="" CHECK_MODE=0 RESUME=0 ASSUME_YES=0 OFFLINE=0
BF_OFFLINE_REPO="${BF_OFFLINE_REPO:-/opt/blueforce/offline-repo}"
usage() { cat <<'EOF'
Usage: sudo ./blueforce-install.sh --dealer-id <8 digits> [--offline] [--from NN] [--only NAME] [--check] [--resume] [--yes]
--offline uses supplied local packages only and completes as PROVISIONED_OFFLINE.
--check is read-only: it creates no logs, state, or directories.
EOF
}
while [[ $# -gt 0 ]]; do case "$1" in --dealer-id) DEALER_ID="${2:-}"; shift 2;; --offline) OFFLINE=1; shift;; --from) FROM="${2:-}"; shift 2;; --only) ONLY="${2:-}"; shift 2;; --check) CHECK_MODE=1; shift;; --resume) RESUME=1; shift;; --yes|-y) ASSUME_YES=1; shift;; --help|-h) usage; exit 0;; *) echo "Unknown argument: $1" >&2; usage >&2; exit 2;; esac; done
[[ -n "$DEALER_ID" ]] || { echo "Missing --dealer-id (8 digits)" >&2; exit 2; }
[[ "$DEALER_ID" =~ ^[0-9]{8}$ ]] || { echo "Invalid dealer id '$DEALER_ID': must match ^[0-9]{8}$" >&2; exit 2; }
log() { if [[ "$CHECK_MODE" -eq 1 ]]; then printf '[installer check] %s\n' "$1" >&2; else mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [installer] $1" | tee -a "$LOG_FILE"; fi; }
record_state() { mkdir -p "$STATE_DIR"; local tmp="$STATE_FILE.tmp"; grep -v "^$1=" "$STATE_FILE" 2>/dev/null > "$tmp" || true; echo "$1=$2" >> "$tmp"; mv "$tmp" "$STATE_FILE"; }
state_of() { grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true; }
export DEALER_ID BF_HOSTNAME="bf-${DEALER_ID}" BF_DEVICE="BF-${DEALER_ID}" STATE_DIR BF_OFFLINE="$OFFLINE" BF_OFFLINE_REPO
validate_offline_repository() {
  local manifest pin package version source
  [[ "$BF_OFFLINE_REPO" = /* && -d "$BF_OFFLINE_REPO" ]] || { echo "OFFLINE BLOCKED: BF_OFFLINE_REPO must be an existing absolute local directory." >&2; return 1; }
  [[ -s "$BF_OFFLINE_REPO/Packages" && -s "$BF_OFFLINE_REPO/Packages.gz" && -s "$BF_OFFLINE_REPO/packages.lock.tsv" && -s "$BF_OFFLINE_REPO/SHA256SUMS" ]] || { echo 'OFFLINE BLOCKED: local APT index, lock, or checksums are missing; ISO bundle is incomplete.' >&2; return 1; }
  (cd "$BF_OFFLINE_REPO" && sha256sum -c SHA256SUMS >/dev/null) || { echo 'OFFLINE BLOCKED: local APT repository checksum validation failed.' >&2; return 1; }
  awk -F '\t' 'NR == 1 { if ($0 != "package\tversion\tarchitecture\tsha256\tsource") exit 1; next } $1 !~ /^[a-z0-9][a-z0-9+.-]*$/ || $2 == "" || $3 == "" || $4 !~ /^[a-f0-9]{64}$/ || $5 == "" { exit 1 } END { exit NR < 2 }' "$BF_OFFLINE_REPO/packages.lock.tsv" || { echo 'OFFLINE BLOCKED: package lock is empty or invalid.' >&2; return 1; }
  for manifest in "$INSTALLER_DIR/../../provisioning/offline-repo/manifests"/*.txt; do
    [[ -s "$manifest" ]] || { echo "OFFLINE BLOCKED: required pin manifest is empty: $(basename "$manifest")." >&2; return 1; }
    while IFS= read -r pin || [[ -n "$pin" ]]; do
      [[ -z "$pin" || "$pin" == \#* ]] && continue
      [[ "$pin" =~ ^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$ ]] && [[ "$pin" != *placeholder* && "$pin" != *REPLACE* && "$pin" != *replace* ]] || { echo "OFFLINE BLOCKED: invalid package pin in $(basename "$manifest")." >&2; return 1; }
      package="${pin%%=*}"; version="${pin#*=}"
      source="$(awk -F '\t' -v p="$package" -v v="$version" '$1 == p && $2 == v {print $5; exit}' "$BF_OFFLINE_REPO/packages.lock.tsv")"
      [[ -n "$source" && -f "$BF_OFFLINE_REPO/pool/$source" ]] || { echo "OFFLINE BLOCKED: pinned package absent from bundle: $package." >&2; return 1; }
    done < "$manifest"
    grep -qvE '^[[:space:]]*(#|$)' "$manifest" || { echo "OFFLINE BLOCKED: required pin manifest has no package pins: $(basename "$manifest")." >&2; return 1; }
  done
  install -d -m 700 "$STATE_DIR"
  printf 'deb [trusted=yes] file:%s ./\n' "$BF_OFFLINE_REPO" > "$STATE_DIR/offline.list"
  chmod 600 "$STATE_DIR/offline.list"
  BF_OFFLINE_APT_CONFIG="$(mktemp)"; chmod 600 "$BF_OFFLINE_APT_CONFIG"
  printf 'Dir::Etc::sourcelist "%s";\nDir::Etc::sourceparts "-";\nAcquire::Languages "none";\n' "$STATE_DIR/offline.list" > "$BF_OFFLINE_APT_CONFIG"
  export BF_OFFLINE_APT_CONFIG
}
if [[ "$OFFLINE" -eq 1 ]]; then
  validate_offline_repository || exit 1
fi
if [[ "$CHECK_MODE" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then read -r -p "Proceed with installation as $BF_DEVICE? [y/N] " answer; [[ "$answer" =~ ^[Yy]$ ]] || { echo Aborted.; exit 2; }; fi
RUN=(); for m in "${MODULES[@]}"; do
  if [[ -n "$ONLY" ]]; then [[ "$m" == "$ONLY" || "$m" == "$ONLY"* ]] && RUN+=("$m"); continue; fi
  [[ -n "$FROM" && "${m%%-*}" < "$FROM" ]] && continue
  if [[ "$CHECK_MODE" -eq 0 && "$RESUME" -eq 1 && "$(state_of "$m")" == OK ]]; then log "SKIP $m (already OK)"; continue; fi
  RUN+=("$m")
done
[[ ${#RUN[@]} -gt 0 ]] || { echo "No modules selected." >&2; exit 2; }
log "=== install start dealer=$BF_DEVICE mode=$([[ "$CHECK_MODE" -eq 1 ]] && echo check || echo apply) modules=${RUN[*]} ==="
failures=0
for m in "${RUN[@]}"; do
 script="$MODULES_DIR/$m.sh"; if [[ ! -x "$script" ]]; then log "FAIL $m (script missing)"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" FAIL; failures=$((failures+1)); break; fi
 args=(); [[ "$CHECK_MODE" -eq 1 ]] && args+=(--check)
 set +e; if [[ "$CHECK_MODE" -eq 1 ]]; then LOG_FILE=/dev/null bash "$script" "${args[@]}"; else LOG_FILE="$LOG_FILE" bash "$script"; fi; rc=$?; set -e
 case "$rc" in 0) log "OK $m"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" OK;; 3) log "SKIP $m"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" SKIP;; *) log "FAIL $m (exit $rc)"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" FAIL; failures=$((failures+1)); [[ "$CHECK_MODE" -eq 0 ]] && exit 1;; esac
done
[[ "$CHECK_MODE" -eq 1 && "$failures" -gt 0 ]] && exit 1
if [[ "$CHECK_MODE" -eq 0 && "$OFFLINE" -eq 1 && "$failures" -eq 0 ]]; then
  install -d -m 700 "$STATE_DIR"
  umask 077
  python3 - "$STATE_DIR/state.json" "$DEALER_ID" <<'PY'
import json, os, sys, tempfile, uuid
path, dealer = sys.argv[1:]
state={'phase':'PROVISIONED_OFFLINE','enrollment_status':'PENDING','fleet_status':'PENDING','device_id':'BF-'+dealer,'provisioning_id':str(uuid.uuid4())}
fd,tmp=tempfile.mkstemp(prefix='state.json.',dir=os.path.dirname(path)); os.fchmod(fd,0o600)
with os.fdopen(fd,'w') as f: json.dump(state,f,sort_keys=True); f.write('\n')
os.replace(tmp,path)
PY
  chmod 600 "$STATE_DIR/state.json"
  log "OFFLINE COMPLETE: device is PROVISIONED_OFFLINE; enrollment is required before READY"
fi
log "=== install done dealer=$BF_DEVICE failures=$failures ==="