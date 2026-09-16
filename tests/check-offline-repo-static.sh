#!/usr/bin/env bash
# Validate the offline APT repository contract without building a bundle:
# manifest pin semantics, SBOM schema shape, secret hygiene, and the coverage
# guarantees of build-offline-repo.sh --dry-run-plan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OFFLINE_REPO="$REPO_ROOT/provisioning/offline-repo"
MANIFEST_DIR="$OFFLINE_REPO/manifests"
BUILD="$OFFLINE_REPO/build-offline-repo.sh"
INSTALLER="$REPO_ROOT/scripts/install/blueforce-install.sh"
REQUIREMENTS="$MANIFEST_DIR/requirements.tsv"
LOCK_SCHEMA="$MANIFEST_DIR/packages.lock.schema.tsv"
MANIFESTS=(base-packages.txt remote-access.txt docker.txt)
LOCK_HEADER="$(printf 'package\tversion\tarchitecture\tsha256\tsource')"
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
pass() { printf 'OK: %s\n' "$*"; }
require_file() { [[ -f "$1" ]] && pass "present: ${1#$REPO_ROOT/}" || fail "missing: ${1#$REPO_ROOT/}"; }

require_file "$BUILD"
require_file "$OFFLINE_REPO/README.md"
require_file "$REQUIREMENTS"
require_file "$LOCK_SCHEMA"
for manifest in "${MANIFESTS[@]}"; do require_file "$MANIFEST_DIR/$manifest"; done

# 1. The build script is strict-mode Bash and parses.
[[ "$(head -n 1 "$BUILD")" == '#!/usr/bin/env bash' ]] || fail 'build-offline-repo.sh requires a Bash shebang'
grep -q '^set -euo pipefail$' "$BUILD" || fail 'build-offline-repo.sh requires strict mode'
bash -n "$BUILD" && pass 'build-offline-repo.sh parses' || fail 'build-offline-repo.sh parse error'
grep -q -- '--dry-run-plan' "$BUILD" || fail 'build-offline-repo.sh must offer --dry-run-plan'
grep -q -- '--check' "$BUILD" || fail 'build-offline-repo.sh must keep --check'
grep -q 'apt-ftparchive' "$BUILD" || fail 'the real build must still use apt-ftparchive'
grep -q 'pin still awaits its LAB version' "$BUILD" || fail 'the build must refuse an UNPINNED pin'

# 2. The plan path must not need the build tooling, which lives only on the LAB host.
plan_body="$(awk '/^plan_report\(\) \{/,/^\}/' "$BUILD")"
[[ -n "$plan_body" ]] || fail 'plan_report function not found in build-offline-repo.sh'
if grep -qE 'dpkg-deb[[:space:]]+-' <<<"$plan_body"; then fail 'dry-run-plan must not invoke dpkg-deb'; else pass 'dry-run-plan never invokes dpkg-deb'; fi
if grep -qE 'apt-ftparchive[[:space:]]+(packages|release)' <<<"$plan_body"; then fail 'dry-run-plan must not invoke apt-ftparchive'; else pass 'dry-run-plan never invokes apt-ftparchive'; fi
plan_dispatch="$(grep -n 'PLAN_ONLY" -eq 1' "$BUILD" | head -n 1 | cut -d: -f1)"
tool_guard="$(grep -n "apt-ftparchive is not installed" "$BUILD" | head -n 1 | cut -d: -f1)"
[[ -n "$plan_dispatch" && -n "$tool_guard" && "$plan_dispatch" -lt "$tool_guard" ]] \
  && pass 'plan mode is dispatched before the build tool requirements' \
  || fail 'plan mode must be dispatched before the build tool requirements'

# 3. The contract tooling acquires nothing: it is a local-file-only builder.
if grep -nE '(^|[^A-Za-z])(curl|wget)[[:space:]]+(-|http)|apt(-get)?[[:space:]]+download|https?://' "$BUILD"; then
  fail 'build-offline-repo.sh must not download anything'
else
  pass 'build-offline-repo.sh has no download primitive'
