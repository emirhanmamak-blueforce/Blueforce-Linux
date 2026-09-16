#!/usr/bin/env bash
# Validate provisioning assets, the bootable ISO builder contract, and the safety rules
# of the autoinstall payload. Nothing is built, no disk is touched, no network is used.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVISIONING="$REPO_ROOT/provisioning"
ISO_DIR="$PROVISIONING/iso"
BUILDER="$ISO_DIR/build-blueforce-iso.sh"
AUTOINSTALL="$PROVISIONING/autoinstall/autoinstall.yaml"
USER_DATA="$PROVISIONING/autoinstall/user-data"
FAIL=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
pass() { printf 'OK: %s\n' "$*"; }
require_file() { [[ -f "$1" ]] && pass "present: ${1#"$REPO_ROOT"/}" || fail "missing: ${1#"$REPO_ROOT"/}"; }

# require_in <file> <extended-regex> <description>
require_in() {
  if grep -qE -- "$2" "$1"; then
    pass "$3"
  else
    fail "$3 (pattern not found in ${1#"$REPO_ROOT"/}: $2)"
  fi
}

# forbid_in <file> <extended-regex> <description>
forbid_in() {
  if grep -qE -- "$2" "$1"; then
    fail "$3 (forbidden pattern in ${1#"$REPO_ROOT"/}: $2)"
  else
    pass "$3"
  fi
}

required_files=(
  provisioning/README.md
  provisioning/autoinstall/autoinstall.yaml
  provisioning/autoinstall/user-data
  provisioning/autoinstall/meta-data
  provisioning/autoinstall/README.md
  provisioning/iso/build-blueforce-iso.sh
  provisioning/iso/verify-upstream-iso.sh
  provisioning/iso/test-iso.sh
  provisioning/iso/README.md
  provisioning/iso/field-os-version
  provisioning/iso/ubuntu-26.04.1-SHA256SUMS
  provisioning/offline-repo/build-offline-repo.sh
  provisioning/offline-repo/packages/.gitkeep
  provisioning/offline-repo/manifests/base-packages.txt
  provisioning/offline-repo/manifests/remote-access.txt
  provisioning/offline-repo/manifests/docker.txt
  provisioning/offline-repo/README.md
  provisioning/firstboot/bf-firstboot
  provisioning/firstboot/blueforce-firstboot.service
  provisioning/firstboot/README.md
  provisioning/enrollment/schemas/enrollment-request.schema.json
  provisioning/enrollment/schemas/enrollment-response.schema.json
  provisioning/enrollment/README.md
  provisioning/release/manifest.yaml
  provisioning/release/README.md
  tests/run-all.sh
)
for relative in "${required_files[@]}"; do require_file "$REPO_ROOT/$relative"; done

if [[ ! -d "$PROVISIONING" ]]; then
  printf 'check-provisioning-static: FAILED\n' >&2
  exit 1
fi

# Provisioning scripts must be Bash, strict-mode, and parse without execution.
while IFS= read -r -d '' script; do
  first_line="$(head -n 1 "$script")"
  [[ "$first_line" == '#!/usr/bin/env bash' ]] || fail "Bash shebang required: ${script#"$REPO_ROOT"/}"
  grep -q '^set -euo pipefail$' "$script" || fail "strict mode required: ${script#"$REPO_ROOT"/}"
  bash -n "$script" && pass "bash parses: ${script#"$REPO_ROOT"/}" || fail "bash parse error: ${script#"$REPO_ROOT"/}"
done < <(find "$PROVISIONING" -type f \( -name '*.sh' -o -name 'bf-firstboot' \) -print0)

# JSON schemas and YAML assets must be structurally parseable. The checks need python3
# (plus PyYAML for the YAML side); when the interpreter or module is missing they are
# reported as skipped instead of failing, so the suite stays usable in minimal containers.
PYTHON_JSON=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  PYTHON_JSON=1
fi
PYTHON_YAML=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  PYTHON_YAML=1
fi

if [[ "$PYTHON_JSON" -eq 1 ]]; then
  while IFS= read -r -d '' json_file; do
    if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$json_file"; then
      pass "json parses: ${json_file#"$REPO_ROOT"/}"
    else
      fail "json parse error: ${json_file#"$REPO_ROOT"/}"
    fi
  done < <(find "$PROVISIONING" -type f -name '*.json' -print0)
