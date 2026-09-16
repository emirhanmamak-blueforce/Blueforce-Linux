#!/usr/bin/env bash
# Exercise the Field OS lifecycle, enrollment and readiness contracts with mocked local services.
#
# This host has no systemd, no apt and no internet, so every external dependency
# (systemctl, wg, ip, dpkg-query, curl) is a mock in $TMP/bin. Scenarios:
#
#   1  secret-safe enrollment request/header/response path
#   2  offline installer fails closed without a local repository
#   3  failed WireGuard activation rolls back and keeps the prior phase
#   4  ROLLBACK/READY: independent proof, fail-closed without central evidence
#   5  skeleton release manifest is never a production release
#   6  state machine: forward-only, no stage skipping, contract validation
#   7  bf-check-local passes without internet and fails closed on key hygiene
#   8  bf-check-enrollment requires central evidence, peer config and handshake
#   9  replay/backwards protection and atomic 0600 state writes
#  10  systemd attempt: PENDING without a token, bounded retry with one staged
#  11  --check dry run never mutates state or sends a request
#  12  enrollment schemas match the real client behaviour
#  13  boot unit cannot loop, carries no credential and stays bounded
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/scripts/diagnostics"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'OK: %s\n' "$*"; }

PUBLIC_KEY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
SERVER_KEY='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
DEALER='12345678'
ENDPOINT='https://control.blueforce.test/enroll'

make_mock_bin() {
  local d="$1"
  mkdir -p "$d"
  cat > "$d/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_CALLS"
case "${1:-}" in
  is-active) [[ "${MOCK_SYSTEMCTL_FAIL:-0}" != 1 ]] ;;
  is-enabled) [[ "${MOCK_SYSTEMCTL_FAIL:-0}" != 1 ]] ;;
  enable|restart) [[ "${MOCK_SYSTEMCTL_FAIL:-0}" != 1 ]] ;;
  get-default) printf 'multi-user.target\n' ;;
  *) exit 0 ;;
esac
EOF
  cat > "$d/curl" <<'EOF'
#!/usr/bin/env bash
# Mock curl: records argv, captures the request file and the header fd, then
# either writes the canned response or fails like a transport/protocol error.
set -euo pipefail
request='' output='' header='' code=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-binary) request="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --write-out) code="$2"; shift 2 ;;
    -H|--header) header="$2"; shift 2 ;;
    *) printf 'argv=%s\n' "$1" >> "$MOCK_CURL_LOG"; shift ;;
  esac
done
[[ "$request" == @* ]] || exit 91
cat "${request#@}" > "$MOCK_REQUEST_CAPTURE"
[[ "$header" == @* ]] || exit 92
cat "${header#@}" > "$MOCK_HEADER_CAPTURE"
if [[ "${MOCK_CURL_FAIL:-0}" == 1 ]]; then
  printf '%s' "${MOCK_HTTP_CODE:-000}"
  exit "${MOCK_CURL_RC:-7}"
fi
printf '%s' "$MOCK_RESPONSE" > "$output"
[[ -z "$code" ]] || printf '%s' "${MOCK_HTTP_CODE:-200}"
EOF
  cat > "$d/wg" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  show) printf 'peer %s\n' "${MOCK_HANDSHAKE:-0}" ;;
  pubkey) IFS= read -r _key || true; printf '%s\n' "${MOCK_PUBLIC_KEY:-}" ;;
  *) exit 0 ;;
esac
EOF
  cat > "$d/ip" <<'EOF'
#!/usr/bin/env bash
[[ "${MOCK_IP_FAIL:-0}" == 1 ]] && exit 1
exit 0
EOF
  cat > "$d/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed'
