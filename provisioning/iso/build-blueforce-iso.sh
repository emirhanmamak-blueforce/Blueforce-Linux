#!/usr/bin/env bash
# Build the bootable Blueforce Field OS installation ISO from a local, verified upstream ISO.
#
# Output contract (written next to --output):
#   <iso>                     dist/Blueforce-Field-OS-<version>-amd64.iso
#   <iso>.sha256              SHA256 of the produced ISO
#   <version>-manifest.yaml   release manifest (field_os_version, base_os, ubuntu_version, ...)
#
# The build is flavour-agnostic: --upstream-iso may point at an Ubuntu Server or an
# Ubuntu Desktop ISO. The flavour is detected from the ISO volume label, recorded in
# the manifest as base_flavor, and never inferred from the file name alone.
#
# Safeguards that must not be weakened:
#   * Nothing is downloaded. The upstream ISO and its SHA256 record must already exist
#     locally, and the digest is always recomputed from the real file.
#   * Device identity, dealer id, private keys and passwords are never embedded. The
#     builder refuses to run when it finds them in the media inputs.
#   * The media root carries autoinstall.yaml with `interactive-sections: [storage]`,
#     so the operator still selects and confirms the target disk. No automatic wipe.
#   * Existing boot files are never destroyed: every patched boot configuration keeps a
#     pristine copy on the media as <name>.blueforce-orig.
#
# --check validates every precondition and writes nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-upstream-iso.sh"
VERSION_FILE="$SCRIPT_DIR/field-os-version"
PROVISIONING_DIR="$REPO_ROOT/provisioning"
AUTOINSTALL_DIR="$PROVISIONING_DIR/autoinstall"
FIRSTBOOT_DIR="$PROVISIONING_DIR/firstboot"
RELEASE_DIR="$PROVISIONING_DIR/release"
OFFLINE_REPO_DIR="$PROVISIONING_DIR/offline-repo"
OFFLINE_AUTODETECT="$OFFLINE_REPO_DIR/build"
DEFAULT_DIST="$REPO_ROOT/dist"
MEDIA_PREFIX="/blueforce-provisioning"
FIRSTBOOT_PATH="$MEDIA_PREFIX/firstboot"
ARCH="amd64"
REPRO_STAMP="2024010100000000"

# Identity and credential patterns that must never reach the media. Written with
# bracket expressions so this scanner cannot match its own source text.
IDENTITY_PATTERN='(BEGIN[[:space:]]+(OPENSSH|RSA|EC|DSA|PGP)[[:space:]]+PRIVATE[[:space:]]+KEY|WG_PRIVATE[[:space:]]+KEY|dealer[-_ ]?id[[:space:]]*[:=][[:space:]]*[0-9]{8}|BF-[0-9]{8}|bf-[0-9]{8})'
CREDENTIAL_PATTERN='(password|passwd|credential|api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*[^[:space:]<#]'

usage() {
  cat <<'USAGE'
Usage: build-blueforce-iso.sh --upstream-iso PATH --checksum-file PATH [options]

Builds the bootable Blueforce Field OS installation medium from a local, SHA256
verified Ubuntu ISO (Server or Desktop flavour). No image is downloaded.

Required:
  --upstream-iso PATH    Local Ubuntu ISO used as the base medium
  --checksum-file PATH   SHA256SUMS record for that ISO (alias: --checksum)

Options:
  --output PATH           ISO path (default: dist/Blueforce-Field-OS-<version>-amd64.iso)
  --version VERSION       Field OS version (default: provisioning/iso/field-os-version)
  --offline-repo DIR      Built offline APT repository to embed (Packages, Packages.gz,
                          SHA256SUMS, packages.lock.tsv). Default: auto-detect
                          provisioning/offline-repo/build, else build without it.
  --require-offline-repo  Fail closed when no built offline repository is available
  --volid LABEL           ISO volume label (default: the upstream label, preserved so the
                          live-media discovery path stays untouched; recorded in the manifest)
  --work-dir DIR          Scratch directory (default: the output filesystem when it has
                          room, else $TMPDIR, else /var/tmp; needs about 2x the base ISO)
  --keep-work             Do not delete the scratch directory (debugging)
  --reproducible          Ask xorriso for fixed volume and file dates (byte-stable rebuilds)
  --allow-remaster        Deprecated no-op: this command always performs a real build
  --check                 Validate every precondition, write nothing, exit 0/1
  --help                  Show this help

Media layout produced inside the ISO:
  /autoinstall.yaml                                  assisted autoinstall (root of the medium)
  /blueforce-provisioning/firstboot/                 first boot payload (fixed contract path)
  /blueforce-provisioning/autoinstall/               NoCloud seed copy of the same configuration
  /blueforce-provisioning/offline-repo/              offline APT tooling, manifests and built repo
  /blueforce-provisioning/release/                   release and media metadata
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }
note() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

UPSTREAM=""
CHECKSUM_RECORD=""
OUTPUT=""
OUTPUT_DIR=""
ISO_NAME=""
SHA_FILE=""
MANIFEST=""
VERSION=""
OFFLINE_REPO=""
OFFLINE_MODE="none"
REQUIRE_OFFLINE=0
VOLID=""
VOLID_SOURCE="upstream-preserved"
CHECK_ONLY=0
REPRODUCIBLE=0
KEEP_WORK=0
OPT_WORK_DIR=""
WORK_DIR=""
WORK_ROOT=""
MEDIA=""
UP_IS_SIZE_KB=0
BASE_FLAVOR="unknown"
UBUNTU_VERSION="unknown"
UP_VOLID=""
UPSTREAM_SHA256=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-iso) UPSTREAM="${2:-}"; shift 2 ;;
    --checksum|--checksum-file) CHECKSUM_RECORD="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --offline-repo) OFFLINE_REPO="${2:-}"; shift 2 ;;
    --require-offline-repo) REQUIRE_OFFLINE=1; shift ;;
    --volid) VOLID="${2:-}"; VOLID_SOURCE="explicit"; shift 2 ;;
    --work-dir) OPT_WORK_DIR="${2:-}"; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    --reproducible) REPRODUCIBLE=1; shift ;;
    --allow-remaster) warn "--allow-remaster is deprecated and ignored: this command always builds a real ISO."; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$UPSTREAM" ]] || { printf 'Missing required argument: --upstream-iso\n' >&2; usage >&2; exit 2; }
