#!/usr/bin/env bash
# Perform non-destructive checks on an explicitly supplied ISO artifact.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test-iso.sh --iso PATH --checksum PATH [--check]

Verifies SHA256 and, when xorriso is installed, reads El Torito boot metadata.
This script neither boots nor writes media.
EOF
}
ISO=""; CHECKSUM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2 ;;
    --checksum) CHECKSUM="${2:-}"; shift 2 ;;
    --check) shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$ISO" && -n "$CHECKSUM" ]] || { usage >&2; exit 2; }
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-upstream-iso.sh" --iso "$ISO" --checksum "$CHECKSUM" --check
command -v xorriso >/dev/null 2>&1 || { printf 'xorriso unavailable: SHA256 passed, boot metadata test is fail-closed.\n' >&2; exit 1; }
xorriso -indev "$ISO" -report_el_torito plain >/dev/null 2>&1 || { printf 'Boot metadata test failed.\n' >&2; exit 1; }
printf 'Non-destructive ISO checks passed: %s\n' "$ISO"
