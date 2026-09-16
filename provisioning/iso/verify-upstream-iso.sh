#!/usr/bin/env bash
# Verify a locally supplied upstream ISO against an explicitly supplied SHA256 record.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: verify-upstream-iso.sh --iso PATH --checksum PATH [--check]

Verifies a local ISO without downloading anything. --checksum may contain a
SHA256SUMS-style line for the ISO or a single 64-character digest.
EOF
}
ISO=""; CHECKSUM=""; CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2 ;;
    --checksum) CHECKSUM="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$ISO" && -n "$CHECKSUM" ]] || { usage >&2; exit 2; }
[[ -f "$ISO" ]] || { printf 'ISO not found: %s\n' "$ISO" >&2; exit 2; }
[[ -f "$CHECKSUM" ]] || { printf 'Checksum file not found: %s\n' "$CHECKSUM" >&2; exit 2; }
expected="$(awk -v base="$(basename "$ISO")" '$1 ~ /^[[:xdigit:]]{64}$/ && (NF == 1 || $2 == base || $2 == "*" base) {print tolower($1); exit}' "$CHECKSUM")"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { printf 'No SHA256 entry for ISO basename in: %s\n' "$CHECKSUM" >&2; exit 2; }
actual="$(sha256sum "$ISO" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  printf 'SHA256 verification FAILED for %s\nexpected: %s\nactual:   %s\n' "$ISO" "$expected" "$actual" >&2
  exit 1
fi
printf 'SHA256 verified: %s\n' "$ISO"
[[ "$CHECK_ONLY" -eq 1 ]] && printf 'Check mode: no files were changed.\n'
