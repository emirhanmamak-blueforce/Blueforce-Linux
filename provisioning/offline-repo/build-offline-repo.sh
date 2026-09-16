#!/usr/bin/env bash
# Create a local APT repository solely from reviewed local Debian packages.
#
# Nothing here downloads anything and no dependency is resolved from a remote
# source: every .deb must already exist in the local pool directory.
#
# Modes:
#   --dry-run-plan  Validate the manifest contract only. Needs no build tooling
#                   and no package pool, and prints the exact LAB gaps.
#   --check         Verify that the supplied pool satisfies every pin.
#   --packages/--output (default)  Build the repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BF_MANIFEST_DIR points the --dry-run-plan validator at a fixture directory; the
# static test suite uses it for negative cases. Production runs, --check and the
# build always read the reviewed manifests next to this script.
MANIFEST_DIR="${BF_MANIFEST_DIR:-$SCRIPT_DIR/manifests}"
MANIFESTS=(base-packages.txt remote-access.txt docker.txt)
REQUIREMENTS_FILE="requirements.tsv"
LOCK_SCHEMA_FILE="packages.lock.schema.tsv"
LOCK_HEADER="$(printf 'package\tversion\tarchitecture\tsha256\tsource')"
UNPINNED="UNPINNED"

usage() {
  cat <<'EOF'
Usage: build-offline-repo.sh --packages DIR --output DIR [--check]
       build-offline-repo.sh --dry-run-plan

Uses only local .deb files. apt-ftparchive is required; no package is fetched.
Every package is recorded as package, version, architecture, SHA256, and source.

--dry-run-plan validates manifests/*.txt, manifests/requirements.tsv and
manifests/packages.lock.schema.tsv without apt-ftparchive, dpkg-deb or a package
pool. It exits non-zero while a pin still reads UNPINNED or a required package is
absent from the contract, and lists every gap so the LAB can fill it in.
EOF
}

PACKAGES=""; OUTPUT=""; CHECK_ONLY=0; PLAN_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --packages) PACKAGES="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --dry-run-plan) PLAN_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# Static validation of the pin contract. Findings are collected first so the
# report is complete, sorted, and identical on every machine.
plan_report() {
  local errors=0 awaiting=0 filled=0 total=0 absent=0 known=0 rows=0
  local -A owner=() pinned=() required=()
  local -a awaiting_lines=() absent_lines=() error_lines=()
  local manifest file line lineno package version key name extra tool_apt tool_deb mf pkg source why

  if command -v apt-ftparchive >/dev/null 2>&1; then tool_apt=present; else tool_apt=absent; fi
  if command -v dpkg-deb >/dev/null 2>&1; then tool_deb=present; else tool_deb=absent; fi

  if [[ ! -d "$MANIFEST_DIR" ]]; then
    printf 'PLAN ERROR: manifest directory not found: %s\n' "$MANIFEST_DIR"
    printf '\nPLAN NOT READY: manifest directory is missing.\n'
    return 1
  fi

  # The offline installer reads every manifests/*.txt as a pin manifest, so an
  # extra file there silently becomes part of the contract.
  while IFS= read -r -d '' extra; do
    name="$(basename "$extra")"
    known=0
    for manifest in "${MANIFESTS[@]}"; do
      if [[ "$name" == "$manifest" ]]; then known=1; fi
    done
    if [[ "$known" -eq 0 ]]; then
      error_lines+=("$name: unexpected manifests/*.txt file; scripts/install/blueforce-install.sh treats every one of them as a pin manifest")
      errors=$((errors + 1))
    fi
  done < <(find "$MANIFEST_DIR" -maxdepth 1 -type f -name '*.txt' -print0 | sort -z)

  for manifest in "${MANIFESTS[@]}"; do
    file="$MANIFEST_DIR/$manifest"
    if [[ ! -s "$file" ]]; then
      error_lines+=("$manifest: missing or empty; the offline installer refuses an empty pin manifest")
      errors=$((errors + 1))
      continue
    fi
    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$((lineno + 1))
      if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
      if [[ "$line" == *[![:print:]]* ]]; then
        error_lines+=("$manifest:$lineno: non-printable character in pin")
        errors=$((errors + 1))
        continue
      fi
      if [[ "$line" == *[[:space:]]* ]]; then
        error_lines+=("$manifest:$lineno: whitespace in a pin; expected exactly package=version with no inline comment: $line")
        errors=$((errors + 1))
        continue
      fi
      if [[ ! "$line" =~ ^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$ ]]; then
        error_lines+=("$manifest:$lineno: not an exact pin (expected package=version): $line")
        errors=$((errors + 1))
        continue
      fi
      if [[ "${line,,}" =~ (placeholder|replace|todo|tbd|fixme|changeme|fillme|example) ]]; then
        error_lines+=("$manifest:$lineno: placeholder token left in pin: $line")
        errors=$((errors + 1))
        continue
      fi
      package="${line%%=*}"
      version="${line#*=}"
      total=$((total + 1))
      if [[ "${version^^}" == "$UNPINNED" || ! "$version" =~ [0-9] ]]; then
        awaiting=$((awaiting + 1))
        awaiting_lines+=("$manifest: $package=$version")
      else
        filled=$((filled + 1))
      fi
      if [[ -n "${owner[$package]:-}" ]]; then
        error_lines+=("$manifest:$lineno: duplicate pin for $package; already declared in ${owner[$package]}")
        errors=$((errors + 1))
      fi
      owner[$package]="$manifest"
      pinned["$manifest:$package"]=1
    done < "$file"
  done

  if [[ ! -s "$MANIFEST_DIR/$REQUIREMENTS_FILE" ]]; then
    error_lines+=("$REQUIREMENTS_FILE: missing or empty; the contract has no audit table of why each package is needed")
    errors=$((errors + 1))
  else
    lineno=0
    while IFS=$'\t' read -r mf pkg source why || [[ -n "${mf:-}" ]]; do
      lineno=$((lineno + 1))
      if [[ -z "$mf" || "$mf" == \#* ]]; then continue; fi
      if [[ -z "${pkg:-}" || -z "${source:-}" || -z "${why:-}" ]]; then
        error_lines+=("$REQUIREMENTS_FILE:$lineno: expected four TAB-separated fields (manifest, package, source, why)")
        errors=$((errors + 1))
        continue
      fi
      known=0
      for manifest in "${MANIFESTS[@]}"; do
        if [[ "$mf" == "$manifest" ]]; then known=1; fi
      done
      if [[ "$known" -eq 0 ]]; then
        error_lines+=("$REQUIREMENTS_FILE:$lineno: unknown manifest column: $mf")
        errors=$((errors + 1))
        continue
      fi
      if [[ ! "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
        error_lines+=("$REQUIREMENTS_FILE:$lineno: invalid package name: $pkg")
        errors=$((errors + 1))
        continue
      fi
      key="$mf:$pkg"
      required[$key]=1
      if [[ -z "${pinned[$key]:-}" ]]; then
        absent_lines+=("$mf: $pkg (required by $source)")
        absent=$((absent + 1))
      fi
    done < "$MANIFEST_DIR/$REQUIREMENTS_FILE"
  fi

  for key in "${!pinned[@]}"; do
    if [[ -z "${required[$key]:-}" ]]; then
      error_lines+=("${key%%:*}: ${key#*:} is pinned but absent from $REQUIREMENTS_FILE; add the audit row or drop the pin")
      errors=$((errors + 1))
    fi
  done

  if [[ ! -s "$MANIFEST_DIR/$LOCK_SCHEMA_FILE" ]]; then
    error_lines+=("$LOCK_SCHEMA_FILE: missing or empty; the released packages.lock.tsv layout is undocumented")
    errors=$((errors + 1))
  else
    lineno=0
    rows=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$((lineno + 1))
      if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
      rows=$((rows + 1))
      if [[ "$line" != "$LOCK_HEADER" ]]; then
        if [[ "$rows" -eq 1 ]]; then
          error_lines+=("$LOCK_SCHEMA_FILE:$lineno: first uncommented line must be the exact lock header (TAB-separated package/version/architecture/sha256/source)")
        else
          error_lines+=("$LOCK_SCHEMA_FILE:$lineno: schema template must not contain data rows; keep examples commented out")
        fi
        errors=$((errors + 1))
      fi
    done < "$MANIFEST_DIR/$LOCK_SCHEMA_FILE"
  fi

  printf '=== Offline APT repository dry-run plan (no build, no network) ===\n'
  printf 'Manifest directory: %s\n' "$MANIFEST_DIR"
  printf 'Build tooling (not used by this plan): apt-ftparchive=%s dpkg-deb=%s\n' "$tool_apt" "$tool_deb"
  printf 'A real build additionally needs an Ubuntu 26.04 build machine with both tools.\n'
  printf 'SUMMARY: pins=%d filled=%d awaiting=%d missing_packages=%d errors=%d\n' \
    "$total" "$filled" "$awaiting" "$absent" "$errors"

  if [[ ${#awaiting_lines[@]} -gt 0 ]]; then
    printf '\nMISSING VERSIONS (LAB: replace the %s sentinel with the exact version of the reviewed .deb):\n' "$UNPINNED"
    while IFS= read -r line; do printf '  %s\n' "$line"; done < <(printf '%s\n' "${awaiting_lines[@]}" | sort)
  fi
  if [[ ${#absent_lines[@]} -gt 0 ]]; then
    printf '\nMISSING PACKAGES (required by the installer or the audit table but not pinned):\n'
    while IFS= read -r line; do printf '  %s\n' "$line"; done < <(printf '%s\n' "${absent_lines[@]}" | sort)
  fi
  if [[ ${#error_lines[@]} -gt 0 ]]; then
    printf '\nPLAN ERRORS (contract violations, must be fixed before a build):\n'
    while IFS= read -r line; do printf '  %s\n' "$line"; done < <(printf '%s\n' "${error_lines[@]}" | sort)
  fi

  if [[ "$errors" -gt 0 || "$absent" -gt 0 || "$awaiting" -gt 0 ]]; then
    printf '\nPLAN NOT READY: %d pin(s) await a LAB version, %d required package(s) unpinned, %d error(s).\n' \
      "$awaiting" "$absent" "$errors"
    return 1
  fi
  printf '\nPLAN READY: %d pin(s) cover the contract; run --check on the Ubuntu 26.04 build machine with the reviewed pool.\n' "$total"
  return 0
}

if [[ "$PLAN_ONLY" -eq 1 ]]; then
  [[ -z "$PACKAGES" && -z "$OUTPUT" && "$CHECK_ONLY" -eq 0 ]] || {
    printf 'Refusing: --dry-run-plan cannot be combined with --packages, --output or --check.\n' >&2
    exit 2
  }
  if plan_report; then exit 0; fi
  exit 1
fi

[[ -n "$PACKAGES" && -n "$OUTPUT" ]] || { usage >&2; exit 2; }
[[ -d "$PACKAGES" ]] || { printf 'Package directory not found: %s\n' "$PACKAGES" >&2; exit 2; }
command -v apt-ftparchive >/dev/null 2>&1 || { printf 'Refusing build: apt-ftparchive is not installed.\n' >&2; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { printf 'Refusing build: dpkg-deb is not installed.\n' >&2; exit 1; }
mapfile -d '' debs < <(find "$PACKAGES" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
[[ ${#debs[@]} -gt 0 ]] || { printf 'Refusing build: no local .deb files supplied.\n' >&2; exit 1; }
for list in "$SCRIPT_DIR/manifests/base-packages.txt" "$SCRIPT_DIR/manifests/remote-access.txt" "$SCRIPT_DIR/manifests/docker.txt"; do
  pins=0
  while IFS= read -r pin || [[ -n "$pin" ]]; do
    [[ -z "$pin" || "$pin" == \#* ]] && continue
    [[ "$pin" =~ ^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$ && "$pin" != *placeholder* && "$pin" != *REPLACE* && "$pin" != *replace* ]] || { printf 'Invalid exact package pin in %s: %s\n' "$list" "$pin" >&2; exit 2; }
    version_part="${pin#*=}"
    case "${version_part^^}" in
      *UNPINNED*) printf 'Refusing build: pin still awaits its LAB version in %s: %s\n' "$list" "$pin" >&2; exit 2 ;;
    esac
    pins=$((pins + 1))
    found=0
    for deb in "${debs[@]}"; do
      [[ "$(dpkg-deb -f "$deb" Package)=$(dpkg-deb -f "$deb" Version)" == "$pin" ]] && found=1 && break
    done
    [[ "$found" -eq 1 ]] || { printf 'Pinned package not supplied locally: %s\n' "$pin" >&2; exit 1; }
  done < "$list"
  [[ "$pins" -gt 0 ]] || { printf 'Refusing build: manifest has no concrete package pins: %s\n' "$list" >&2; exit 1; }
done
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf 'Check passed: %d local packages and all requested pins are available.\n' "${#debs[@]}"
  exit 0
fi
[[ ! -e "$OUTPUT" ]] || { printf 'Refusing to overwrite output: %s\n' "$OUTPUT" >&2; exit 2; }
mkdir -p "$OUTPUT/pool"
lock="$OUTPUT/packages.lock.tsv"
printf 'package\tversion\tarchitecture\tsha256\tsource\n' > "$lock"
for deb in "${debs[@]}"; do
  base="$(basename "$deb")"
  cp -- "$deb" "$OUTPUT/pool/$base"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(dpkg-deb -f "$deb" Package)" "$(dpkg-deb -f "$deb" Version)" "$(dpkg-deb -f "$deb" Architecture)" \
    "$(sha256sum "$deb" | awk '{print $1}')" "$base" >> "$lock"
done
( cd "$OUTPUT"; apt-ftparchive packages pool > Packages; gzip -n -9 -c Packages > Packages.gz; sha256sum Packages Packages.gz packages.lock.tsv > SHA256SUMS )
printf 'Built offline repository: %s\n' "$OUTPUT"