fi

# 4. manifests/*.txt is the offline installer contract: exactly three pin files.
mapfile -t manifest_txt < <(find "$MANIFEST_DIR" -maxdepth 1 -type f -name '*.txt' -printf '%f\n' | sort)
[[ ${#manifest_txt[@]} -eq 3 ]] || fail "manifests/ must hold exactly 3 *.txt pin files, found ${#manifest_txt[@]}"
for manifest in "${MANIFESTS[@]}"; do
  found=0
  for actual in "${manifest_txt[@]}"; do [[ "$actual" == "$manifest" ]] && found=1; done
  [[ "$found" -eq 1 ]] || fail "manifests/$manifest is missing from the installer contract"
done
[[ -z "$(grep -L 'package=version' "$MANIFEST_DIR"/*.txt || true)" ]] && pass 'every manifest documents the package=version pin format' || fail 'a manifest does not document the package=version pin format'
[[ -z "$(grep -L 'Ubuntu 26.04' "$MANIFEST_DIR"/*.txt || true)" ]] && pass 'every manifest names its target Ubuntu release' || fail 'a manifest does not name its target Ubuntu release'
[[ -z "$(grep -L 'UNPINNED' "$MANIFEST_DIR"/*.txt || true)" ]] && pass 'every manifest explains the UNPINNED sentinel' || fail 'a manifest does not explain the UNPINNED sentinel'

# 5. Pin semantics, independently of the build script.
awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    if ($0 ~ /[[:space:]]/ || $0 !~ /^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$/) { printf "INVALID\t%s\t%d\t%s\n", FILENAME, FNR, $0; next }
    split($0, kv, "=")
    pkg = kv[1]; ver = substr($0, length(pkg) + 2)
    if (seen[pkg] != "") printf "DUPLICATE\t%s\t%s\n", pkg, seen[pkg]
    else seen[pkg] = FILENAME ":" FNR
    pins++
    if (ver == "UNPINNED") awaiting++
    else filled++
  }
  END { printf "COUNT\t%d\t%d\t%d\n", pins, filled, awaiting }
' "$MANIFEST_DIR/base-packages.txt" "$MANIFEST_DIR/remote-access.txt" "$MANIFEST_DIR/docker.txt" > "$TMP/pins.txt"

invalid="$(grep -c '^INVALID' "$TMP/pins.txt" || true)"
duplicates="$(grep -c '^DUPLICATE' "$TMP/pins.txt" || true)"
read -r _ pin_count filled_count awaiting_count < <(grep '^COUNT' "$TMP/pins.txt" || printf 'COUNT 0 0 0\n')
[[ "$invalid" -eq 0 ]] && pass 'every manifest line is an exact package=version pin' || { fail "invalid pin lines: $invalid"; grep '^INVALID' "$TMP/pins.txt" >&2; }
[[ "$duplicates" -eq 0 ]] && pass 'no package is pinned twice' || { fail "duplicate pins: $duplicates"; grep '^DUPLICATE' "$TMP/pins.txt" >&2; }
[[ "$pin_count" -gt 0 ]] && pass "manifests declare $pin_count concrete pins" || fail 'manifests declare no pins'

# The audit table and the manifests must describe the same contract.
python_rc=0
python3 - "$MANIFEST_DIR" "$pin_count" <<'PY' || python_rc=$?
import os
import sys

manifest_dir, pin_count = sys.argv[1], int(sys.argv[2])
pins = {}
for name in ('base-packages.txt', 'remote-access.txt', 'docker.txt'):
    with open(os.path.join(manifest_dir, name), encoding='utf-8') as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            package, _, version = line.partition('=')
            pins.setdefault(package, []).append(name)
            assert version == 'UNPINNED' or version[0].isdigit() or ':' in version, line
rows = []
with open(os.path.join(manifest_dir, 'requirements.tsv'), encoding='utf-8') as handle:
    for lineno, raw in enumerate(handle, 1):
        line = raw.rstrip('\n')
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) != 4 or not all(fields):
            raise SystemExit(f'requirements.tsv:{lineno}: expected four TAB-separated fields')
        rows.append((fields[0], fields[1]))
missing = [f'{m}: {p}' for m, p in rows if p not in pins or m not in pins[p]]
rogue = sorted(f'{n}: {p}' for p, names in pins.items() for n in names if (n, p) not in rows)
if len(pins) != pin_count:
    raise SystemExit(f'pin parsing disagreement: script={pin_count} python={len(pins)}')
if missing or rogue:
    for item in missing:
        print(f'MISSING PACKAGE (in requirements.tsv, not in its manifest): {item}')
    for item in rogue:
        print(f'ROGUE PIN (in a manifest, not in requirements.tsv): {item}')
    raise SystemExit(1)
print(f'CHECK ok: {len(rows)} requirement rows, {len(pins)} pinned packages, coverage is complete')
PY
if [[ "$python_rc" -eq 0 ]]; then pass 'requirements.tsv and manifests/*.txt describe the same contract'; else fail 'requirements audit table drifted from the manifests'; fi

# 6. The SBOM schema keeps the exact header the offline installer validates.
schema_rows="$(grep -vcE '^[[:space:]]*(#|$)' "$LOCK_SCHEMA" || true)"
[[ "$schema_rows" -eq 1 ]] || fail "packages.lock.schema.tsv must carry only the header row ($schema_rows uncommented lines)"
[[ "$(grep -vE '^[[:space:]]*(#|$)' "$LOCK_SCHEMA")" == "$LOCK_HEADER" ]] && pass 'lock schema header matches the documented layout' || fail 'lock schema header is wrong'
grep -q 'package	version	architecture	sha256	source' "$LOCK_SCHEMA" || fail 'lock schema header is not TAB-separated'
installer_header="$(grep -o 'package\\tversion\\tarchitecture\\tsha256\\tsource' "$INSTALLER" | head -n 1)"
[[ "${installer_header//\\t/$'\t'}" == "$LOCK_HEADER" ]] \
  && pass 'lock header matches the header blueforce-install.sh validates' \
  || fail 'lock header drifted from blueforce-install.sh'
grep -q 'blueforce-install.sh' "$LOCK_SCHEMA" && pass 'lock schema names its consumer' || fail 'lock schema must name its consumer'
for column in package version architecture sha256 source; do
  grep -q "\\b$column\\b" "$LOCK_SCHEMA" || fail "lock schema does not document the $column column"
done

# 7. No secrets, keys, or device identities in the offline repository assets.
if grep -RniE --exclude-dir=.git \
  '(BEGIN [A-Z ]*PRIVATE KEY|(password|passwd|token|api[_-]?key|secret)[[:space:]]*[:=]|AKIA[0-9A-Z]{16}|BF-[0-9]{8})' \
  "$OFFLINE_REPO"; then
  fail 'secret-like or device-specific value found in provisioning/offline-repo'
else
  pass 'no secret-like or device-specific value in provisioning/offline-repo'
fi
if grep -RniE --exclude-dir=.git 'https?://[^[:space:]]*:[^[:space:]]*@' "$OFFLINE_REPO"; then
  fail 'credential-bearing URL found in provisioning/offline-repo'
else
  pass 'no credential-bearing URL in provisioning/offline-repo'
fi

# 8. The plan is read-only and its verdict matches the fill state of the manifests.
manifest_state_before="$(find "$MANIFEST_DIR" -type f -exec sha256sum {} + | sort)"
plan_rc=0
plan_out="$(bash "$BUILD" --dry-run-plan 2>&1)" || plan_rc=$?
manifest_state_after="$(find "$MANIFEST_DIR" -type f -exec sha256sum {} + | sort)"
[[ "$manifest_state_before" == "$manifest_state_after" ]] && pass 'dry-run-plan leaves the manifests untouched' || fail 'dry-run-plan modified the manifests'
grep -q 'apt-ftparchive is not installed' <<<"$plan_out" && fail 'dry-run-plan must not require apt-ftparchive' || pass 'dry-run-plan runs without the LAB build tooling'
grep -q "^SUMMARY: pins=$pin_count filled=$filled_count awaiting=$awaiting_count missing_packages=0 errors=0$" <<<"$plan_out" \
  && pass "dry-run-plan summary matches the manifests (pins=$pin_count awaiting=$awaiting_count)" \
  || { fail 'dry-run-plan summary disagrees with the manifests'; grep '^SUMMARY:' <<<"$plan_out" >&2; }
if [[ "$awaiting_count" -gt 0 ]]; then
  [[ "$plan_rc" -eq 1 ]] && pass 'dry-run-plan reports NOT READY while pins are unfilled' || fail "expected exit 1 while $awaiting_count pins await a version, got $plan_rc"
  grep -q '^PLAN NOT READY' <<<"$plan_out" && pass 'dry-run-plan states PLAN NOT READY' || fail 'dry-run-plan must state PLAN NOT READY'
  grep -q '^MISSING VERSIONS' <<<"$plan_out" && pass 'dry-run-plan lists the missing versions' || fail 'dry-run-plan must list the missing versions'
  listed="$(grep -c '=UNPINNED$' <<<"$plan_out" || true)"
  [[ "$listed" -eq "$awaiting_count" ]] && pass "dry-run-plan lists all $awaiting_count unfilled pins" || fail "dry-run-plan listed $listed of $awaiting_count unfilled pins"
  printf 'INFO: %d pin(s) still await a LAB version; the repo ships no .deb and no bundle.\n' "$awaiting_count"
else
  [[ "$plan_rc" -eq 0 ]] && pass 'dry-run-plan reports READY when every pin is filled' || fail "expected exit 0 with all pins filled, got $plan_rc"
  grep -q '^PLAN READY' <<<"$plan_out" || fail 'dry-run-plan must state PLAN READY'
fi
plan_rc=0
bash "$BUILD" --dry-run-plan --check >/dev/null 2>&1 || plan_rc=$?
[[ "$plan_rc" -eq 2 ]] && pass 'dry-run-plan refuses to combine with --check' || fail "dry-run-plan --check must exit 2, got $plan_rc"

# 9. Fixtures: the validator must catch each contract violation it advertises.
new_fixture() {
  rm -rf "$TMP/m"
  mkdir -p "$TMP/m"
  for manifest in "${MANIFESTS[@]}"; do cp "$MANIFEST_DIR/$manifest" "$TMP/m/$manifest"; done
  cp "$REQUIREMENTS" "$TMP/m/requirements.tsv"
  cp "$LOCK_SCHEMA" "$TMP/m/packages.lock.schema.tsv"
}
# Synthetic fixture versions: obviously non-release values used only to exercise
# the ready path. They are never copied into the repository or into a bundle.
fill_fixture() {
  local manifest src dst line
  for manifest in "${MANIFESTS[@]}"; do
    src="$TMP/m/$manifest"
    dst="$TMP/m/$manifest.filled"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == *=UNPINNED ]]; then
        printf '%s\n' "${line%=UNPINNED}=9.9.9-lab-fixture"
      else
        printf '%s\n' "$line"
      fi
    done < "$src" > "$dst"
    mv "$dst" "$src"
  done
}
drop_fixture_line() {
  local file="$1" prefix="$2" tmp="$TMP/drop.tmp" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$prefix"* ]]; then continue; fi
    printf '%s\n' "$line"
  done < "$file" > "$tmp"
  mv "$tmp" "$file"
}
plan_fixture() {
  PLAN_RC=0
  PLAN_OUT="$(BF_MANIFEST_DIR="$TMP/m" bash "$BUILD" --dry-run-plan 2>&1)" || PLAN_RC=$?
}
expect_violation() {
  local label="$1" pattern="$2"
  if [[ "$PLAN_RC" -eq 0 ]]; then fail "$label: validator accepted an invalid contract"; return; fi
  if grep -qE "$pattern" <<<"$PLAN_OUT"; then pass "$label: rejected ($(grep -oE "$pattern" <<<"$PLAN_OUT" | head -n 1))"; else
    fail "$label: expected diagnostic /$pattern/ not reported"; printf '%s\n' "$PLAN_OUT" >&2
  fi
}