EOF
  chmod +x "$d"/*
}

MOCK_BIN="$TMP/bin"; make_mock_bin "$MOCK_BIN"
export PATH="$MOCK_BIN:$PATH" MOCK_CALLS="$TMP/calls" MOCK_CURL_LOG="$TMP/curl-argv"
export MOCK_REQUEST_CAPTURE="$TMP/request" MOCK_HEADER_CAPTURE="$TMP/header"
export MOCK_PUBLIC_KEY="$PUBLIC_KEY"
STATE_DIR="$TMP/state"; WG_DIR="$TMP/wg"; mkdir -p "$STATE_DIR" "$WG_DIR"
printf '%s\n' "$DEALER" > "$STATE_DIR/dealer-id"
printf '%s\n' 'private-test-key' > "$WG_DIR/privatekey"
printf '%s\n' "$PUBLIC_KEY" > "$WG_DIR/publickey"
chmod 600 "$WG_DIR/privatekey" "$WG_DIR/publickey" "$STATE_DIR/dealer-id"
export STATE_DIR WG_DIR BF_STATE_FILE="$STATE_DIR/state.json"
IDEM="$(python3 -c "import hashlib,sys;print(hashlib.sha256(('p-1|BF-'+sys.argv[1]+'|'+sys.argv[2]).encode()).hexdigest())" "$DEALER" "$PUBLIC_KEY")"

write_state() { printf '%s\n' "$1" > "$BF_STATE_FILE"; chmod 600 "$BF_STATE_FILE"; }
state_field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$BF_STATE_FILE" "$1"; }
central_pending='{"status":"pending","verification_id":"cv-1","monitoring":{"status":"pending","verification_id":"mon-1"},"remote":{"status":"pending","verification_id":"rem-1"},"management":{"status":"pending","verification_id":"mgmt-1"}}'
central_verified='{"status":"verified","verification_id":"cv-1","monitoring":{"status":"verified","verification_id":"mon-1"},"remote":{"status":"verified","verification_id":"rem-1"},"management":{"status":"verified","verification_id":"mgmt-1"}}'
pending_state="{\"phase\":\"PROVISIONED_OFFLINE\",\"enrollment_status\":\"PENDING\",\"fleet_status\":\"PENDING\",\"device_id\":\"BF-$DEALER\",\"provisioning_id\":\"p-1\"}"
enrolled_state() { printf '{"phase":"ENROLLED","enrollment_status":"ENROLLED","fleet_status":"PENDING","device_id":"BF-%s","provisioning_id":"p-1","central_verification":%s}' "$DEALER" "$1"; }
ready_state() { printf '{"phase":"READY","enrollment_status":"ENROLLED","fleet_status":"READY","device_id":"BF-%s","provisioning_id":"p-1","central_verification":%s}' "$DEALER" "$1"; }
mocked_response() { printf '{"status":"accepted","device_id":"BF-%s","idempotency_key":"%s","enrollment_id":"enr-1","wireguard":{"address":"10.20.0.17/32","endpoint":"wg.blueforce.test:51820","server_public_key":"%s","allowed_ips":"10.20.0.0/24"},"central_verification":%s}' "$DEALER" "$IDEM" "$SERVER_KEY" "$1"; }

# --- scenario 1: the secret-safe enrollment path ----------------------------
write_state "$pending_state"
export MOCK_RESPONSE="$(mocked_response "$central_verified")"
printf '%s\n' 'super-secret-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin >/dev/null
[[ "$(state_field phase)" == 'ENROLLED' ]] || fail 'successful enrollment must commit ENROLLED'
[[ -s "$WG_DIR/wg0.conf" ]] || fail 'successful enrollment must install wg0.conf'
[[ "$(stat -c '%a' "$WG_DIR/wg0.conf")" == '600' ]] || fail 'wg0.conf must be mode 600'
[[ "$(stat -c '%a' "$BF_STATE_FILE")" == '600' ]] || fail 'state.json must be mode 600'
grep -q "BF-$DEALER" "$MOCK_REQUEST_CAPTURE" || fail 'curl must consume the generated request file'
grep -Fqx 'Authorization: Bearer super-secret-token' "$MOCK_HEADER_CAPTURE" || fail 'curl must receive the exact supplied token through process substitution'
! grep -R -F 'super-secret-token' "$TMP" --exclude=header --exclude=request --exclude=enrollment.token || fail 'token persisted outside the transient curl fixture'
! grep -R -F 'super-secret-token' "$MOCK_CURL_LOG" "$STATE_DIR" 2>/dev/null || fail 'token leaked to curl argv, output, or state'
pass 'curl request/header/response path is secret-safe and functional'

# --- scenario 12 (early check): request body carries public facts only -------
python3 - "$MOCK_REQUEST_CAPTURE" "$PUBLIC_KEY" <<'PY'
import json, sys
request = json.load(open(sys.argv[1], encoding='utf-8'))
if set(request) != {'device_id', 'wireguard_public_key', 'idempotency_key', 'hardware', 'release'}:
    raise SystemExit('unexpected request field set: %s' % sorted(request))
if request['wireguard_public_key'] != sys.argv[2]:
    raise SystemExit('request must carry the local public key')
blob = json.dumps(request).lower()
for banned in ('private', 'secret', 'password', 'passwd', 'bearer', 'authorization'):
    if banned in blob:
        raise SystemExit('request carries a secret-like field: ' + banned)
PY
! grep -q 'private-test-key' "$MOCK_REQUEST_CAPTURE" || fail 'the WireGuard private key must never be sent'
! grep -q 'super-secret-token' "$MOCK_REQUEST_CAPTURE" || fail 'the one-time token must never be sent in the request body'
pass 'request carries public facts only: no private key, no token, no credential'

# --- scenario 2: offline installer fails closed -----------------------------
cat > "$MOCK_BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_APT_CALLS"
exit 90
EOF
chmod +x "$MOCK_BIN/apt-get"
export MOCK_APT_CALLS="$TMP/apt-calls"
if STATE_DIR="$TMP/offline-state" LOG_FILE="$TMP/offline.log" BF_OFFLINE_REPO="$TMP/missing-offline-repo" "$REPO_ROOT/scripts/install/blueforce-install.sh" --offline --dealer-id "$DEALER" --only 02-system --yes > "$TMP/offline.out" 2>&1; then fail 'offline installer must reject a missing local repository before modules'; fi
[[ ! -e "$MOCK_APT_CALLS" ]] || fail 'offline repository rejection must not invoke apt-get'
! grep -Eqi '(curl|wget|https?://|apt[[:space:]]+download)' "$TMP/offline.out" "$TMP/offline.log" 2>/dev/null || fail 'offline rejection must not run or report network package acquisition'
pass 'offline installer fails closed before package modules when local repository is absent'

# --- scenario 3: activation failure rolls back, phase is preserved ----------
write_state "$pending_state"
rm -f "$WG_DIR/wg0.conf"
export MOCK_SYSTEMCTL_FAIL=1
if printf '%s\n' 'another-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin; then fail 'activation failure must fail enrollment'; fi
[[ "$(state_field phase)" == 'PROVISIONED_OFFLINE' ]] || fail 'activation failure must not commit ENROLLED'
[[ "$(state_field enrollment_status)" == 'PENDING' ]] || fail 'activation failure must leave enrollment PENDING'
[[ ! -e "$WG_DIR/wg0.conf" ]] || fail 'activation failure must roll back a new config'
[[ -z "$(find "$STATE_DIR" -name '.state.json.*' -print -quit)" ]] || fail 'atomic state writes must leave no temporary files'
unset MOCK_SYSTEMCTL_FAIL
pass 'state transition rolls back on WireGuard activation failure and stays PENDING'

# --- scenario 4: READY proof is independent and fails closed ----------------
printf '%s\n' 'third-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin >/dev/null
[[ -s "$WG_DIR/wg0.conf" ]] || fail 're-enrollment after a rolled-back attempt must install wg0.conf'
RUST_SYSTEM="$TMP/RustDesk-system.toml"; RUST_USER="$TMP/RustDesk-user.toml"
printf "rendezvous-server = 'rustdesk.blueforce.test'\nrelay-server = 'rustdesk.blueforce.test'\n" > "$RUST_SYSTEM"
cp "$RUST_SYSTEM" "$RUST_USER"
export MOCK_HANDSHAKE="$(date +%s)" BF_RUSTDESK_SYSTEM_CONFIG="$RUST_SYSTEM" BF_RUSTDESK_USER_CONFIG="$RUST_USER" BF_MESH_CONFIG="$TMP/no-mesh"
python3 - "$BF_STATE_FILE" "$central_verified" <<'PY'
import json, sys
path, verified = sys.argv[1], json.loads(sys.argv[2])
state = json.load(open(path, encoding='utf-8'))
state['central_verification'] = verified
json.dump(state, open(path, 'w', encoding='utf-8'))
PY
"$BIN/bf-check-ready" >/dev/null || fail 'ENROLLED state with independent local and central evidence must become ready-check eligible'
python3 - "$BF_STATE_FILE" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path, encoding='utf-8'))
del state['central_verification']
json.dump(state, open(path, 'w', encoding='utf-8'))
PY
if "$BIN/bf-check-ready" > "$TMP/ready-failclosed.out" 2>&1; then fail 'missing central verification evidence must fail closed'; fi
if "$BIN/bf-check-enrollment" > "$TMP/enroll-failclosed.out" 2>&1; then fail 'the ENROLLED gate must fail closed without central evidence'; fi
grep -q 'central_verification is missing' "$TMP/enroll-failclosed.out" || fail 'the ENROLLED gate must name the missing central evidence'
pass 'READY proof is independent of persisted READY and fails closed without central evidence'

# --- scenario 5: skeleton release manifest ----------------------------------
RELEASE="$TMP/release.yaml"
printf 'release:\n  name: blueforce-provisioning-skeleton\n  version: 0.1.0\n  status: skeleton\n  commit: deadbeef\n' > "$RELEASE"
if BF_RELEASE_MANIFEST="$RELEASE" "$BIN/bf-release" > "$TMP/release.out"; then fail 'skeleton release must be nonzero'; fi
grep -q 'UNAPPROVED_SKELETON' "$TMP/release.out" || fail 'skeleton release must be labelled unapproved'
pass 'nested skeleton manifest is not represented as a production release'

# --- scenario 6: state machine contract -------------------------------------
write_state "$pending_state"
[[ "$("$BIN/bf-enrollment-status" --field phase)" == 'PROVISIONED_OFFLINE' ]] || fail 'canonical reader must report the provisioned phase'
write_state "$(enrolled_state "$central_pending")"
"$BIN/bf-enrollment-status" | grep -qx 'Enrollment: ENROLLED' || fail 'ENROLLED stage must be visible before READY'
write_state "$(ready_state "$central_verified")"
"$BIN/bf-enrollment-status" > "$TMP/ready-status.out" || fail 'READY with verified central evidence must be contract-valid'
grep -qx 'Lifecycle: READY' "$TMP/ready-status.out" || fail 'READY stage must be reported'
grep -qx 'Enrollment: COMPLETE' "$TMP/ready-status.out" || fail 'READY implies a complete enrollment'
grep -qx 'Fleet: READY' "$TMP/ready-status.out" || fail 'READY implies fleet READY'
write_state "{\"phase\":\"READY\",\"enrollment_status\":\"PENDING\",\"fleet_status\":\"READY\",\"device_id\":\"BF-$DEALER\",\"provisioning_id\":\"p-1\"}"
if "$BIN/bf-enrollment-status" > "$TMP/skip.out" 2>/dev/null; then fail 'a skipped stage (PROVISIONED_OFFLINE -> READY) must be INVALID'; fi
grep -qx 'Lifecycle: INVALID' "$TMP/skip.out" || fail 'skipped stage must be reported as INVALID'
write_state "$(ready_state "$central_pending")"
if "$BIN/bf-enrollment-status" >/dev/null 2>&1; then fail 'READY without verified channels must be INVALID'; fi
write_state "{\"phase\":\"PROVISIONED_OFFLINE\",\"enrollment_status\":\"PENDING\",\"fleet_status\":\"PENDING\",\"device_id\":\"BF-$DEALER\"}"
if "$BIN/bf-enrollment-status" >/dev/null 2>&1; then fail 'a state without provisioning_id must be INVALID'; fi
if BF_STATE_FILE="$TMP/absent.json" "$BIN/bf-enrollment-status" > "$TMP/absent.out" 2>/dev/null; then fail 'a missing state file must exit non-zero'; fi
grep -qx 'Lifecycle: PENDING' "$TMP/absent.out" || fail 'a missing state file must report PENDING'
pass 'state machine is forward-only, never skips a stage and validates its contract'

# --- scenario 6b: bf-status lifecycle block ---------------------------------
write_state "$(enrolled_state "$central_pending")"
BF_STATE_FILE="$BF_STATE_FILE" "$BIN/bf-status" > "$TMP/status.out" 2>/dev/null || fail 'bf-status must always exit 0'
grep -qx 'Provisioning : COMPLETE' "$TMP/status.out" || fail 'bf-status must show Provisioning : COMPLETE once central accepted the device'
grep -qx 'Enrollment   : ENROLLED' "$TMP/status.out" || fail 'bf-status must show Enrollment : ENROLLED'
grep -qx 'Fleet State  : NOT READY' "$TMP/status.out" || fail 'bf-status must show Fleet State : NOT READY before READY'
write_state "$pending_state"
"$BIN/bf-status" > "$TMP/status-pending.out" 2>/dev/null
grep -qx 'Provisioning : PROVISIONED_OFFLINE' "$TMP/status-pending.out" || fail 'bf-status must show the offline provisioning stage'
grep -qx 'Enrollment   : PENDING' "$TMP/status-pending.out" || fail 'bf-status must show a pending enrollment'
write_state "$(ready_state "$central_verified")"
"$BIN/bf-status" > "$TMP/status-ready.out" 2>/dev/null
grep -qx 'Fleet State  : READY' "$TMP/status-ready.out" || fail 'bf-status must show Fleet State : READY'
write_state "{\"phase\":\"READY\",\"enrollment_status\":\"PENDING\",\"fleet_status\":\"READY\",\"device_id\":\"BF-$DEALER\",\"provisioning_id\":\"p-1\"}"
"$BIN/bf-status" > "$TMP/status-invalid.out" 2>/dev/null
grep -q 'lifecycle state invalid' "$TMP/status-invalid.out" || fail 'bf-status must raise a critical alert for an invalid lifecycle state'
pass 'bf-status prints the Provisioning/Enrollment/Fleet State lifecycle block'

# --- scenario 7: local gate is offline-safe ---------------------------------
write_state "$pending_state"
rm -f "$WG_DIR/wg0.conf" "$STATE_DIR/enrollment.token"
"$BIN/bf-check-local" > "$TMP/local.out" 2>&1 || fail 'bf-check-local must pass offline with no handshake and no wg0.conf'
grep -q 'local gates PASS' "$TMP/local.out" || fail 'bf-check-local must report a passing local gate'
! grep -q '^FAIL' "$TMP/local.out" || fail 'bf-check-local must not fail any local gate offline'
"$BIN/bf-check-local" --check >/dev/null 2>&1 || fail 'bf-check-local --check must behave like the default run'
[[ ! -e "$WG_DIR/wg0.conf" ]] || fail 'bf-check-local must not create enrollment artifacts'
! grep -Eq '(^|/)(curl|wget|apt|apt-get)( |$)' "$TMP/calls" 2>/dev/null || fail 'bf-check-local must not call network tools'
chmod 644 "$WG_DIR/privatekey"
if "$BIN/bf-check-local" >/dev/null 2>&1; then fail 'a world-readable WireGuard private key must fail the local gate'; fi
chmod 600 "$WG_DIR/privatekey"
MOCK_PUBLIC_KEY='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=' "$BIN/bf-check-local" >/dev/null 2>&1 && fail 'a mismatched WireGuard keypair must fail the local gate'
if BF_STATE_FILE="$TMP/absent.json" "$BIN/bf-check-local" >/dev/null 2>&1; then fail 'a missing state file must fail the local gate'; fi
pass 'bf-check-local passes offline and fails closed on key hygiene'

# --- scenario 8: ENROLLED gate needs evidence and a live tunnel -------------
write_state "$pending_state"
rm -f "$WG_DIR/wg0.conf"
printf '%s\n' 'enrolled-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin >/dev/null
export MOCK_HANDSHAKE="$(date +%s)"
[[ -s "$WG_DIR/wg0.conf" ]] || fail 'a successful enrollment must install the assigned peer configuration'
[[ "$(state_field phase)" == 'ENROLLED' ]] || fail 'a successful enrollment must commit ENROLLED'
"$BIN/bf-check-enrollment" >/dev/null || fail 'ENROLLED gates must pass with peer config, live tunnel and a fresh handshake'
MOCK_HANDSHAKE=0 "$BIN/bf-check-enrollment" >/dev/null 2>&1 && fail 'a missing WireGuard handshake must fail the ENROLLED gate'
export MOCK_HANDSHAKE="$(date +%s)"
MOCK_IP_FAIL=1 "$BIN/bf-check-enrollment" >/dev/null 2>&1 && fail 'a missing wg0 interface must fail the ENROLLED gate'
MOCK_IP_FAIL=1 "$BIN/bf-check-ready" >/dev/null 2>&1 && fail 'a missing wg0 interface must fail the READY gate'
mv "$WG_DIR/wg0.conf" "$TMP/wg0.conf.keep"
"$BIN/bf-check-enrollment" >/dev/null 2>&1 && fail 'a missing peer configuration must fail the ENROLLED gate'
mv "$TMP/wg0.conf.keep" "$WG_DIR/wg0.conf"
write_state "$pending_state"
"$BIN/bf-check-enrollment" >/dev/null 2>&1 && fail 'PROVISIONED_OFFLINE must never pass the ENROLLED gate'
write_state "$(enrolled_state "$central_pending")"
"$BIN/bf-check-enrollment" >/dev/null || fail 'a device with pending central channels is still ENROLLED'
if "$BIN/bf-check-ready" >/dev/null 2>&1; then fail 'pending central channels must never produce READY'; fi
pass 'bf-check-enrollment requires central evidence, peer configuration and a fresh handshake'

# --- scenario 9: replay and backwards protection ----------------------------
write_state "$pending_state"
printf '%s\n' 'replay-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin >/dev/null
REPLAY_BEFORE="$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))" "$BF_STATE_FILE")"
if printf '%s\n' 'replay-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin > "$TMP/replay.out" 2>&1; then fail 'a second enrollment without --reenroll must be refused'; fi
grep -q 'already ENROLLED' "$TMP/replay.out" || fail 'the replay refusal must explain the ENROLLED state'
REPLAY_AFTER="$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))" "$BF_STATE_FILE")"
[[ "$REPLAY_BEFORE" == "$REPLAY_AFTER" ]] || fail 'a refused replay must not touch the state file'
printf '%s\n' 'replay-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin --reenroll >/dev/null || fail '--reenroll must re-apply enrollment'
[[ "$(state_field phase)" == 'ENROLLED' ]] || fail '--reenroll must never move the phase backwards'
write_state "$(ready_state "$central_verified")"
if printf '%s\n' 'replay-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin --reenroll > "$TMP/ready-refusal.out" 2>&1; then fail 'a READY device must refuse enrollment even with --reenroll'; fi
grep -q 'never move backwards' "$TMP/ready-refusal.out" || fail 'the READY refusal must explain the forward-only rule'
[[ "$(state_field phase)" == 'READY' ]] || fail 'the READY refusal must not change the phase'
[[ "$(stat -c '%a' "$BF_STATE_FILE")" == '600' ]] || fail 'state writes must stay at mode 600'
[[ -z "$(find "$STATE_DIR" -name '.state.json.*' -print -quit)" ]] || fail 'atomic writes must not leave temporary files'
pass 'replay and backwards transitions are refused, state writes are atomic and 0600'

# --- scenario 10: systemd attempt and staged token --------------------------
write_state "$pending_state"
rm -f "$WG_DIR/wg0.conf" "$STATE_DIR/enrollment.token"
BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --systemd > "$TMP/pending.out" 2>&1 || fail 'the boot attempt must exit 0 while nothing is staged'
grep -q 'PENDING' "$TMP/pending.out" || fail 'the boot attempt must report PENDING'
[[ ! -e "$WG_DIR/wg0.conf" ]] || fail 'a pending boot attempt must not install a config'
BF_STATE_FILE="$TMP/absent.json" BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --systemd > "$TMP/unprovisioned.out" 2>&1 || fail 'an unprovisioned device must exit 0 so the unit never loops'
grep -q 'PENDING' "$TMP/unprovisioned.out" || fail 'an unprovisioned device must report PENDING'
BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --systemd >/dev/null 2>&1 || fail 'a boot attempt without central configuration must exit 0'
printf '%s\n' 'staged-secret-token' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin --stage >/dev/null || fail '--stage must store the token'
[[ "$(stat -c '%a' "$STATE_DIR/enrollment.token")" == '600' ]] || fail 'the staged token must be mode 600'
MOCK_CURL_FAIL=1 MOCK_CURL_RC=7 BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --systemd > "$TMP/offline-attempt.out" 2>&1 && fail 'an unreachable endpoint must fail the attempt so the bounded retry can run'
[[ -e "$STATE_DIR/enrollment.token" ]] || fail 'a transient failure must keep the staged token for the bounded retry'
[[ "$(state_field phase)" == 'PROVISIONED_OFFLINE' ]] || fail 'a failed attempt must keep the lifecycle at PROVISIONED_OFFLINE'
[[ ! -e "$WG_DIR/wg0.conf" ]] || fail 'a failed attempt must not leave a WireGuard config behind'
unset MOCK_CURL_FAIL MOCK_CURL_RC
MOCK_CURL_FAIL=1 MOCK_CURL_RC=22 MOCK_HTTP_CODE=403 BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --systemd >/dev/null 2>&1 && fail 'a definitive rejection must fail the attempt'
[[ ! -e "$STATE_DIR/enrollment.token" ]] || fail 'a definitive rejection must discard the consumed token'
unset MOCK_CURL_FAIL MOCK_CURL_RC MOCK_HTTP_CODE
printf '%s\n' 'staged-secret-token-two' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin --stage >/dev/null
touch -d '2 hours ago' "$STATE_DIR/enrollment.token"
BF_ENROLLMENT_TOKEN_MAX_AGE=1800 BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --systemd >/dev/null || fail 'an expired staged token must exit 0 as PENDING'
[[ ! -e "$STATE_DIR/enrollment.token" ]] || fail 'an expired staged token must be discarded'
printf '%s\n' 'staged-secret-token-three' | BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll-now" --stage >/dev/null || fail 'the technician wrapper must stage a token'
[[ -e "$STATE_DIR/enrollment.token" ]] || fail 'bf-enroll-now --stage must leave the token staged'
BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --systemd >/dev/null || fail 'the boot attempt must enroll when a valid token is staged and central is reachable'
[[ "$(state_field phase)" == 'ENROLLED' ]] || fail 'the boot attempt must commit ENROLLED'
[[ ! -e "$STATE_DIR/enrollment.token" ]] || fail 'the staged token must be deleted after use'
! grep -R -F 'staged-secret-token-three' "$TMP" --exclude=header --exclude=request --exclude=enrollment.token || fail 'the staged token must not leak into state, logs or argv'
pass 'the boot attempt stays PENDING without a token and joins automatically with one'

# --- scenario 11: --check dry run -------------------------------------------
write_state "$pending_state"
rm -f "$WG_DIR/wg0.conf" "$STATE_DIR/enrollment.token"
BEFORE="$(cat "$BF_STATE_FILE")"
BF_ENROLLMENT_ENDPOINT="$ENDPOINT" "$BIN/bf-enroll" --token-stdin --check > "$TMP/check.out" 2>&1 || fail '--check must succeed on a valid pre-enrollment device'
grep -q 'would enroll' "$TMP/check.out" || fail '--check must describe the planned transition'
[[ "$BEFORE" == "$(cat "$BF_STATE_FILE")" ]] || fail '--check must not touch the state file'
[[ ! -e "$WG_DIR/wg0.conf" ]] || fail '--check must not write a WireGuard config'
[[ ! -e "$STATE_DIR/enrollment.token" ]] || fail '--check must not stage a token'
"$BIN/bf-enroll" --token-stdin --check >/dev/null 2>&1 && fail '--check must fail without an endpoint'
if BF_ENROLLMENT_ENDPOINT='https://example.invalid/enroll' "$BIN/bf-enroll" --token-stdin --check >/dev/null 2>&1; then fail '--check must reject placeholder endpoints'; fi
pass '--check validates without mutating or sending anything'

# --- scenario 12: schemas match the client behaviour ------------------------
python3 - "$REPO_ROOT" "$MOCK_REQUEST_CAPTURE" "$MOCK_RESPONSE" <<'PY'
import json, sys
root, request_capture, response_sample = sys.argv[1:4]
request_schema = json.load(open(root + '/provisioning/enrollment/schemas/enrollment-request.schema.json', encoding='utf-8'))
response_schema = json.load(open(root + '/provisioning/enrollment/schemas/enrollment-response.schema.json', encoding='utf-8'))
request = json.load(open(request_capture, encoding='utf-8'))
response = json.loads(response_sample)
if set(request_schema['properties']) != set(request_schema['required']):
    raise SystemExit('request schema must close every property it requires')
if set(request) != set(request_schema['required']):
    raise SystemExit('captured request does not match the request schema')
for section, keys in (('hardware', ('machine_id', 'product_uuid', 'sys_vendor')), ('release', ('os_release', 'kernel'))):
    if set(request_schema['properties'][section]['required']) != set(keys):
        raise SystemExit('%s schema fields drifted' % section)
    if set(request[section]) != set(keys):
        raise SystemExit('captured %s does not match the schema' % section)
required_response = set(response_schema['required'])
if set(response) - set(response_schema['properties']):
    raise SystemExit('canned response carries fields the schema forbids')
if not required_response <= set(response):
    raise SystemExit('canned response is missing required fields')
if set(response['wireguard']) != set(response_schema['properties']['wireguard']['required']):
    raise SystemExit('WireGuard response fields drifted')
if set(response['central_verification']) != set(response_schema['properties']['central_verification']['required']):
    raise SystemExit('central verification fields drifted')
blob = json.dumps(response_schema).lower()
for banned in ('private_key', 'privkey', 'password', 'bearer'):
    if banned in blob:
        raise SystemExit('response schema must not define a secret field: ' + banned)
PY
! grep -q 'BF-12345678' "$REPO_ROOT/provisioning/enrollment/README.md" || fail 'provisioning docs must not embed a device identity'
pass 'enrollment schemas match the implemented request and response contract'

# --- scenario 13: boot unit cannot loop and carries no credential -----------
UNIT="$REPO_ROOT/config/systemd/blueforce-enroll.service"
TIMER="$REPO_ROOT/config/systemd/blueforce-enroll.timer"
grep -q '^Restart=on-failure$' "$UNIT" || fail 'the boot unit must retry only failures'
grep -q '^Restart=always' "$UNIT" && fail 'the boot unit must never restart unconditionally'
grep -q '^RestartSec=' "$UNIT" || fail 'the boot unit must delay its bounded retries'
grep -q '^StartLimitBurst=' "$UNIT" || fail 'the boot unit must bound its retries'
grep -q '^StartLimitIntervalSec=' "$UNIT" || fail 'the boot unit must bound its retry window'
grep -q 'ExecStart=/usr/local/bin/bf-enroll --systemd' "$UNIT" || fail 'the boot unit must run the controlled attempt'
grep -q 'Unit=blueforce-enroll.service' "$TIMER" || fail 'the timer must trigger the enrollment attempt'
grep -q 'OnBootSec=' "$TIMER" || fail 'the timer must attempt shortly after boot'
! grep -Eqi '(token|password|secret|bearer)[[:space:]]*=' "$UNIT" "$TIMER" || fail 'the units must not embed a credential'
exec_lines="$(grep -E '^Exec[A-Za-z]*=' "$UNIT" || true)"
[[ -n "$exec_lines" ]] || fail 'the boot unit must define its attempt command'
! printf '%s\n' "$exec_lines" | grep -Eqi 'reboot|shutdown' || fail 'the boot unit must never reboot or shut down the device'
grep -q 'never reboots' "$UNIT" || fail 'the boot unit must document that it never reboots the device'
pass 'the enrollment units retry in a bounded way and carry no credential'

printf 'test-field-os-lifecycle: all scenarios passed\n'
