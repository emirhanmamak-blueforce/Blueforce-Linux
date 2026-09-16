#!/usr/bin/env bash
# Single entry point for the repository test suite.
#
# Runs every tests/*.sh (except this file) in sorted order, reports each result, and
# exits with the sum of the individual exit codes so that a single non-zero test can
# never be mistaken for a clean run.
#
# Usage:
#   bash tests/run-all.sh                 # run everything
#   bash tests/run-all.sh offline firstboot   # run only tests whose name contains a term
#
# -e is deliberately not set: a failing test must not abort the rest of the run, it has
# to be reported and counted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

filters=("$@")
tests=()
while IFS= read -r script; do
  tests+=("$script")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f \( -name '*.sh' -o -name 'test_*.py' -o -name 'check_*.py' \) ! -name "$SELF" | sort)

if [[ ${#tests[@]} -eq 0 ]]; then
  printf 'run-all: no tests found in %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi

selected=()
for script in "${tests[@]}"; do
  if [[ ${#filters[@]} -eq 0 ]]; then
    selected+=("$script")
    continue
  fi
  for filter in "${filters[@]}"; do
    if [[ "$(basename "$script")" == *"$filter"* ]]; then
      selected+=("$script")
      break
    fi
  done
done

if [[ ${#selected[@]} -eq 0 ]]; then
  printf 'run-all: no test matched: %s\n' "${filters[*]}" >&2
  exit 1
fi

printf 'run-all: %d test file(s) from %s\n' "${#selected[@]}" "$REPO_ROOT"
exit_code_sum=0
failures=()

for script in "${selected[@]}"; do
  name="$(basename "$script")"
  printf '\n=== %s ===\n' "$name"
  case "$script" in
    *.py)
      # Python suites run from the repository root so `import bfos` and
      # `tests.test_*` module paths resolve.
      ( cd "$REPO_ROOT" && python3 "$script" )
      ;;
    *)
      ( cd "$REPO_ROOT" && bash "$script" )
      ;;
  esac
  status=$?
  if [[ "$status" -eq 0 ]]; then
    printf '%s\n' "--- $name: PASS"
  else
    printf '%s\n' "--- $name: FAIL (exit $status)"
    failures+=("$name")
  fi
  exit_code_sum=$((exit_code_sum + status))
done

printf '\n=== run-all summary ===\n'
printf 'tests run : %d\n' "${#selected[@]}"
# Build the failing-name suffix explicitly: inlining this command substitution in
# the printf argument list makes the empty-array case drop an argument and printf
# then reports "usage: printf ...".
failure_suffix=""
if [[ ${#failures[@]} -gt 0 ]]; then
  failure_suffix=" (${failures[*]})"
fi
printf 'failed    : %d%s\n' "${#failures[@]}" "$failure_suffix"
printf 'exit code : %d (sum of individual exit codes)\n' "$exit_code_sum"

if [[ "$exit_code_sum" -gt 255 ]]; then
  exit 255
fi
exit "$exit_code_sum"