new_fixture; fill_fixture
plan_fixture
if [[ "$PLAN_RC" -eq 0 ]] && grep -q '^PLAN READY' <<<"$PLAN_OUT"; then
  pass 'fixture: a fully filled contract reports PLAN READY'
else
  fail "fixture: a fully filled contract must report PLAN READY (exit $PLAN_RC)"
  printf '%s\n' "$PLAN_OUT" >&2
fi

new_fixture; fill_fixture
printf 'curl=1.0-lab-fixture\n' >> "$TMP/m/base-packages.txt"
plan_fixture; expect_violation 'fixture: duplicate pin' 'duplicate pin for curl'

new_fixture; fill_fixture
printf 'openssh-server=1.0-lab-fixture inline note\n' >> "$TMP/m/base-packages.txt"
plan_fixture; expect_violation 'fixture: whitespace in a pin' 'whitespace in a pin'

new_fixture; fill_fixture
printf 'Curl=1.0-lab-fixture\n' >> "$TMP/m/base-packages.txt"
plan_fixture; expect_violation 'fixture: malformed pin' 'not an exact pin'

new_fixture; fill_fixture
printf 'wget=placeholder-1.0\n' >> "$TMP/m/base-packages.txt"
plan_fixture; expect_violation 'fixture: placeholder token' 'placeholder token left in pin'