[[ -n "$CHECKSUM_RECORD" ]] || { printf 'Missing required argument: --checksum-file\n' >&2; usage >&2; exit 2; }

# ----------------------------------------------------------------- small tools --

free_kb() {
  df -Pk -- "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

existing_ancestor() {
  local path="$1"
  while [[ ! -d "$path" && "$path" != "/" ]]; do
    path="$(dirname "$path")"
  done
  printf '%s' "$path"
}

detect_flavor_from_label() {
  local label="$1"
  case "$label" in
    *Server*) printf 'server' ;;
    *Desktop*) printf 'desktop' ;;
    *[Uu]buntu*) printf 'desktop' ;;
    *) printf 'unknown' ;;
  esac
}

version_from_text() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true
}

base_os_string() {
  if [[ "$UBUNTU_VERSION" == "unknown" ]]; then
    printf 'Ubuntu %s' "$BASE_FLAVOR"
  else
    # Title-case the flavour for display only; the machine-readable flavour stays
    # in base_flavor, so nothing depends on this cosmetic spelling.
    printf 'Ubuntu %s %s LTS' "$(printf '%s' "${BASE_FLAVOR:0:1}" | tr '[:lower:]' '[:upper:]')${BASE_FLAVOR:1}" "$UBUNTU_VERSION"
  fi
}

# ------------------------------------------------------------------ parameters --

resolve_parameters() {
  if [[ -z "$VERSION" ]]; then
    [[ -r "$VERSION_FILE" ]] || die "Field OS version file is missing: $VERSION_FILE (pass --version)"
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
  fi
  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}([-.+][0-9A-Za-z.-]+)?$ ]] \
    || die "Invalid Field OS version '${VERSION}': expected e.g. 1.0.0 or 1.1.0-rc1"

  ISO_NAME="Blueforce-Field-OS-${VERSION}-${ARCH}.iso"
  if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$DEFAULT_DIST/$ISO_NAME"
  elif [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$PWD/$OUTPUT"
  fi
  [[ "$(basename "$OUTPUT")" == *.iso ]] || die "--output must name an .iso file: $OUTPUT"
  OUTPUT_DIR="$(dirname "$OUTPUT")"
  SHA_FILE="${OUTPUT}.sha256"
  MANIFEST="$OUTPUT_DIR/${VERSION}-manifest.yaml"

  case "$(basename "$UPSTREAM")" in
    *"${ARCH}"*) : ;;
    *i386*|*arm64*|*ppc64el*|*s390x*) die "Only ${ARCH} media is supported; got: $(basename "$UPSTREAM")" ;;
    *) warn "Upstream ISO name does not mention ${ARCH}: $(basename "$UPSTREAM")" ;;
  esac
}

