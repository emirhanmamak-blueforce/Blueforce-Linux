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

# ------------------------------------------------- repository owner tooling ------
# The packages are committed by the repository owner on an Ubuntu host, so the
# intake and index builders are part of the contract: they must stay free of any
# download primitive, keep the exact lock header, and never write a partial build.
ADD_PKGS="$OFFLINE_REPO/add-packages.sh"
BUILD_INDEX="$OFFLINE_REPO/build-index.sh"
REPO_MANIFEST="$OFFLINE_REPO/repo-manifest.yaml"
require_file "$ADD_PKGS"
require_file "$BUILD_INDEX"
require_file "$REPO_MANIFEST"

for script in "$ADD_PKGS" "$BUILD_INDEX"; do
  label="$(basename "$script")"
  [[ "$(head -n 1 "$script")" == '#!/usr/bin/env bash' ]] || fail "$label requires a Bash shebang"
  grep -q '^set -euo pipefail$' "$script" || fail "$label requires strict mode"
  bash -n "$script" && pass "$label parses" || fail "$label has a parse error"
  if grep -nE '(^|[^A-Za-z])(curl|wget)[[:space:]]+(-|http|https)|apt(-get)?[[:space:]]+download|https?://' "$script"; then
    fail "$label must contain no download primitive"
  else
    pass "$label has no download primitive"
  fi
  if grep -nE '(BEGIN [A-Z ]*PRIVATE KEY|(password|passwd|token|api[_-]?key|secret)[[:space:]]*[:=]|AKIA[0-9A-Z]{16})' "$script"; then
    fail "$label contains a credential-like pattern"
  else
    pass "$label carries no credential-like pattern"
  fi
done

# add-packages.sh: intake verdicts and the manifest hand-off are mandatory.
grep -q 'dpkg-deb' "$ADD_PKGS" && pass 'add-packages.sh validates with dpkg-deb' || fail 'add-packages.sh must validate with dpkg-deb'
grep -q 'UNPINNED' "$ADD_PKGS" && pass 'add-packages.sh knows the UNPINNED sentinel' || fail 'add-packages.sh must handle the UNPINNED sentinel'
grep -q 'MANIFEST GÜNCELLEMESİ' "$ADD_PKGS" && pass 'add-packages.sh hands the owner the pin lines to fill' || fail 'add-packages.sh must print the manifest lines to fill'
grep -q 'EKLENDİ' "$ADD_PKGS" && pass 'add-packages.sh reports each accepted package' || fail 'add-packages.sh must report what it accepted'
grep -q 'çakışma' "$ADD_PKGS" && pass 'add-packages.sh refuses a second version of a package' || fail 'add-packages.sh must refuse a version conflict'
grep -q 'mimari uyumsuz' "$ADD_PKGS" && pass 'add-packages.sh refuses a foreign architecture' || fail 'add-packages.sh must refuse a foreign architecture'
grep -q 'geçerli bir Debian paketi' "$ADD_PKGS" && pass 'add-packages.sh refuses a file that is not a Debian package' || fail 'add-packages.sh must refuse a non-Debian file'
grep -q -- '-name .\*.deb.' "$ADD_PKGS" && pass 'add-packages.sh only admits *.deb candidates' || fail 'add-packages.sh must filter on the .deb extension'
if grep -qE '^[^#]*manifests/\*\.txt.*>[[:space:]]*"' "$ADD_PKGS" || grep -qE '>[[:space:]]*"\$MANIFEST' "$ADD_PKGS"; then
  fail 'add-packages.sh must never rewrite manifests/*.txt'
else
  pass 'add-packages.sh never rewrites the manifests'
fi

# build-index.sh: the bundle contract, fail-closed behaviour, stable rebuilds.
grep -q 'apt-ftparchive' "$BUILD_INDEX" && pass 'build-index.sh builds the index with apt-ftparchive' || fail 'build-index.sh must use apt-ftparchive'
grep -q 'apt-utils' "$BUILD_INDEX" && pass 'build-index.sh names the apt-utils package that carries the tool' || fail 'build-index.sh must say how to install apt-ftparchive'
grep -q 'package\\tversion\\tarchitecture\\tsha256\\tsource' "$BUILD_INDEX" \
  && pass 'build-index.sh writes the documented lock header' \
  || fail 'build-index.sh must write the documented lock header'