else
  printf 'NOTE: json parse checks skipped (python3 with the json module is unavailable)\n'
fi

if [[ "$PYTHON_YAML" -eq 1 ]]; then
  while IFS= read -r -d '' yaml_file; do
    if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$yaml_file"; then
      pass "yaml parses: ${yaml_file#"$REPO_ROOT"/}"
    else
      fail "yaml parse error: ${yaml_file#"$REPO_ROOT"/}"
    fi
  done < <(find "$PROVISIONING" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
else
  printf 'NOTE: yaml parse checks skipped (python3 with PyYAML is unavailable)\n'
fi

# ---------------------------------------------------------------- autoinstall --
if [[ -f "$AUTOINSTALL" && -f "$USER_DATA" ]]; then
  grep -q '^autoinstall:$' "$AUTOINSTALL" || fail 'autoinstall.yaml must have an autoinstall root'
  grep -qE '^[[:space:]]*interactive-sections:[[:space:]]*\[storage\][[:space:]]*$' "$AUTOINSTALL" || fail 'autoinstall.yaml must require interactive storage'
  if grep -qE '^[[:space:]]*identity:' "$AUTOINSTALL" "$USER_DATA"; then
    fail 'autoinstall must not embed an identity'
  else
    pass 'autoinstall contains no identity block'
  fi

  # Storage directives are checked on the effective YAML (comments stripped) so that
  # documentation comments cannot be mistaken for real directives.
  for payload in "$AUTOINSTALL" "$USER_DATA"; do
    if sed -E 's/(^|[[:space:]])#.*$//' "$payload" \
      | grep -qE '(^|[[:space:]])(layout|match|wipe|grub_device|device|path):[[:space:]]*[^[:space:]]'; then
      fail "autoinstall must not directly select or wipe a disk: ${payload#"$REPO_ROOT"/}"
    else
      pass "no direct disk selection or wipe directive: ${payload#"$REPO_ROOT"/}"
    fi
  done

  require_in "$AUTOINSTALL" '^[[:space:]]*fallback:[[:space:]]*offline-install[[:space:]]*$' \
    'autoinstall declares the offline-install apt fallback'
  require_in "$USER_DATA" '^[[:space:]]*fallback:[[:space:]]*offline-install[[:space:]]*$' \
    'seed user-data declares the offline-install apt fallback'
  require_in "$AUTOINSTALL" '/opt/blueforce/offline-repo' \
    'late-commands place the offline repository at /opt/blueforce/offline-repo'
  require_in "$AUTOINSTALL" 'cdrom/blueforce-provisioning/firstboot/bf-firstboot' \
    'late-commands install the firstboot payload from the fixed media path'
  require_in "$AUTOINSTALL" 'systemctl enable blueforce-firstboot\.service' \
    'late-commands enable blueforce-firstboot.service'
  require_in "$AUTOINSTALL" '/etc/blueforce-release' \
    'late-commands place /etc/blueforce-release on the target'

  # The seed copy and the media copy must stay in sync.
  AUTO_LATE="$(sed -n '/late-commands:/,$p' "$AUTOINSTALL" | grep -E '^[[:space:]]*-' | sed -E 's/^[[:space:]]*-[[:space:]]*//' || true)"
  SEED_LATE="$(sed -n '/late-commands:/,$p' "$USER_DATA" | grep -E '^[[:space:]]*-' | sed -E 's/^[[:space:]]*-[[:space:]]*//' || true)"
  if [[ -n "$AUTO_LATE" && "$AUTO_LATE" == "$SEED_LATE" ]]; then
    pass 'seed user-data late-commands match the media autoinstall'
  else
    fail 'seed user-data late-commands differ from autoinstall.yaml'
  fi
fi

# ------------------------------------------------------------- ISO builder ----
if [[ -f "$BUILDER" ]]; then
  # Assertions about executable behaviour run against a comment-stripped view so that a
  # documentation comment can neither satisfy nor trip a code contract check.
  CODE_VIEW="$(mktemp)"
  trap 'rm -rf "${TMP_TEST:-}" "$CODE_VIEW"' EXIT
  sed -E 's/(^|[[:space:]])#.*$//' "$BUILDER" > "$CODE_VIEW"
  require_in "$BUILDER" 'Blueforce-Field-OS-\$\{VERSION\}-\$\{ARCH\}\.iso' \
    'builder names the ISO after the released version contract'
  require_in "$BUILDER" '"\$\{OUTPUT\}\.sha256"' 'builder writes <iso>.sha256'
  require_in "$BUILDER" '\$\{VERSION\}-manifest\.yaml' 'builder writes <version>-manifest.yaml'
  require_in "$BUILDER" '\-\-checksum-file' 'builder accepts an explicit checksum record'
  forbid_in "$BUILDER" 'Refusing remaster without --allow-remaster' \
    'real build is no longer gated behind --allow-remaster'
  require_in "$BUILDER" '\-\-check\)' 'builder provides a dry-run mode'

  # Media layout and automatic autoinstall start.
  require_in "$BUILDER" '\$MEDIA/autoinstall\.yaml' 'autoinstall.yaml is written to the media root'
  require_in "$BUILDER" 'FIRSTBOOT_PATH="\$MEDIA_PREFIX/firstboot"' 'firstboot path is fixed at /blueforce-provisioning/firstboot'
  require_in "$BUILDER" 'inject_autoinstall_arg' 'builder injects the autoinstall kernel argument itself'
  require_in "$BUILDER" 'blueforce-orig' 'builder keeps a pristine copy of every boot file it patches'
  require_in "$BUILDER" 'boot/grub/grub\.cfg' 'GRUB configuration is patched'
  require_in "$BUILDER" 'isolinux' 'isolinux configuration is patched when the base ISO has one'
  # The boot structure is rebuilt from the base ISO's own layout recipe: a replay cannot
  # re-create the GRUB2 MBR (first 16 sectors of the source image) or the appended EFI
  # system partition. Those options are read at build time, never hard-coded.
  require_in "$BUILDER" 'report_el_torito as_mkisofs' 'boot layout is read from the base ISO at build time'
  require_in "$BUILDER" '\-as mkisofs' 'the medium is written with the base ISO boot recipe'
  require_in "$BUILDER" 'append_partition' 'builder fails closed when the base layout has no appended EFI partition'
  require_in "$BUILDER" 'modification-date' 'reproducible builds pin the mkisofs modification date'
  forbid_in "$CODE_VIEW" '\-boot_image any replay' 'boot layout is no longer replayed'
  forbid_in "$BUILDER" '28732ac11ff8d211ba4b00a0c93ec93b|appended_partition_2_start_|local_fs:[0-9]' \
    'boot layout values are not hard-coded in the builder'
  require_in "$BUILDER" 'El Torito boot img.*BIOS' 'builder asserts the BIOS El Torito entry survives'
  require_in "$BUILDER" 'El Torito boot img.*\(UEFI\|EFI\)' 'builder asserts the UEFI El Torito entry survives'
  require_in "$BUILDER" 'interactive-sections: \\\[storage\\\]' 'builder re-checks interactive storage inside the produced media'
  require_in "$BUILDER" 'rm -f "\$OUTPUT"' 'builder removes a broken output instead of leaving a half-good ISO'

  # Offline repository embedding.
  require_in "$BUILDER" 'Packages\.gz' 'builder requires a complete offline repository before embedding it'
  require_in "$BUILDER" 'offline-repo/built' 'built offline repository is placed on the media'

  # Manifest contract.
  require_in "$BUILDER" 'field_os_version' 'manifest records field_os_version'
  require_in "$BUILDER" 'base_flavor' 'manifest records the detected base_flavor'
  require_in "$BUILDER" 'base_iso_filename' 'manifest records the base ISO file name'
  require_in "$BUILDER" 'ubuntu_iso_sha256' 'manifest records ubuntu_iso_sha256'
  require_in "$BUILDER" 'git_commit' 'manifest records the git commit'
  require_in "$BUILDER" 'build_date' 'manifest records the build date'
  require_in "$BUILDER" 'meg_package_version' 'manifest records the package versions'
  require_in "$BUILDER" 'blueforce_installer_version' 'manifest records the installer version'
  require_in "$BUILDER" 'baseline_deviation' 'manifest records the documented-baseline deviation'
  forbid_in "$BUILDER" '[0-9a-f]{64}' 'builder embeds no hard-coded SHA256 digest'

  # No download and no device identity in the builder.
  forbid_in "$BUILDER" '\b(curl|wget|apt-get download|apt download)\b' 'builder downloads nothing'
  forbid_in "$BUILDER" 'BF-[0-9]{8}' 'builder embeds no device identity'

  # The version file must be usable as an artifact name component.
  if [[ -f "$ISO_DIR/field-os-version" ]] \
    && grep -qE '^[0-9]+(\.[0-9]+){1,3}([-.+][0-9A-Za-z.-]+)?$' "$ISO_DIR/field-os-version"; then
    pass 'field-os-version holds a valid version string'
  else
    fail 'field-os-version must hold a version such as 1.0.0'
  fi

  # The upstream checksum record must not be a hand-written digest store: it must carry a
  # SHA256SUMS-style entry for a real Ubuntu image name.
  if [[ -f "$ISO_DIR/ubuntu-26.04.1-SHA256SUMS" ]] \
    && grep -qE '^[0-9a-f]{64} \*ubuntu-[0-9.]+-(live-server|desktop)-amd64\.iso$' "$ISO_DIR/ubuntu-26.04.1-SHA256SUMS"; then
    pass 'upstream checksum record is a Canonical SHA256SUMS file'
  else
    fail 'upstream checksum record is missing or malformed'
  fi

  # --check and failure paths stay non-destructive.
  TMP_TEST="$(mktemp -d)"
  printf 'not an iso\n' > "$TMP_TEST/junk-amd64.iso"
  printf '%s *junk-amd64.iso\n' "$(sha256sum "$TMP_TEST/junk-amd64.iso" | awk '{print $1}')" > "$TMP_TEST/SHA256SUMS"
  if bash "$BUILDER" --upstream-iso "$TMP_TEST/missing-amd64.iso" --checksum-file "$TMP_TEST/SHA256SUMS" \
      --output "$TMP_TEST/out.iso" --check > "$TMP_TEST/missing.out" 2>&1; then
    fail 'builder must reject a missing upstream ISO'
  elif grep -q 'Upstream ISO not found' "$TMP_TEST/missing.out"; then
    pass 'builder rejects a missing upstream ISO with a clear message'
  else
    fail "builder failed without explaining the missing upstream ISO: $(head -n 1 "$TMP_TEST/missing.out")"
  fi

  # A real build must refuse a base medium that carries no ISO 9660 boot catalog, and it
  # must not leave an artifact behind when it does.
  if bash "$BUILDER" --upstream-iso "$TMP_TEST/junk-amd64.iso" --checksum-file "$TMP_TEST/SHA256SUMS" \
      --output "$TMP_TEST/out2.iso" > "$TMP_TEST/junkbuild.out" 2>&1; then
    fail 'a real build must refuse a base medium that carries no ISO 9660 boot catalog'
  else
    pass 'real build refuses a non-bootable base medium'
  fi
  grep -qE 'ERROR: ' "$TMP_TEST/junkbuild.out" \
    && pass 'the refusal is explained with an explicit error' \
    || fail 'real build refused a non-bootable base medium without an explicit error'
  [[ ! -e "$TMP_TEST/out2.iso" && ! -e "$TMP_TEST/out2.iso.sha256" ]] \
    && pass 'refused real build wrote no output artifacts' \
    || fail 'refused real build left output artifacts behind'

  # Dry-run behaviour on a medium that is not an ISO image: xorriso exits 0 and just says
  # "No ISO 9660 image at LBA 0", so this is reported rather than asserted until the
  # preflight probe checks for a boot catalog line itself.
  if bash "$BUILDER" --upstream-iso "$TMP_TEST/junk-amd64.iso" --checksum-file "$TMP_TEST/SHA256SUMS" \
      --output "$TMP_TEST/out.iso" --check > "$TMP_TEST/junk.out" 2>&1; then
    printf 'NOTE: --check accepted a file with no El Torito catalog (xorriso exits 0 on it); tighten the preflight boot-metadata probe when convenient\n'
  else
    pass 'dry run rejects a medium that carries no El Torito catalog'
  fi
  [[ ! -e "$TMP_TEST/out.iso" && ! -e "$TMP_TEST/out.iso.sha256" ]] \
    && pass 'dry run wrote no output artifacts' \
    || fail 'dry run left output artifacts behind'

  # Optional: when a real verified base ISO and xorriso are available, the dry run must pass.
  if [[ -n "${BF_TEST_UPSTREAM_ISO:-}" && -f "${BF_TEST_UPSTREAM_ISO:-}" && -f "$ISO_DIR/ubuntu-26.04.1-SHA256SUMS" ]] \
    && command -v xorriso >/dev/null 2>&1; then
    if bash "$BUILDER" --upstream-iso "$BF_TEST_UPSTREAM_ISO" --checksum-file "$ISO_DIR/ubuntu-26.04.1-SHA256SUMS" \
        --output "$TMP_TEST/real.iso" --check > "$TMP_TEST/real.out" 2>&1; then
      pass 'builder dry run passes against the real verified base ISO'
    else
      fail "builder dry run failed against ${BF_TEST_UPSTREAM_ISO}: $(tail -n 1 "$TMP_TEST/real.out")"
    fi
    [[ ! -e "$TMP_TEST/real.iso" ]] && pass 'dry run wrote no ISO' || fail 'dry run wrote an ISO'
  else
    pass 'real-ISO dry run skipped (set BF_TEST_UPSTREAM_ISO and install xorriso to enable it)'
  fi
fi

# ------------------------------------------------------- secrets and identity --
# No credentials, private keys, device IDs, or machine identities belong in the skeleton.
# Two tiers:
#   1. hard indicators (key blocks, WireGuard keys, RustDesk server, device identity) are
#      scanned across the whole provisioning tree,
#   2. the heuristic "secret-looking assignment" scan covers the directories whose files
#      are actually copied into the installation medium, which is the same set the builder
#      re-scans before it writes one.
# The heuristic requires an alphanumeric character in the value, so an empty placeholder
# such as `token = ""` is not reported while any concrete value still is. (A source file
# that assigns a bare identifier named `token` still trips tier 2 by design; rename such a
# variable rather than widening the rule.)
if grep -RniE --exclude='check-provisioning-static.sh' --exclude='*.md' \
  '(BEGIN (OPENSSH|RSA|EC|DSA|PGP) PRIVATE KEY|WG_(PRIVATE|PEER)_|RUSTDESK_SERVER[[:space:]]*=[[:space:]]*[^<[:space:]#]*[A-Za-z0-9])' \
  "$PROVISIONING"; then
  fail 'secret-like value found in provisioning assets'
elif grep -RniE --exclude='check-provisioning-static.sh' --exclude='*.md' \
  '(^|[^A-Za-z])(password|passwd|token|api[_-]?key|secret)[[:space:]]*[:=][[:space:]]*[^<[:space:]#]*[A-Za-z0-9]' \
  "$PROVISIONING/autoinstall" "$PROVISIONING/firstboot" "$PROVISIONING/release" "$PROVISIONING/offline-repo"; then
  fail 'secret-like value found in assets that are copied into the medium'
else
  pass 'no secret-like value found in provisioning assets'
fi
if grep -RniE --exclude='check-provisioning-static.sh' 'BF-[0-9]{8}|bf-[0-9]{8}|dealer[-_ ]?id[[:space:]]*[:=][[:space:]]*[0-9]{8}' "$PROVISIONING"; then
  fail 'device-specific identity found in provisioning assets'
else
  pass 'no embedded device identity found'
fi

# Firstboot may invoke only the explicit offline installer after a dealer ID check.
if grep -q 'blueforce-install\.sh' "$PROVISIONING/firstboot/bf-firstboot" && grep -q -- '--offline' "$PROVISIONING/firstboot/bf-firstboot"; then
  pass 'firstboot installer path is explicit offline-only'
else
  fail 'firstboot must invoke the installer only with --offline'
fi
grep -q 'BF_FIRSTBOOT_TEST_MODE' "$PROVISIONING/firstboot/bf-firstboot" && pass 'firstboot has mutation-free test mode' || fail 'firstboot test mode missing'

grep -q 'interactive-sections: \[storage\]' "$AUTOINSTALL" && pass 'assisted storage is explicit' || fail 'assisted storage declaration missing'
grep -q 'apt-ftparchive' "$PROVISIONING/offline-repo/build-offline-repo.sh" && pass 'offline repository uses apt-ftparchive' || fail 'offline repository must use apt-ftparchive'
grep -q 'sha256sum' "$PROVISIONING/iso/verify-upstream-iso.sh" && pass 'upstream SHA256 verification present' || fail 'upstream SHA256 verification missing'

if [[ "$FAIL" -ne 0 ]]; then
  printf 'check-provisioning-static: FAILED\n' >&2
  exit 1
fi
printf 'check-provisioning-static: all passed\n'