require_media_inputs() {
  local missing=() file
  local -a required=(
    "$AUTOINSTALL_DIR/autoinstall.yaml"
    "$AUTOINSTALL_DIR/user-data"
    "$AUTOINSTALL_DIR/meta-data"
    "$FIRSTBOOT_DIR/bf-firstboot"
    "$FIRSTBOOT_DIR/blueforce-firstboot.service"
    "$RELEASE_DIR/manifest.yaml"
  )
  for file in "${required[@]}"; do
    [[ -f "$file" ]] || missing+=("${file#"$REPO_ROOT"/}")
  done
  [[ -d "$OFFLINE_REPO_DIR" ]] || missing+=("${OFFLINE_REPO_DIR#"$REPO_ROOT"/}/")
  [[ ${#missing[@]} -eq 0 ]] || die "Required provisioning inputs are missing: ${missing[*]}"
  ok "provisioning inputs present (autoinstall, firstboot, offline-repo tooling, release manifest)"
}

resolve_offline_repo() {
  local missing=() marker
  if [[ -n "$OFFLINE_REPO" && "$OFFLINE_REPO" != "none" ]]; then
    [[ -d "$OFFLINE_REPO" ]] || die "Offline repository directory not found: $OFFLINE_REPO"
  elif [[ -z "$OFFLINE_REPO" && -d "$OFFLINE_AUTODETECT" ]]; then
    OFFLINE_REPO="$OFFLINE_AUTODETECT"
  else
    OFFLINE_REPO=""
  fi

  if [[ -z "$OFFLINE_REPO" ]]; then
    if [[ "$REQUIRE_OFFLINE" -eq 1 ]]; then
      die "No built offline APT repository found (looked at ${OFFLINE_AUTODETECT#"$REPO_ROOT"/} and --offline-repo). Build one with provisioning/offline-repo/build-offline-repo.sh, then retry."
    fi
    OFFLINE_MODE="not-included"
    warn "No built offline APT repository is embedded: the medium ships the offline tooling and manifests only."
    warn "Package installation on the installed system stays OFFLINE BLOCKED until a repository is built and re-embedded."
    return
  fi

  for marker in Packages Packages.gz SHA256SUMS packages.lock.tsv; do
    [[ -f "$OFFLINE_REPO/$marker" ]] || missing+=("$marker")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Offline repository $OFFLINE_REPO is incomplete; missing: ${missing[*]}"
  OFFLINE_MODE="embedded"
  ok "offline APT repository will be embedded: $OFFLINE_REPO"
}

scan_media_inputs() {
  local -a scan_dirs=("$AUTOINSTALL_DIR" "$FIRSTBOOT_DIR" "$RELEASE_DIR" "$OFFLINE_REPO_DIR")
  local hits
  hits="$(grep -RIlE --exclude='*.md' -- "$IDENTITY_PATTERN" "${scan_dirs[@]}" 2>/dev/null || true)"
  [[ -z "$hits" ]] || die "Device identity found in media inputs; refusing to build:"$'\n'"$hits"
  hits="$(grep -RIlE --exclude='*.md' -- "$CREDENTIAL_PATTERN" "${scan_dirs[@]}" 2>/dev/null || true)"
  [[ -z "$hits" ]] || die "Credential-like value found in media inputs; refusing to build:"$'\n'"$hits"
  ok "media inputs carry no device identity, private key or credential"
}

resolve_work_root() {
  local need_kb=$(( UP_IS_SIZE_KB * 2 + 1048576 )) candidate available detail=""
  local -a candidates=()
  if [[ -n "$OPT_WORK_DIR" ]]; then
    candidates=("$OPT_WORK_DIR")
  elif [[ "$CHECK_ONLY" -eq 1 ]]; then
    # Dry runs create no directories, so judge the filesystem the output will land on.
    candidates=("$(existing_ancestor "$OUTPUT_DIR")" "${TMPDIR:-/tmp}" "/var/tmp")
  else
    # Real builds reuse the output directory, which keeps the scratch tree on the same
    # filesystem as the artifact and inside a directory that already has to exist.
    install -d "$OUTPUT_DIR" || die "Could not create the output directory: $OUTPUT_DIR"
    candidates=("$OUTPUT_DIR" "${TMPDIR:-/tmp}" "/var/tmp")
  fi
  for candidate in "${candidates[@]}"; do
    if [[ ! -d "$candidate" ]]; then
      detail+="  ${candidate}: not a directory"$'\n'
      continue
    fi
    available="$(free_kb "$candidate")"
    if [[ -n "$available" && "$available" -ge "$need_kb" ]]; then
      WORK_ROOT="$candidate"
      return 0
    fi
    detail+="  ${candidate}: $(( ${available:-0} / 1024 )) MiB free"$'\n'
  done
  die "Not enough scratch space. This build extracts the base ISO and writes a new one, so it needs about $(( need_kb / 1024 )) MiB free. Checked:
${detail}Pass --work-dir with a directory that has room. Nothing is downloaded to satisfy this."
}

# ------------------------------------------------------------------- preflight --

preflight() {
  step "Preconditions"

  [[ -f "$UPSTREAM" ]] || die "Upstream ISO not found: $UPSTREAM"
  [[ -s "$UPSTREAM" ]] || die "Upstream ISO is empty: $UPSTREAM"
  UP_IS_SIZE_KB=$(( $(stat -c %s -- "$UPSTREAM") / 1024 ))
  ok "upstream ISO present: $(basename "$UPSTREAM") ($(( UP_IS_SIZE_KB / 1024 )) MiB)"
  [[ -f "$CHECKSUM_RECORD" ]] || die "Checksum record not found: $CHECKSUM_RECORD"

  command -v xorriso >/dev/null 2>&1 \
    || die "xorriso is required to build bootable media and was not found in PATH. Install it (for example: apt-get install xorriso) and retry. Nothing was written."
  ok "xorriso available: $(xorriso --version 2>/dev/null | awk 'NR==1 {print $2}')"

  local boot_report
  boot_report="$(xorriso -indev "$UPSTREAM" -report_el_torito plain 2>&1)" \
    || die "xorriso cannot read El Torito boot metadata from $(basename "$UPSTREAM"); refusing to build. Nothing was written."
  # xorriso exits 0 even when the input is not an ISO at all: it prints
  # "No ISO 9660 image at LBA 0" and reports nothing. Combined with a checksum
  # record that happens to match, that would let a non-ISO file through the
  # preflight, so assert positively that boot metadata was actually produced.
  grep -qE 'El Torito boot img' <<<"$boot_report" \
    || die "$(basename "$UPSTREAM") is not usable as an installation ISO: no El Torito boot image was reported. Nothing was written."
  grep -qE 'El Torito boot img.*BIOS' <<<"$boot_report" \
    || warn "upstream ISO reports no BIOS El Torito entry; the produced medium may not boot on Legacy BIOS"
  grep -qE 'El Torito boot img.*(UEFI|EFI)' <<<"$boot_report" \
    || warn "upstream ISO reports no UEFI El Torito entry; the produced medium may not boot on UEFI"
  ok "El Torito boot metadata readable from the upstream ISO"

  UP_VOLID="$(sed -n 's/^Volume id[^:]*:[[:space:]]*//p' <<<"$boot_report" | head -n 1 | tr -d "\"'" || true)"
  UP_VOLID="${UP_VOLID:-unknown}"
  BASE_FLAVOR="$(detect_flavor_from_label "$UP_VOLID")"
  UBUNTU_VERSION="$(version_from_text "$UP_VOLID")"
  [[ -n "$UBUNTU_VERSION" ]] || UBUNTU_VERSION="unknown"
  ok "base label '${UP_VOLID}' => base_flavor=${BASE_FLAVOR}, ubuntu_version=${UBUNTU_VERSION}"
  if [[ "$BASE_FLAVOR" != "server" ]]; then
    warn "Base medium is not the documented Server baseline (docs/24 K-01, docs/26)."
    warn "The deviation is recorded in the manifest as base_flavor=${BASE_FLAVOR}; a Server ISO can be used with --upstream-iso."
  fi

  [[ -n "$VOLID" ]] || VOLID="$UP_VOLID"
  [[ "$VOLID" != "unknown" ]] || VOLID="BLUEFORCE_FIELD_OS"
  (( ${#VOLID} <= 32 )) || die "Volume label too long for ISO 9660 (max 32 characters): $VOLID"
  ok "output volume label: '${VOLID}' (${VOLID_SOURCE})"

  require_media_inputs
  resolve_offline_repo

  local -a existing=()
  [[ -e "$OUTPUT" ]] && existing+=("$OUTPUT")
  [[ -e "$SHA_FILE" ]] && existing+=("$SHA_FILE")
  [[ -e "$MANIFEST" ]] && existing+=("$MANIFEST")
  [[ ${#existing[@]} -eq 0 ]] || die "Refusing to overwrite existing artifacts: ${existing[*]}"
  ok "no existing artifact would be overwritten"

  scan_media_inputs

  local verify_output
  if ! verify_output="$("$VERIFY_SCRIPT" --iso "$UPSTREAM" --checksum "$CHECKSUM_RECORD" --check 2>&1)"; then
    printf '%s\n' "$verify_output" >&2
    die "Upstream ISO failed SHA256 verification against $CHECKSUM_RECORD"
  fi
  UPSTREAM_SHA256="$(sha256sum -- "$UPSTREAM" | awk '{print $1}')"
  ok "upstream SHA256 recomputed from the real file: $UPSTREAM_SHA256"

  resolve_work_root
  ok "scratch directory will be created under: ${WORK_ROOT} (about $(( (UP_IS_SIZE_KB * 2 + 1048576) / 1024 )) MiB required)"

  ok "output contract: $OUTPUT"
  ok "                 ${SHA_FILE}"
  ok "                 ${MANIFEST}"
}

# -------------------------------------------------------------- boot injection --

# Insert the `autoinstall` kernel argument into a boot configuration file without
# damaging the original: the pristine copy is kept on the medium as <name>.blueforce-orig.
# kind=grub     -> `linux`/`linuxefi` lines get the argument right after the kernel path,
#                  ahead of the `---` separator.
# kind=isolinux -> `append` lines get the argument right after the keyword.
# Re-running is idempotent: lines that already request autoinstall are left untouched.
inject_autoinstall_arg() {
  local file="$1" kind="$2" out="${1}.blueforce-inject.tmp" line changed=0
  : > "$out"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$kind" == "grub" ]] \
      && [[ "$line" =~ ^([[:space:]]*(linux|linuxefi)[[:space:]]+)([^[:space:]]+)(.*)$ ]] \
      && [[ "$line" != *autoinstall* ]]; then
      printf '%s%s autoinstall%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" >> "$out"
      changed=$((changed + 1))
      continue
    fi
    if [[ "$kind" == "isolinux" ]] \
      && [[ "$line" =~ ^([[:space:]]*(append|APPEND)[[:space:]]+)(.*)$ ]] \
      && [[ "$line" != *autoinstall* ]]; then
      printf '%sautoinstall %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" >> "$out"
      changed=$((changed + 1))
      continue
    fi
    printf '%s\n' "$line" >> "$out"
  done < "$file"

  if [[ "$changed" -gt 0 ]]; then
    [[ -e "${file}.blueforce-orig" ]] || cp -p "$file" "${file}.blueforce-orig"
    mv "$out" "$file"
  else
    rm -f "$out"
  fi
  printf '%d' "$changed"
}

inject_boot_configuration() {
  step "Boot configuration"
  local -a grub_files=(
    "$MEDIA/boot/grub/grub.cfg"
    "$MEDIA/boot/grub/loopback.cfg"
    "$MEDIA/EFI/boot/grub.cfg"
  )
  local -a isolinux_files=(
    "$MEDIA/isolinux/txt.cfg"
    "$MEDIA/isolinux/isolinux.cfg"
    "$MEDIA/isolinux/gtk.cfg"
  )
  local file changed grub_total=0 isolinux_total=0
  for file in "${grub_files[@]}"; do
    [[ -f "$file" ]] || continue
    changed="$(inject_autoinstall_arg "$file" grub)"
    grub_total=$((grub_total + changed))
    ok "GRUB ${file#"$MEDIA"/}: ${changed} kernel line(s) now request autoinstall"
  done
  for file in "${isolinux_files[@]}"; do
    [[ -f "$file" ]] || continue
    changed="$(inject_autoinstall_arg "$file" isolinux)"
    isolinux_total=$((isolinux_total + changed))
    ok "isolinux ${file#"$MEDIA"/}: ${changed} append line(s) now request autoinstall"
  done

  [[ $((grub_total + isolinux_total)) -gt 0 ]] \
    || die "No recognised boot configuration (GRUB or isolinux) was found in the upstream ISO; refusing to write a medium that cannot start the installer."
  if [[ "$grub_total" -eq 0 ]]; then
    warn "No GRUB configuration was patched: automatic autoinstall start is not prepared for this base ISO."
  fi
  if [[ "$isolinux_total" -eq 0 ]]; then
    note "note: this base ISO carries no isolinux configuration (Legacy BIOS boots through the El Torito GRUB image, which reads the patched GRUB configuration)."
  fi
}

# --------------------------------------------------------------------- staging --

write_media_metadata() {
  local release_file="$MEDIA$MEDIA_PREFIX/release/blueforce-release"
  cat > "$release_file" <<EOF
# Blueforce Field OS release identity, installed as /etc/blueforce-release.
# Device identity, dealer id and provisioning state are written by the firstboot
# installer on the target, never by the installation medium.
FIELD_OS_VERSION=${VERSION}
BASE_OS=$(base_os_string)
BASE_FLAVOR=${BASE_FLAVOR}
UBUNTU_VERSION=${UBUNTU_VERSION}
BASE_ISO_FILENAME=$(basename "$UPSTREAM")
BASE_ISO_SHA256=${UPSTREAM_SHA256}
ARCHITECTURE=${ARCH}
FIRSTBOOT_PATH=${FIRSTBOOT_PATH}
AUTOINSTALL_CONFIG=/autoinstall.yaml
OFFLINE_REPO_STATUS=${OFFLINE_MODE}
EOF
  chmod 0644 "$release_file"

  cat > "$MEDIA$MEDIA_PREFIX/release/media-info.yaml" <<EOF
schema_version: 1
field_os_version: "${VERSION}"
base_os: "$(base_os_string)"
base_flavor: "${BASE_FLAVOR}"
base_iso_filename: "$(basename "$UPSTREAM")"
base_iso_sha256: "${UPSTREAM_SHA256}"
ubuntu_version: "${UBUNTU_VERSION}"
architecture: "${ARCH}"
iso_volid: "${VOLID}"
autoinstall_config: "/autoinstall.yaml"
interactive_sections: [storage]
apt_fallback: offline-install
firstboot_path: "${FIRSTBOOT_PATH}"
offline_repo_status: "${OFFLINE_MODE}"
build_timestamp: omitted-on-purpose
EOF
  chmod 0644 "$MEDIA$MEDIA_PREFIX/release/media-info.yaml"
  # Generated files get a fixed modification time so a rebuild from identical inputs
  # differs only in what --reproducible pins down in xorriso.
  touch -t "${REPRO_STAMP:0:8}${REPRO_STAMP:8:4}.${REPRO_STAMP:12:2}" "$release_file" \
    "$MEDIA$MEDIA_PREFIX/release/media-info.yaml"
  ok "release metadata written (no build timestamp is embedded in the medium)"
}

prepare_media() {
  step "Staging media tree"
  MEDIA="$WORK_DIR/media"
  install -d "$MEDIA"

  if ! xorriso -osirrox on -indev "$UPSTREAM" -extract / "$MEDIA" >"$WORK_DIR/extract.log" 2>&1; then
    tail -n 15 "$WORK_DIR/extract.log" >&2
    die "ISO filesystem extraction failed (log: $WORK_DIR/extract.log)"
  fi
  chmod -R u+w "$MEDIA"
  ok "upstream tree extracted to the scratch directory"

  install -d "$MEDIA$MEDIA_PREFIX/autoinstall" "$MEDIA$MEDIA_PREFIX/firstboot" \
    "$MEDIA$MEDIA_PREFIX/offline-repo" "$MEDIA$MEDIA_PREFIX/release"

  install -m 0644 "$AUTOINSTALL_DIR/autoinstall.yaml" "$MEDIA/autoinstall.yaml"
  install -m 0644 "$AUTOINSTALL_DIR/autoinstall.yaml" "$MEDIA$MEDIA_PREFIX/autoinstall/autoinstall.yaml"
  install -m 0644 "$AUTOINSTALL_DIR/user-data" "$MEDIA$MEDIA_PREFIX/autoinstall/user-data"
  install -m 0644 "$AUTOINSTALL_DIR/meta-data" "$MEDIA$MEDIA_PREFIX/autoinstall/meta-data"
  if [[ -f "$AUTOINSTALL_DIR/README.md" ]]; then
    install -m 0644 "$AUTOINSTALL_DIR/README.md" "$MEDIA$MEDIA_PREFIX/autoinstall/README.md"
  fi
  ok "autoinstall configuration placed at /autoinstall.yaml and ${MEDIA_PREFIX}/autoinstall/"

  install -m 0755 "$FIRSTBOOT_DIR/bf-firstboot" "$MEDIA$FIRSTBOOT_PATH/bf-firstboot"
  install -m 0644 "$FIRSTBOOT_DIR/blueforce-firstboot.service" "$MEDIA$FIRSTBOOT_PATH/blueforce-firstboot.service"
  if [[ -f "$FIRSTBOOT_DIR/README.md" ]]; then
    install -m 0644 "$FIRSTBOOT_DIR/README.md" "$MEDIA$FIRSTBOOT_PATH/README.md"
  fi
  ok "firstboot payload placed at ${FIRSTBOOT_PATH}/"

  cp -a "$OFFLINE_REPO_DIR/." "$MEDIA$MEDIA_PREFIX/offline-repo/"
  rm -f "$MEDIA$MEDIA_PREFIX/offline-repo/packages/.gitkeep"
  if [[ "$OFFLINE_MODE" == "embedded" ]]; then
    install -d "$MEDIA$MEDIA_PREFIX/offline-repo/built"
    cp -a "$OFFLINE_REPO/." "$MEDIA$MEDIA_PREFIX/offline-repo/built/"
    ok "offline APT repository placed at ${MEDIA_PREFIX}/offline-repo/built/"
  else
    ok "offline APT tooling and manifests placed at ${MEDIA_PREFIX}/offline-repo/ (no built repository)"
  fi

  install -m 0644 "$RELEASE_DIR/manifest.yaml" "$MEDIA$MEDIA_PREFIX/release/manifest.yaml"
  write_media_metadata
  chmod -R a+rX "$MEDIA$MEDIA_PREFIX"
}

# --------------------------------------------------------------------- ISO out --

# Rebuild the boot structure from the base ISO's own layout.
#
# Why this is not `-boot_image any replay`:
#   Ubuntu live ISOs carry boot information in two places that a replay cannot
#   re-establish, because neither is a data file inside the ISO9660 tree:
#     1. the GRUB2 MBR boot code lives in the first 16 sectors of the *source
#        image*, and
#     2. the EFI system partition is an APPENDED PARTITION, i.e. a byte range of
#        the source image.
#   Replaying them fails with:
#     "Cannot enable EL Torito boot image #1 because it is not a data file in
#      the ISO filesystem"
#     "Cannot refer by GRUB2 MBR to data outside of ISO 9660 filesystem"
#
#   `xorriso -report_el_torito as_mkisofs` emits the exact option set that
#   reconstructs the layout, so it is read from the base ISO at build time rather
#   than hard-coded. That keeps Server and Desktop flavours, and future ISO
#   revisions, working without editing this script.
read_boot_layout_options() {
  local lines="$WORK_DIR/boot-layout.lines" tokens="$1"
  xorriso -indev "$UPSTREAM" -report_el_torito as_mkisofs >"$WORK_DIR/boot-layout.raw" 2>/dev/null || true

  # Step 1: keep the mkisofs option lines only, and drop the options this script
  # owns.
  #
  # `--modification-date` must be dropped: xorriso translates it into its own
  # `-volume_date uuid`, which then rejects the value as "not an ECMA-119 time
  # string". This script controls the date itself.
  #
  # Nothing else is rewritten. The `--interval:local_fs:...` operands inside
  # `--grub2-mbr` and `-append_partition` already name the base ISO with the very
  # path this build passed to xorriso, so they are used verbatim. Rewriting them
  # (e.g. via sed or an extra gsub) reorders the interval fields and xorriso then
  # fails with "Number text too short or too long in interval reader description
  # string". If a future build ever reads and writes the base ISO under different
  # paths, that rewrite has to replace the path operand in place, not prefix it.
  awk '
    /^-/ {
      if ($0 ~ /^-V / || $0 == "-V" || $0 ~ /^-o / || $0 == "-o" || $0 ~ /^--modification-date[= ]/) next
      print
    }
  ' "$WORK_DIR/boot-layout.raw" >"$lines"

  # Step 2: split each line into individual arguments.
  #
  # as_mkisofs quotes values that contain spaces or commas, and those quoted
  # values must reach xorriso as ONE argument. Emitting one option per line and
  # relying on the shell to strip the quotes does not work: the option and its
  # value collapse into a single argument, and xorriso then reports
  # "Unrecognized option '--grub2-mbr --interval:...'".
  # So tokenise here: honour quotes while splitting, then drop the quote
  # characters, and emit one argument per line for mapfile to collect.
  awk '
    {
      line = $0; n = length(line); i = 1; token = ""; inq = 0
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "'"'"'") { inq = !inq; i++; continue }
        if (!inq && (c == " " || c == "\t")) {
          if (token != "") { print token; token = "" }
          i++; continue
        }
        token = token c; i++
      }
      if (token != "") print token
    }
  ' "$lines" >"$tokens"

  grep -q -- '-append_partition' "$tokens" || return 1
  return 0
}

assemble_iso() {
  step "Writing the ISO"
  # The boot layout comes from the base ISO itself; see read_boot_layout_options.
  if ! read_boot_layout_options "$WORK_DIR/boot-layout.opts"; then
    die "could not read a usable boot layout from $(basename "$UPSTREAM"); refusing to write a medium that may not boot."
  fi

  local -a boot_opts=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && boot_opts+=("$line")
  done <"$WORK_DIR/boot-layout.opts"
  step "Boot layout: ${#boot_opts[@]} option line(s) replayed from the base ISO"

  local -a cmd=(xorriso -as mkisofs)
  cmd+=(-V "$VOLID")
  if [[ "$REPRODUCIBLE" -eq 1 ]]; then
    # -as mkisofs does not know xorriso's -volume_date; the mkisofs-compatible
    # spelling is --modification-date=<YYYYMMDDhhmmsscc>.
    # File mtimes come from the extracted base ISO plus the files this script
    # installs, and are already stable for identical inputs; --reproducible only
    # has to pin the volume-level dates for a byte-stable rebuild.
    cmd+=("--modification-date=$REPRO_STAMP")
  fi
  cmd+=("${boot_opts[@]}" -o "$OUTPUT" "$MEDIA")

  # Diagnostic: record the exact argv before running it. This is what settles
  # "the file looks right but xorriso still rejects an option" reports.
  local -a trace_cmd=()
  if [[ "${BF_ISO_TRACE:-0}" == "1" ]]; then
    { printf 'argv:'; printf ' %q' "${cmd[@]}"; printf '\n'; } >"$WORK_DIR/assemble-argv.txt"
  fi

  if ! "${cmd[@]}" >"$WORK_DIR/assemble.log" 2>&1; then
    tail -n 20 "$WORK_DIR/assemble.log" >&2
    [[ -s "$WORK_DIR/assemble-argv.txt" ]] && cat "$WORK_DIR/assemble-argv.txt" >&2
    rm -f "$OUTPUT"
    die "xorriso failed to write the output ISO; the incomplete file was removed."
  fi
  [[ -s "$OUTPUT" ]] || { rm -f "$OUTPUT"; die "xorriso reported success but produced no data."; }
  ok "ISO written: $OUTPUT ($(( $(stat -c %s -- "$OUTPUT") / 1024 / 1024 )) MiB)"
}

extract_from_iso() {
  local iso_path="$1" dest="$2"
  rm -f "$dest"
  xorriso -osirrox on -indev "$OUTPUT" -extract "$iso_path" "$dest" >/dev/null 2>&1
  [[ -f "$dest" ]]
}

verify_output_iso() {
  step "Verifying the produced medium"
  local check_dir="$WORK_DIR/verify"
  install -d "$check_dir"

  xorriso -indev "$OUTPUT" -report_el_torito plain > "$WORK_DIR/boot-report.txt" 2>&1 || true
  grep -qE 'El Torito boot img.*BIOS' "$WORK_DIR/boot-report.txt" \
    || { rm -f "$OUTPUT"; die "produced ISO lost its BIOS El Torito entry; the broken output was removed."; }
  grep -qE 'El Torito boot img.*(UEFI|EFI)' "$WORK_DIR/boot-report.txt" \
    || { rm -f "$OUTPUT"; die "produced ISO lost its UEFI El Torito entry; the broken output was removed."; }
  grep -qF "Volume id    : '$VOLID'" "$WORK_DIR/boot-report.txt" \
    || warn "produced ISO reports a different volume label than requested (${VOLID})"
  ok "El Torito boot entries preserved (BIOS + UEFI) and readable by xorriso"

  extract_from_iso /autoinstall.yaml "$check_dir/autoinstall.yaml" \
    || { rm -f "$OUTPUT"; die "the produced ISO has no /autoinstall.yaml at the medium root."; }
  grep -q 'interactive-sections: \[storage\]' "$check_dir/autoinstall.yaml" \
    || { rm -f "$OUTPUT"; die "medium autoinstall lost 'interactive-sections: [storage]'; the broken output was removed."; }
  grep -q 'offline-install' "$check_dir/autoinstall.yaml" \
    || { rm -f "$OUTPUT"; die "medium autoinstall is missing the offline-install apt fallback."; }
  grep -q "$MEDIA_PREFIX/firstboot" "$check_dir/autoinstall.yaml" \
    || { rm -f "$OUTPUT"; die "medium autoinstall does not place the firstboot payload from ${FIRSTBOOT_PATH}/."; }
  grep -q 'blueforce-firstboot.service' "$check_dir/autoinstall.yaml" \
    || { rm -f "$OUTPUT"; die "medium autoinstall does not enable blueforce-firstboot.service."; }
  ok "medium root /autoinstall.yaml verified (interactive storage, offline-install fallback, firstboot late-commands)"

  extract_from_iso /boot/grub/grub.cfg "$check_dir/grub.cfg" \
    || { rm -f "$OUTPUT"; die "the produced ISO has no /boot/grub/grub.cfg; the broken output was removed."; }
  grep -q 'autoinstall' "$check_dir/grub.cfg" \
    || { rm -f "$OUTPUT"; die "the medium GRUB configuration does not start autoinstall; the broken output was removed."; }
  ok "medium GRUB configuration requests autoinstall on boot"
  if extract_from_iso /boot/grub/grub.cfg.blueforce-orig "$check_dir/grub.cfg.orig"; then
    ok "pristine GRUB configuration kept on the medium as grub.cfg.blueforce-orig"
  fi

  local -a expected=(
    "$MEDIA_PREFIX/firstboot/bf-firstboot"
    "$MEDIA_PREFIX/firstboot/blueforce-firstboot.service"
    "$MEDIA_PREFIX/release/blueforce-release"
    "$MEDIA_PREFIX/release/media-info.yaml"
    "$MEDIA_PREFIX/release/manifest.yaml"
    "$MEDIA_PREFIX/offline-repo/manifests/base-packages.txt"
  )
  local relative
  for relative in "${expected[@]}"; do
    extract_from_iso "$relative" "$check_dir/payload" \
      || { rm -f "$OUTPUT"; die "the produced ISO is missing ${relative}; the broken output was removed."; }
  done
  ok "firstboot, release and offline-repo payloads present in the produced ISO"

  if [[ "$OFFLINE_MODE" == "embedded" ]]; then
    extract_from_iso "$MEDIA_PREFIX/offline-repo/built/Packages" "$check_dir/Packages" \
      || { rm -f "$OUTPUT"; die "the offline APT index is missing from the produced ISO."; }
    ok "offline APT repository index present in the produced ISO"
  fi
}

# ------------------------------------------------------------------ artifacts --

package_version_from_offline_repo() {
  local lock="" value name
  [[ "$OFFLINE_MODE" == "embedded" ]] && lock="$OFFLINE_REPO/packages.lock.tsv"
  if [[ -z "$lock" || ! -f "$lock" ]]; then
    printf 'unknown'
    return
  fi
  for name in "$@"; do
    value="$(awk -F'\t' -v p="$name" 'NR > 1 && $1 == p {print $2; exit}' "$lock" | head -n 1 || true)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
  done
  printf 'unknown'
}

package_version_by_pattern() {
  local pattern="$1" lock="" value
  if [[ "$OFFLINE_MODE" != "embedded" ]]; then
    printf 'unknown'
    return
  fi
  lock="$OFFLINE_REPO/packages.lock.tsv"
  [[ -f "$lock" ]] || { printf 'unknown'; return; }
  value="$(awk -F'\t' -v pat="$pattern" 'NR > 1 && $1 ~ pat {print $2; exit}' "$lock" | head -n 1 || true)"
  printf '%s' "${value:-unknown}"
}

write_dist_artifacts() {
  step "Checksums and manifest"
  local iso_sha256 build_date git_commit git_state
  iso_sha256="$(sha256sum -- "$OUTPUT" | awk '{print $1}')"
  printf '%s  %s\n' "$iso_sha256" "$(basename "$OUTPUT")" > "$SHA_FILE"
  ok "checksum written: $SHA_FILE"

  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git_commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  git_commit="${git_commit:-unknown}"
  # Distinguish "clean", "dirty" and "cannot tell". If git is unavailable or the
  # tree is not a repository, the status command fails and the previous form would
  # silently report "clean" - a claim the build has no evidence for.
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git_state="unknown"
  elif [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -n 1 || true)" ]]; then
    git_state="dirty-worktree"
  else
    git_state="clean"
  fi

  local rustdesk_pkg docker_pkg xrdp_pkg wireguard_pkg meg_pkg installer_pkg packages_source
  rustdesk_pkg="$(package_version_by_pattern '^(rustdesk|rustdesk-server)$')"
  docker_pkg="$(package_version_from_offline_repo docker-ce docker.io docker)"
  xrdp_pkg="$(package_version_from_offline_repo xrdp xorgxrdp gnome-session)"
  wireguard_pkg="$(package_version_from_offline_repo wireguard wireguard-tools)"
  meg_pkg="$(package_version_by_pattern '^meg')"
  installer_pkg="$(package_version_by_pattern '^blueforce-installer')"
  if [[ "$OFFLINE_MODE" == "embedded" ]]; then
    packages_source="embedded offline APT lock file (packages.lock.tsv)"
  else
    packages_source="no built offline repository was embedded; every package version is reported as unknown on purpose"
  fi

  {
    printf 'schema_version: 1\n'
    printf 'field_os_version: "%s"\n' "$VERSION"
    printf 'base_os: "%s"\n' "$(base_os_string)"
    printf 'base_flavor: "%s"\n' "$BASE_FLAVOR"
    printf 'base_iso_filename: "%s"\n' "$(basename "$UPSTREAM")"
    printf 'ubuntu_version: "%s"\n' "$UBUNTU_VERSION"
    printf 'ubuntu_iso_sha256: "%s"\n' "$UPSTREAM_SHA256"
    printf 'git_commit: "%s"\n' "$git_commit"
    printf 'git_worktree: "%s"\n' "$git_state"
    printf 'build_date: "%s"\n' "$build_date"
    printf 'architecture: "%s"\n' "$ARCH"
    printf 'iso_volid: "%s"\n' "$VOLID"
    printf 'iso_filename: "%s"\n' "$(basename "$OUTPUT")"
    printf 'iso_sha256: "%s"\n' "$iso_sha256"
    printf 'release_status: "lab-artifact"\n'
    printf 'packages:\n'
    printf '  rustdesk: "%s"\n' "$rustdesk_pkg"
    printf '  docker: "%s"\n' "$docker_pkg"
    printf '  xrdp: "%s"\n' "$xrdp_pkg"
    printf '  wireguard: "%s"\n' "$wireguard_pkg"
    printf '  meg_package_version: "%s"\n' "$meg_pkg"
    printf '  blueforce_installer_version: "%s"\n' "$installer_pkg"
    printf 'packages_source: "%s"\n' "$packages_source"
    printf 'media:\n'
    printf '  autoinstall_config: "/autoinstall.yaml"\n'
    printf '  interactive_sections: [storage]\n'
    printf '  apt_fallback: "offline-install"\n'
    printf '  firstboot_path: "%s/"\n' "$FIRSTBOOT_PATH"
    printf '  offline_repo_status: "%s"\n' "$OFFLINE_MODE"
    printf '  boot: "El Torito BIOS + UEFI rebuilt from the base ISO boot layout; autoinstall requested on every kernel line"\n'
    printf '  checksum_record: "%s"\n' "$(basename "$CHECKSUM_RECORD")"
    printf 'safety:\n'
    printf '  device_identity_embedded: false\n'
    printf '  automatic_disk_wipe: false\n'
    printf '  identity_collection_point: "firstboot (dealer ID is entered on the installed system)"\n'
    if [[ "$BASE_FLAVOR" != "server" ]]; then
      printf 'baseline_deviation:\n'
      printf '  documented_baseline: "Ubuntu Server 26.04.1+ LTS (docs/24 K-01, docs/26, docs/32)"\n'
      printf '  built_base: "%s"\n' "$(base_os_string)"
      printf '  reason: "The only checksum-verified installation medium available on this build host is the %s ISO, and builds must not download another image."\n' "$BASE_FLAVOR"
      printf '  impact: "Desktop media already ships GNOME, so the GNOME desktop layer needs no extra installation step on the target. Server media stays supported through --upstream-iso."\n'
      printf '  decision_needed: "Accept the Desktop-based baseline for LAB, or rebuild against a Server ISO before production use."\n'
      printf '  lab_required: true\n'
    else
      printf 'baseline_deviation: none\n'
    fi
    printf 'notes:\n'
    printf '  - "The build date lives in this manifest only; the ISO itself carries no build timestamp."\n'
    printf '  - "Boot acceptance (UEFI, Legacy BIOS, Secure Boot) and the autoinstall path on this flavour are LAB work; this artifact is not a production release."\n'
    printf '  - "Device identity, dealer ID, private keys and passwords are never embedded; identity is collected at firstboot."\n'
  } > "$MANIFEST"
  ok "manifest written: $MANIFEST"
}

print_summary() {
  step "Done"
  note "Field OS version : $VERSION"
  note "Base medium      : $(base_os_string) [base_flavor=${BASE_FLAVOR}]"
  note "Base ISO SHA256  : $UPSTREAM_SHA256"
  note "ISO              : $OUTPUT"
  note "ISO checksum     : $SHA_FILE"
  note "Manifest         : $MANIFEST"
  note "Offline repo     : $OFFLINE_MODE"
  note ""
  note "The medium boots into an operator-assisted install: storage stays interactive and"
  note "device identity is entered at firstboot. UEFI/BIOS boot acceptance is still a LAB step."
}

main() {
  resolve_parameters
  preflight
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    step "Check passed"
    note "All preconditions for $ISO_NAME are satisfied. Nothing was written."
    exit 0
  fi

  WORK_DIR="$(mktemp -d "$WORK_ROOT/blueforce-iso.XXXXXX")" || die "Could not create a scratch directory under $WORK_ROOT"
  cleanup() {
    if [[ "$KEEP_WORK" -eq 1 ]]; then
      printf 'Scratch directory kept: %s\n' "$WORK_DIR"
    else
      rm -rf -- "$WORK_DIR"
    fi
  }
  trap cleanup EXIT

  prepare_media
  inject_boot_configuration
  assemble_iso
  verify_output_iso
  write_dist_artifacts
  print_summary
}

main "$@"