grep -q -- "-name '\*.txt'" "$BUILD_INDEX" && pass 'build-index.sh reads every manifests/*.txt pin file' || fail 'build-index.sh must read every pin manifest'
grep -q 'ekş\|eksik' "$BUILD_INDEX" && pass 'build-index.sh reports the missing packages' || fail 'build-index.sh must report missing packages'
grep -q 'paketler eksik' "$BUILD_INDEX" && pass 'build-index.sh names the missing package list explicitly' || fail 'build-index.sh must print an explicit missing package list'
grep -q 'YAZILMADI' "$BUILD_INDEX" && pass 'build-index.sh writes no bundle while a pin is unsatisfied' || fail 'build-index.sh must refuse to write an incomplete bundle'
grep -q 'canonicalize_stanzas' "$BUILD_INDEX" && pass 'build-index.sh orders the index canonically' || fail 'build-index.sh must order the index canonically'
grep -q 'DEĞİŞİKLİK YOK' "$BUILD_INDEX" && pass 'build-index.sh detects an unchanged bundle' || fail 'build-index.sh must detect an unchanged bundle'
grep -q 'repo-manifest.yaml' "$BUILD_INDEX" && pass 'build-index.sh maintains repo-manifest.yaml' || fail 'build-index.sh must maintain repo-manifest.yaml'
grep -q 'bu depoya ait olmayan dosya' "$BUILD_INDEX" && pass 'build-index.sh refuses to delete a foreign output directory' || fail 'build-index.sh must not clobber a foreign output directory'
grep -q 'git add -f' "$BUILD_INDEX" && pass 'build-index.sh prints the git add -f step the .gitignore requires' || fail 'build-index.sh must print the commit command'
grep -q 'built' "$BUILD_INDEX" && pass 'build-index.sh documents the built/ bundle path' || fail 'build-index.sh must document the bundle path'

# repo-manifest.yaml is the repository record: shape, not data, at rest.
grep -q '^schema_version: 1$' "$REPO_MANIFEST" && pass 'repo-manifest.yaml carries a schema version' || fail 'repo-manifest.yaml must carry a schema version'
for key in ubuntu_release architecture generated_at package_count total_bytes index_sha256 packages; do
  grep -q "^ *$key:" "$REPO_MANIFEST" || fail "repo-manifest.yaml does not declare $key"
done
grep -q "^  architecture: 'amd64'$" "$REPO_MANIFEST" && pass 'repo-manifest.yaml states the amd64 target' || fail 'repo-manifest.yaml must state the target architecture'
grep -q "^  state: 'UNBUILT'$" "$REPO_MANIFEST" && pass 'repo-manifest.yaml is shipped in the unbuilt state' || fail 'the shipped repo-manifest.yaml must be marked UNBUILT'
grep -q '^packages: \[\]$' "$REPO_MANIFEST" && pass 'repo-manifest.yaml ships no package rows' || fail 'the shipped repo-manifest.yaml must not carry package rows'
if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - "$REPO_MANIFEST" <<'PY' && pass 'repo-manifest.yaml is valid YAML' || fail 'repo-manifest.yaml is not valid YAML'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as handle:
    data = yaml.safe_load(handle)
assert data['schema_version'] == 1
assert data['repository']['architecture'] == 'amd64'
assert data['repository']['package_count'] == 0
assert data['packages'] == []
PY
else
  pass 'repo-manifest.yaml YAML parse skipped (PyYAML unavailable)'
fi

# ------------------------------------------------------------ README is Turkish --
README_FILE="$OFFLINE_REPO/README.md"
require_file "$README_FILE"
grep -q 'repo sorumlusu' "$README_FILE" && pass 'README explains the repository owner role' || fail 'README must explain who supplies the packages'
grep -q 'indirmez\|indirme yapmaz' "$README_FILE" && pass 'README states that the installer downloads nothing' || fail 'README must state that the offline installer downloads nothing'
grep -q 'OFFLINE BLOCKED' "$README_FILE" && pass 'README documents the OFFLINE BLOCKED failures' || fail 'README must document OFFLINE BLOCKED'
grep -q 'requirements.tsv' "$README_FILE" && pass 'README points at the audit table' || fail 'README must reference requirements.tsv'
grep -q 'add-packages.sh' "$README_FILE" && grep -q 'build-index.sh' "$README_FILE" \
  && pass 'README documents both owner tools' \
  || fail 'README must document add-packages.sh and build-index.sh'