new_fixture; fill_fixture
printf 'ncdu=1.0-lab-fixture\n' >> "$TMP/m/base-packages.txt"
plan_fixture; expect_violation 'fixture: rogue pin without an audit row' 'absent from requirements.tsv'

new_fixture; fill_fixture
drop_fixture_line "$TMP/m/remote-access.txt" 'rustdesk='
plan_fixture
expect_violation 'fixture: required package missing' 'MISSING PACKAGES'
grep -q 'rustdesk' <<<"$PLAN_OUT" || fail 'fixture: the missing package must be named in the report'

new_fixture; fill_fixture
printf 'ncdu=1.0-lab-fixture\n' > "$TMP/m/extra.txt"
plan_fixture; expect_violation 'fixture: unexpected manifests/*.txt' 'unexpected manifests'

new_fixture; fill_fixture
printf 'curl\t1.0-lab-fixture\tamd64\t%s\tcurl_1.0-lab-fixture_amd64.deb\n' "$(printf 'a%.0s' {1..64})" >> "$TMP/m/packages.lock.schema.tsv"
plan_fixture; expect_violation 'fixture: data row in the lock schema' 'must not contain data rows'

# 10. Real builds and --check stay fail-closed without a reviewed pool.
mkdir -p "$TMP/pool"
build_rc=0
build_out="$(bash "$BUILD" --packages "$TMP/pool" --output "$TMP/out" --check 2>&1)" || build_rc=$?
if [[ "$build_rc" -ne 0 ]]; then pass 'build --check fails closed without a reviewed pool'; else fail 'build --check must not pass without a reviewed pool'; fi
grep -qE 'apt-ftparchive is not installed|no local \.deb files supplied' <<<"$build_out" \
  && pass 'build --check reports why it refused' \
  || { fail 'build --check refusal message is unclear'; printf '%s\n' "$build_out" >&2; }
[[ ! -e "$TMP/out" ]] && pass 'a refused build creates no output directory' || fail 'a refused build must not create output'
build_rc=0
bash "$BUILD" --packages "$TMP/absent-pool" --output "$TMP/out" >/dev/null 2>&1 || build_rc=$?
[[ "$build_rc" -eq 2 ]] && pass 'a missing package directory is a usage error' || fail "missing package directory must exit 2, got $build_rc"

if [[ "$FAIL" -ne 0 ]]; then
  printf 'check-offline-repo-static: FAILED\n' >&2
  exit 1
fi
printf 'check-offline-repo-static: all passed\n'