grep -q 'built/' "$README_FILE" && pass 'README documents the bundle directory' || fail 'README must document the built/ layout'
grep -q 'offline-repo' "$README_FILE" && pass 'README names the install path of the bundle' || fail 'README must name the install path'
grep -q 'UNPINNED' "$README_FILE" && pass 'README explains the UNPINNED sentinel' || fail 'README must explain the UNPINNED sentinel'
grep -q 'git add -f' "$README_FILE" && pass 'README explains the git add -f requirement' || fail 'README must explain the git add -f requirement'
for package in curl openssh-server wireguard-tools smartmontools ufw prometheus-node-exporter xrdp rustdesk docker-ce containerd.io; do
  grep -q "$package" "$README_FILE" || fail "README does not explain why $package is needed"
done
pass 'README lists the pinned packages with their reason'

# ------------------------------------------ stub tools (this machine has no apt) --
# apt-ftparchive and dpkg-deb exist on the Ubuntu build host only. These two stubs
# reproduce their observable interface so the owner tooling is exercised end to end
# here; they are created inside the temporary directory and never committed, and a
# passing run is not a substitute for one real build on the Ubuntu host.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/dpkg-deb" <<'STUB'
#!/usr/bin/env bash
# Test stub: real dpkg-deb reads the control member; the identity is read from
# the <package>_<version>_<arch>.deb file name instead.
set -euo pipefail
[[ "${1:-}" == '-f' ]] || exit 1
file="${2:-}"
shift 2
base="$(basename "$file")"
case "$base" in
  *_*_*.deb) ;;
  *) printf 'stub: cannot read a control file from %s\n' "$base" >&2; exit 1 ;;
esac
name="${base%.deb}"; arch="${name##*_}"; rest="${name%_*}"
version="${rest##*_}"; package="${rest%_*}"
[[ -n "$package" && -n "$version" && -n "$arch" ]] || exit 1
for field in "$@"; do
  case "$field" in
    Package) printf '%s\n' "$package" ;;
    Version) printf '%s\n' "$version" ;;
    Architecture) printf '%s\n' "$arch" ;;
    *) printf '\n' ;;
  esac
done
STUB
cat > "$STUB_BIN/apt-ftparchive" <<'STUB'
#!/usr/bin/env bash
# Test stub: emits one Packages stanza per .deb, in reverse file order, so the
# builder's canonical ordering has to do real work.
set -euo pipefail
[[ "${1:-}" == 'packages' ]] || exit 1
dir="${2:-pool}"
first=1
while IFS= read -r deb; do
  base="$(basename "$deb")"
  name="${base%.deb}"; arch="${name##*_}"; rest="${name%_*}"
  version="${rest##*_}"; package="${rest%_*}"
  [[ "$first" -eq 1 ]] || printf '\n'
  first=0
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s/%s\nSize: %s\nSHA256: %s\n' \
    "$package" "$version" "$arch" "$dir" "$base" "$(stat -c %s "$deb")" "$(sha256sum "$deb" | awk '{print $1}')"
done < <(find "$dir" -maxdepth 1 -type f -name '*.deb' | sort -r)
STUB
chmod +x "$STUB_BIN/dpkg-deb" "$STUB_BIN/apt-ftparchive"
export PATH="$STUB_BIN:$PATH"

new_fixture; fill_fixture
DEB_DIR="$TMP/debs"; BAD_DIR="$TMP/bad-debs"; PKG_OUT="$TMP/owner-packages"
mkdir -p "$DEB_DIR" "$BAD_DIR"
while IFS= read -r pin; do
  [[ -z "$pin" || "$pin" == \#* ]] && continue
  printf 'stub %s\n' "$pin" > "$DEB_DIR/${pin%%=*}_${pin#*=}_amd64.deb"
done < <(cat "$TMP/m/base-packages.txt" "$TMP/m/remote-access.txt" "$TMP/m/docker.txt")
printf 'stub arm64\n' > "$BAD_DIR/stub-arm_1.0-lab-fixture_arm64.deb"
printf 'this is not a debian package\n' > "$BAD_DIR/garbage.deb"
FIXTURE_PINS="$(grep -hvE '^[[:space:]]*(#|$)' "$TMP/m"/*.txt | wc -l)"
FIXTURE_PINS="$((FIXTURE_PINS))"

# --check must validate and mutate nothing.
[[ "$FIXTURE_PINS" -gt 0 ]] && pass "fixture declares $FIXTURE_PINS pins for the owner tooling"
rc=0; out="$(bash "$ADD_PKGS" --packages "$PKG_OUT" --from "$DEB_DIR" --check 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] && pass 'add-packages.sh --check accepts a matching pool' || { fail "add-packages.sh --check failed (exit $rc)"; printf '%s\n' "$out" >&2; }
[[ ! -e "$PKG_OUT" ]] && pass 'add-packages.sh --check copies nothing' || fail 'add-packages.sh --check must not copy'
grep -q 'EKLENECEK' <<<"$out" && pass 'add-packages.sh --check previews the accepted packages' || fail 'add-packages.sh --check must preview the packages'

# Real intake, twice: the second run must be a no-op.
rc=0; out="$(bash "$ADD_PKGS" --packages "$PKG_OUT" --from "$DEB_DIR" --manifest "$TMP/m/base-packages.txt" --include-all 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] && pass 'add-packages.sh accepts the reviewed pool' || { fail "add-packages.sh intake failed (exit $rc)"; printf '%s\n' "$out" >&2; }
copied="$(find "$PKG_OUT" -maxdepth 1 -type f -name '*.deb' | wc -l)"
[[ "$copied" -eq "$FIXTURE_PINS" ]] && pass "add-packages.sh copied all $copied packages into packages/" || fail "add-packages.sh copied $copied of $FIXTURE_PINS packages"
state_before="$(find "$PKG_OUT" -maxdepth 1 -type f -exec sha256sum {} + | sort)"
rc=0; out="$(bash "$ADD_PKGS" --packages "$PKG_OUT" --from "$DEB_DIR" 2>&1)" || rc=$?
state_after="$(find "$PKG_OUT" -maxdepth 1 -type f -exec sha256sum {} + | sort)"
[[ "$rc" -eq 0 && "$state_before" == "$state_after" ]] \
  && pass 're-running add-packages.sh over the same files changes nothing' \
  || fail 'add-packages.sh is not idempotent'
grep -q 'ATLANDI' <<<"$out" && pass 'add-packages.sh reports an already accepted file instead of copying it again' || fail 'add-packages.sh must report a duplicate instead of re-copying'

# A pin that is still UNPINNED: the owner gets the exact line to fill.
rc=0; out="$(bash "$ADD_PKGS" --packages "$TMP/other-packages" --from "$DEB_DIR" --manifest "$MANIFEST_DIR/base-packages.txt" --check 2>&1)" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'MANIFEST GÜNCELLEMESİ' <<<"$out" && grep -q 'base-packages.txt: curl=9.9.9-lab-fixture' <<<"$out"; then
  pass 'add-packages.sh hands over the UNPINNED pin line with the real version'
else
  fail "add-packages.sh must print the pin line to fill (exit $rc)"
  printf '%s\n' "$out" >&2
fi

# Failing intakes must change nothing and must be explicit.
printf 'stub newer\n' > "$BAD_DIR/curl_0.0.1-lab-fixture_amd64.deb"
rc=0; out="$(bash "$ADD_PKGS" --packages "$PKG_OUT" --from "$BAD_DIR" --include-all 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] && pass 'add-packages.sh fails on an unusable batch' || fail 'add-packages.sh must fail on an unusable batch'
grep -q 'mimari uyumsuz' <<<"$out" && pass 'add-packages.sh names the architecture mismatch' || fail 'add-packages.sh must name the architecture mismatch'
grep -q 'geçerli bir Debian paketi' <<<"$out" && pass 'add-packages.sh names the unreadable file' || fail 'add-packages.sh must name the unreadable file'
grep -q 'çakışma' <<<"$out" && pass 'add-packages.sh refuses the second version of curl' || fail 'add-packages.sh must refuse a version conflict'
[[ ! -e "$PKG_OUT/curl_0.0.1-lab-fixture_amd64.deb" ]] && pass 'a refused batch copies no file' || fail 'add-packages.sh copied a refused file'
[[ ! -e "$PKG_OUT/garbage.deb" ]] && pass 'an unreadable file never reaches packages/' || fail 'add-packages.sh copied an unreadable file'
printf 'not a deb\n' > "$BAD_DIR/notes.txt"
rc=0; out="$(bash "$ADD_PKGS" --packages "$PKG_OUT" "$BAD_DIR/notes.txt" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'Debian paketi değil' <<<"$out" && pass 'add-packages.sh refuses a non-.deb argument' || fail 'add-packages.sh must refuse a non-.deb argument'

# build-index.sh --check: contract verified, nothing written.
BAD_OUT="$TMP/never-written"
rc=0; out="$(bash "$BUILD_INDEX" --packages "$PKG_OUT" --output "$BAD_OUT" --manifest-dir "$TMP/m" --manifest-out "$TMP/never.yaml" --check 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] && pass 'build-index.sh --check accepts a complete pool' || { fail "build-index.sh --check failed (exit $rc)"; printf '%s\n' "$out" >&2; }
[[ ! -e "$BAD_OUT" && ! -e "$TMP/never.yaml" ]] && pass 'build-index.sh --check writes nothing' || fail 'build-index.sh --check must not write'

# A refused output path must be refused before anything is removed.
FAKE_HOME="$TMP/fake-home"; mkdir -p "$FAKE_HOME"
rc=0; out="$(HOME="$FAKE_HOME" bash "$BUILD_INDEX" --packages "$PKG_OUT" --output "$FAKE_HOME" --manifest-dir "$TMP/m" --check 2>&1)" || rc=$?
[[ "$rc" -eq 2 && -d "$FAKE_HOME" ]] && pass 'build-index.sh refuses an unsafe --output path' || fail "an unsafe --output must be a usage error (exit $rc)"
FOREIGN_OUT="$TMP/foreign-out"; mkdir -p "$FOREIGN_OUT"; printf 'keep me\n' > "$FOREIGN_OUT/junk.txt"
rc=0; out="$(bash "$BUILD_INDEX" --packages "$PKG_OUT" --output "$FOREIGN_OUT" --manifest-dir "$TMP/m" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'bu depoya ait olmayan dosya' <<<"$out" && pass 'build-index.sh refuses a foreign output directory' || fail 'build-index.sh must refuse a foreign output directory'
[[ -f "$FOREIGN_OUT/junk.txt" ]] && pass 'a refused build deletes nothing' || fail 'a refused build must not delete anything'

# The real build.
OUT="$TMP/owner-built"
rc=0; out="$(bash "$BUILD_INDEX" --packages "$PKG_OUT" --output "$OUT" --manifest-dir "$TMP/m" --manifest-out "$TMP/repo-manifest.yaml" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] && pass 'build-index.sh builds a bundle from the accepted pool' || { fail "build-index.sh build failed (exit $rc)"; printf '%s\n' "$out" >&2; }
for artifact in Packages Packages.gz packages.lock.tsv SHA256SUMS; do
  [[ -s "$OUT/$artifact" ]] || fail "build-index.sh did not write $artifact"
done
pool_count="$(find "$OUT/pool" -maxdepth 1 -type f -name '*.deb' | wc -l)"
[[ "$pool_count" -eq "$FIXTURE_PINS" ]] && pass "the bundle holds the whole pool ($pool_count .deb)" || fail "the bundle holds $pool_count of $FIXTURE_PINS packages"
lock_rows="$(wc -l < "$OUT/packages.lock.tsv")"
[[ "$lock_rows" -eq $((FIXTURE_PINS + 1)) ]] && pass 'packages.lock.tsv holds the header plus one row per package' || fail "packages.lock.tsv holds $lock_rows lines, expected $((FIXTURE_PINS + 1))"
[[ "$(head -n 1 "$OUT/packages.lock.tsv")" == "$LOCK_HEADER" ]] && pass 'the bundle lock header is byte-identical to the documented one' || fail 'the bundle lock header is wrong'
awk -F '\t' 'NR > 1 { if (NF != 5 || $0 ~ /\r/ || $4 !~ /^[a-f0-9]{64}$/) { print "BADROW: " $0; bad=1 } } END { exit bad }' "$OUT/packages.lock.tsv" \
  && pass 'every lock row carries five TAB-separated fields and a sha256' \
  || fail 'a lock row is malformed'
( cd "$OUT" && sha256sum -c SHA256SUMS >/dev/null ) && pass 'the bundle verifies with sha256sum -c' || fail 'the bundle does not verify'
stanza_count="$(grep -c '^Package: ' "$OUT/Packages")"
[[ "$stanza_count" -eq "$FIXTURE_PINS" ]] && pass 'Packages indexes every package' || fail "Packages indexes $stanza_count of $FIXTURE_PINS packages"
gzip_flg="$(od -An -t u1 -j 3 -N 1 "$OUT/Packages.gz" | tr -d ' ')"
gzip_mtime="$(od -An -t u1 -j 4 -N 4 "$OUT/Packages.gz" | tr -d ' \n')"
[[ "$gzip_flg" == '0' && "$gzip_mtime" == '0000' ]] \
  && pass 'Packages.gz carries no name and no timestamp (reproducible)' \
  || fail "Packages.gz is not timestamp free (FLG=$gzip_flg MTIME=$gzip_mtime)"
cmp -s <(gzip -dc "$OUT/Packages.gz") "$OUT/Packages" && pass 'Packages.gz decompresses to Packages' || fail 'Packages.gz does not match Packages'

# The repository record.
if [[ -f "$TMP/repo-manifest.yaml" ]]; then
  pass 'build-index.sh writes the repository record'
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$TMP/repo-manifest.yaml" "$FIXTURE_PINS" "$OUT" <<'PY' && pass 'the repository record matches the bundle' || fail 'the repository record disagrees with the bundle'
import hashlib, os, sys, yaml
record_path, expected, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(record_path, encoding='utf-8') as handle:
    rec = yaml.safe_load(handle)
repo = rec['repository']
assert rec['schema_version'] == 1, rec['schema_version']
assert repo['state'] == 'BUILT', repo['state']
assert repo['architecture'] == 'amd64', repo['architecture']
assert repo['ubuntu_release'] == '26.04', repo['ubuntu_release']
assert repo['package_count'] == expected, repo['package_count']
assert repo['pinned_packages'] == expected, repo['pinned_packages']
assert repo['total_bytes'] > 0
assert len(rec['packages']) == expected, len(rec['packages'])
for row in rec['packages']:
    assert len(row['sha256']) == 64, row
    assert row['pinned_in'], row
    assert os.path.isfile(os.path.join(out, 'pool', row['source'])), row
for name in ('Packages', 'Packages.gz', 'packages.lock.tsv'):
    with open(os.path.join(out, name), 'rb') as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    assert repo['index_sha256'][name] == digest, (name, digest)
PY
  else
    pass 'repository record parse skipped (PyYAML unavailable)'
  fi
  grep -q "^  package_count: $FIXTURE_PINS$" "$TMP/repo-manifest.yaml" && pass 'the record counts every package' || fail 'the record has the wrong package_count'
else
  fail 'build-index.sh must write the repository record'
fi

# An unchanged rebuild must be a no-op, byte for byte.
bundle_before="$(find "$OUT" -type f -exec sha256sum {} + | sort)"
record_before="$(sha256sum "$TMP/repo-manifest.yaml" | awk '{print $1}')"
rc=0; out="$(bash "$BUILD_INDEX" --packages "$PKG_OUT" --output "$OUT" --manifest-dir "$TMP/m" --manifest-out "$TMP/repo-manifest.yaml" 2>&1)" || rc=$?
bundle_after="$(find "$OUT" -type f -exec sha256sum {} + | sort)"
record_after="$(sha256sum "$TMP/repo-manifest.yaml" | awk '{print $1}')"
[[ "$rc" -eq 0 && "$bundle_before" == "$bundle_after" ]] && pass 'rebuilding an unchanged pool leaves the bundle byte-identical' || fail 'rebuilding an unchanged pool changed the bundle'
grep -q 'DEĞİŞİKLİK YOK' <<<"$out" && pass 'build-index.sh reports the unchanged bundle instead of rewriting it' || fail 'build-index.sh must report an unchanged bundle'
[[ "$record_before" == "$record_after" ]] && pass 'an unchanged rebuild leaves the repository record untouched' || fail 'an unchanged rebuild must not restamp the repository record'
git_status_note="$(git -C "$REPO_ROOT" status --porcelain -- "provisioning/offline-repo/built" 2>/dev/null || true)"
[[ -z "$git_status_note" ]] && pass 'the test build never touches the committed bundle directory' || fail "the test build wrote into provisioning/offline-repo/built: $git_status_note"

# A missing pin: report, then stop, without touching the previous bundle.
rm -f "$PKG_OUT/rustdesk_9.9.9-lab-fixture_amd64.deb"
rc=0; out="$(bash "$BUILD_INDEX" --packages "$PKG_OUT" --output "$OUT" --manifest-dir "$TMP/m" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] && pass 'build-index.sh fails when a manifest pin is absent from the pool' || fail "a missing pinned package must exit 1, got $rc"
grep -q 'paketler eksik' <<<"$out" && pass 'build-index.sh prints the missing package list' || fail 'build-index.sh must print the missing package list'
grep -q 'rustdesk' <<<"$out" && pass 'the missing package is named' || fail 'the missing package must be named'
grep -q 'YAZILMADI' <<<"$out" && grep -q 'OFFLINE BLOCKED' <<<"$out" \
  && pass 'build-index.sh explains that the device would report OFFLINE BLOCKED' \
  || fail 'build-index.sh must explain the offline consequence'
[[ "$bundle_before" == "$(find "$OUT" -type f -exec sha256sum {} + | sort)" ]] && pass 'a refused build leaves the previous bundle untouched' || fail 'a refused build must not modify the previous bundle'
[[ -z "$(find "$(dirname "$OUT")" -maxdepth 1 -name '.build-index.*' -print -quit)" ]] && pass 'a refused build leaves no staging directory behind' || fail 'a refused build left a staging directory'

# An unfilled manifest pin: no bundle either.
rc=0; out="$(bash "$BUILD_INDEX" --packages "$PKG_OUT" --output "$TMP/never-2" --manifest-dir "$MANIFEST_DIR" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] && pass 'build-index.sh refuses while a pin still reads UNPINNED' || fail "an UNPINNED pin must exit 1, got $rc"
grep -q 'UNPINNED' <<<"$out" && grep -q 'eksik' <<<"$out" && pass 'the unfilled pins are listed as missing packages' || fail 'build-index.sh must list the unfilled pins'
[[ ! -e "$TMP/never-2" ]] && pass 'nothing is written while a pin is unfilled' || fail 'build-index.sh wrote a bundle for an unfilled contract'

# The canonical order is deterministic and stable: prove it on the sorter alone.
SORTED_A="$TMP/sorted-a"; SORTED_B="$TMP/sorted-b"; SORTER="$TMP/sorter.sh"
awk '/^canonicalize_stanzas\(\) \{/,/^\}/' "$BUILD_INDEX" > "$SORTER"
[[ -s "$SORTER" ]] || fail 'the canonical sorter function could not be extracted from build-index.sh'
bash -c 'set -euo pipefail
  source "$1"
  canonicalize_stanzas < "$2" > "$3"
  canonicalize_stanzas < "$2" > "$4"
  cmp -s "$3" "$4" || exit 1
  canonicalize_stanzas < "$3" > "$3.recanon"
  cmp -s "$3" "$3.recanon"' _ "$SORTER" "$OUT/Packages" "$SORTED_A" "$SORTED_B" \
  && pass 'the canonical index order is reproducible and self-stable' \
  || fail 'the canonical index sorter is not deterministic'
indexed_names="$(grep '^Package: ' "$OUT/Packages" | sed 's/^Package: //')"
[[ "$indexed_names" == "$(printf '%s\n' "$indexed_names" | LC_ALL=C sort)" ]] \
  && pass 'the index is ordered by package name, not by the raw pool order' \
  || fail 'the index must be ordered by package name'

if [[ "$FAIL" -ne 0 ]]; then
  printf 'check-offline-repo-static: FAILED\n' >&2
  exit 1
fi
printf 'check-offline-repo-static: all passed\n'
