#!/usr/bin/env bash
# Static and sandboxed behavior test for the first-boot terminal wizard.
#
# It never runs systemd, never touches apt, and never touches the real /var state: every
# scenario works inside a throwaway sandbox with a fake installer. Scenarios that require
# root run in a separate user namespace (unshare -r) and are reported as SKIP when the
# host does not permit that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
BF="$REPO_ROOT/provisioning/firstboot/bf-firstboot"
UNIT="$REPO_ROOT/provisioning/firstboot/blueforce-firstboot.service"
README_FILE="$REPO_ROOT/provisioning/firstboot/README.md"

WORK="$(mktemp -d)"
PASSED=0
FAILED=0
SKIPPED=0

trap 'rm -rf "$WORK"' EXIT

ok() {
  if [[ -n "${BF_TEST_RESULTS:-}" ]]; then
    printf 'PASS\t%s\n' "$*" >>"$BF_TEST_RESULTS"
  else
    printf 'OK   %s\n' "$*"
    PASSED=$((PASSED + 1))
  fi
}
bad() {
  if [[ -n "${BF_TEST_RESULTS:-}" ]]; then
    printf 'FAIL\t%s\n' "$*" >>"$BF_TEST_RESULTS"
  else
    printf 'FAIL %s\n' "$*" >&2
    FAILED=$((FAILED + 1))
  fi
}
skip() {
  if [[ -n "${BF_TEST_RESULTS:-}" ]]; then
    printf 'SKIP\t%s\n' "$*" >>"$BF_TEST_RESULTS"
  else
    printf 'SKIP %s\n' "$*"
    SKIPPED=$((SKIPPED + 1))
  fi
}
section() { [[ -n "${BF_TEST_RESULTS:-}" ]] || printf '\n== %s ==\n' "$*"; }

assert_rc() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected exit $1, got $2)"; fi
}
assert_output() {
  if [[ "$2" == *"$1"* ]]; then ok "$3"; else bad "$3 (output lacks: $1)"; fi
}
assert_no_output() {
  if [[ "$2" != *"$1"* ]]; then ok "$3"; else bad "$3 (output unexpectedly contains: $1)"; fi
}
assert_file() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}
assert_no_file() {
  if [[ ! -e "$1" ]]; then ok "$2"; else bad "$2 (unexpected path: $1)"; fi
}
assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected '$1', got '$2')"; fi
}
assert_grep() {
  if grep -qF -- "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3 (pattern not found in $2)"; fi
}
assert_no_grep() {
  if grep -qF -- "$1" "$2" 2>/dev/null; then bad "$3 (forbidden pattern found in $2)"; else ok "$3"; fi
}
assert_no_directive() {
  if grep -qE "^[[:space:]]*$1=" "$2" 2>/dev/null; then bad "$3 (forbidden unit directive in $2)"; else ok "$3"; fi
}

ENV_ARGS=()
SB=''
OUT=''
RC=0

new_sandbox() {
  SB="$(mktemp -d "$WORK/sb.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s/calls.log"\n' "$SB"
  } >"$SB/fake-install.sh"
  chmod 755 "$SB/fake-install.sh"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexamplePublicKeyForStaticFirstbootTest field@blueforce\n' >"$SB/key.pub"
  chmod 600 "$SB/key.pub"
  ENV_ARGS=(
    "BF_FIRSTBOOT_MARKER=$SB/marker"
    "STATE_DIR=$SB/state"
    "BF_INSTALLER_PATH=$SB/fake-install.sh"
    "BF_ADMIN_PUBLIC_KEY_FILE=$SB/key.pub"
    "BF_REIDENTITY_AUDIT_LOG=$SB/audit.log"
    "BF_FIRSTBOOT_INPUT_TIMEOUT=10"
  )
}

installer_calls() {
  if [[ -f "$SB/calls.log" ]]; then wc -l <"$SB/calls.log" | tr -d ' '; else printf '0'; fi
}
installer_args() {
  if [[ -f "$SB/calls.log" ]]; then cat "$SB/calls.log"; else printf ''; fi
}
sandbox_listing() {
  (cd "$SB" && ls -1A | sort | tr '\n' ',')
}
write_marker() {
  printf '%s\n' "$1" >"$SB/marker"
  chmod 600 "$SB/marker"
}
marker_content() {
  if [[ -f "$SB/marker" ]]; then tr -d '[:space:]' <"$SB/marker"; else printf '<no-marker>'; fi
}
file_mode() {
  if [[ -e "$1" ]]; then stat -c '%a' "$1"; else printf '<missing>'; fi
}

# Non-interactive invocation: stdin is /dev/null, so the wizard can never prompt.
run_bf() {
  set +e
  OUT="$(timeout 60 env "${ENV_ARGS[@]}" "$@" 2>&1 </dev/null)"
  RC=$?
  set -e
}

# Interactive invocation behind a real pseudo terminal, with the given keystrokes.
# The command (with any VAR=value prefixes) is rebuilt inside the pty through env, so it
# is passed exactly like the plain run_bf helper.
pty_command() {
  local inner='env' arg
  for arg in "$@"; do inner+=" $(printf '%q' "$arg")"; done
  printf '%s' "$inner"
}

run_bf_tty() {
  local input="$1"
  shift
  local inner
  inner="$(pty_command "$@")"
  set +e
  OUT="$(printf '%s\n' "$input" | env SHELL=/bin/bash "${ENV_ARGS[@]}" timeout 60 script -qec "$inner" /dev/null 2>&1)"
  RC=$?
  set -e
}

# Same, but with no bytes written to the pseudo terminal at all (timeout path).
run_bf_tty_silent() {
  local inner
  inner="$(pty_command "$@")"
  set +e
  OUT="$(printf '' | env SHELL=/bin/bash "${ENV_ARGS[@]}" timeout 60 script -qec "$inner" /dev/null 2>&1)"
  RC=$?
  set -e
}

# ---------------------------------------------------------------------------
# Source, unit and documentation checks (no execution).
# ---------------------------------------------------------------------------
check_sources() {
  section 'static: script, unit, README'

  [[ -x "$BF" ]] && ok 'bf-firstboot is executable' || bad 'bf-firstboot is executable'
  assert_eq '#!/usr/bin/env bash' "$(head -n 1 "$BF")" 'bf-firstboot has a bash shebang'
  if bash -n "$BF" 2>/dev/null; then ok 'bf-firstboot parses (bash -n)'; else bad 'bf-firstboot parses (bash -n)'; fi
  assert_grep 'set -euo pipefail' "$BF" 'bf-firstboot uses strict mode'
  assert_grep '^[0-9]{8}$' "$BF" 'bf-firstboot validates the dealer number with the shared regex'
  assert_grep '# BLUEFORCE FIELD OS' "$BF" 'bf-firstboot prints the field console banner'
  assert_grep "wizard_write '> '" "$BF" 'bf-firstboot prompts with the wizard input marker'
  assert_grep '/dev/tty' "$BF" 'bf-firstboot opens /dev/tty when stdin is not a terminal'
  assert_grep '/etc/blueforce/dealer-id' "$BF" 'bf-firstboot supports the seeded dealer id file'
  assert_grep '--offline' "$BF" 'bf-firstboot calls the installer offline-only'
  assert_grep 'blueforce-install.sh' "$BF" 'bf-firstboot targets the local installer'
  assert_grep 'BF_FIRSTBOOT_TEST_MODE' "$BF" 'bf-firstboot keeps the mutation-free test mode'
  assert_grep '--resume' "$BF" 'bf-firstboot resumes a partial install'
  assert_grep '--force-reidentity' "$BF" 'bf-firstboot exposes the admin re-identity path'
  assert_grep 'BF_ALLOW_REIDENTITY' "$BF" 'the re-identity path is gated by an operator switch'
  assert_grep 'already completed' "$BF" 'bf-firstboot short-circuits on the completion marker'

  assert_no_grep 'curl' "$BF" 'bf-firstboot fetches nothing from the network'
  assert_no_grep 'wget' "$BF" 'bf-firstboot does not download via wget'
  assert_no_grep 'set -x' "$BF" 'bf-firstboot never traces (no accidental key dump)'
  if grep -nE '(^|[^A-Za-z_])(cat|tee|head|tail|awk|printf|echo|cp|scp)[[:space:]]+[^|]*\$KEY_FILE' "$BF" >/dev/null 2>&1; then
    bad 'the administrator key file is never read out into a message or a copy'
  else
    ok 'the administrator key file is never read out into a message or a copy'
  fi

  assert_file "$UNIT" 'the first-boot unit is present'
  assert_grep 'ConditionPathExists=/etc/blueforce/admin-authorized-key.pub' "$UNIT" 'the unit requires the administrator public key'
  assert_grep 'ConditionPathExists=!/var/lib/blueforce/firstboot-complete' "$UNIT" 'the unit is skipped once the marker exists'
  assert_grep 'TimeoutStartSec=' "$UNIT" 'the unit bounds its runtime'
  assert_grep 'StandardInput=tty-force' "$UNIT" 'the unit attaches the wizard to the console'
  assert_grep 'Type=oneshot' "$UNIT" 'the unit is a one-shot service'
  assert_grep 'RemainAfterExit=yes' "$UNIT" 'the unit records its result'
  assert_grep 'WantedBy=multi-user.target' "$UNIT" 'the unit runs once at boot'
  assert_no_directive 'ProtectSystem' "$UNIT" 'the unit does not sandbox paths the offline installer must write'
  assert_no_directive 'ProtectHome' "$UNIT" 'the unit keeps /home/blueforce writable for the user module'

  assert_file "$README_FILE" 'the first-boot README is present'
  assert_grep 'BLUEFORCE FIELD OS' "$README_FILE" 'the README documents the wizard screen'
  assert_grep 'force-reidentity' "$README_FILE" 'the README documents the admin identity change procedure'
  assert_grep 'BF_ALLOW_REIDENTITY' "$README_FILE" 'the README documents that identity change is off by default'
  assert_grep 'public SSH key' "$README_FILE" 'the README states the administrator key rule'
  assert_grep '/var/log/blueforce-reidentity.log' "$README_FILE" 'the README documents the identity change audit record'
  assert_grep 'ConditionPathExists' "$README_FILE" 'the README explains the unit conditions'
}

# ---------------------------------------------------------------------------
# Command line behavior: check mode, validation, automation path, no terminal.
# ---------------------------------------------------------------------------
check_cli() {
  section 'cli: validation, check mode, no-terminal fallback'

  new_sandbox
  run_bf bash "$BF" --check --dealer-id 12010193
  assert_rc 0 "$RC" 'check mode accepts a valid dealer number'
  assert_output 'no changes were made' "$OUT" 'check mode reports that it made no changes'
  assert_no_file "$SB/marker" 'check mode writes no marker'
  assert_no_file "$SB/state" 'check mode creates no state directory'
  assert_eq '0' "$(installer_calls)" 'check mode never runs the installer'
  assert_eq 'fake-install.sh,key.pub,' "$(sandbox_listing)" 'check mode leaves the sandbox untouched'

  for candidate in 1234567 123456789 1234abcd '' '12 34 5678'; do
    new_sandbox
    run_bf bash "$BF" --check --dealer-id "$candidate"
    assert_rc 2 "$RC" "invalid dealer number is rejected: '${candidate:-<empty>}'"
    assert_output '8 digits' "$OUT" "rejection of '${candidate:-<empty>}' explains the expected format"
    assert_no_file "$SB/marker" "rejection of '${candidate:-<empty>}' writes no marker"
  done

  new_sandbox
  run_bf bash "$BF" --check
  assert_rc 2 "$RC" 'check mode without any dealer number fails with a clear error'
  assert_no_file "$SB/marker" 'a failed check mode writes no marker'

  new_sandbox
  run_bf bash "$BF" --not-a-flag
  assert_rc 2 "$RC" 'an unknown argument is rejected'
  assert_output 'unknown argument' "$OUT" 'an unknown argument is reported explicitly'

  new_sandbox
  run_bf bash "$BF" --dealer-id 1234567
  assert_rc 2 "$RC" 'a 7-digit dealer number never reaches the installer'
  assert_no_file "$SB/marker" 'a rejected dealer number writes no marker'
  assert_eq '0' "$(installer_calls)" 'a rejected dealer number never runs the installer'

  # Non-interactive mode with no seeded file and no flag must fail closed, without hanging.
  new_sandbox
  run_bf bash "$BF" --non-interactive
  assert_rc 2 "$RC" 'non-interactive mode without any dealer number fails'
  if [[ "$OUT" == *'dealer id file is missing or unreadable'* || "$OUT" == *'invalid dealer number'* ]]; then
    ok 'non-interactive mode names the unusable dealer id input'
  else
    bad 'non-interactive mode names the unusable dealer id input'
  fi
  assert_no_file "$SB/marker" 'the no-input path writes no marker'

  # Explicit file path (automation) is honoured and never opens the wizard.
  new_sandbox
  printf '12010193\n' >"$SB/dealer-id"
  run_bf bash "$BF" --dealer-id-file "$SB/dealer-id"
  assert_no_output '# BLUEFORCE FIELD OS' "$OUT" 'the automation path never opens the wizard'
  assert_no_output '8 Haneli Bayi Numarası' "$OUT" 'the automation path asks nothing at the console'
  assert_eq '0' "$(installer_calls)" 'the automation path runs no installer when it cannot install'
  if [[ "$(id -u)" -eq 0 ]]; then
    assert_rc 0 "$RC" 'the dealer id file path completes when the test runs as root'
  else
    assert_rc 1 "$RC" 'the dealer id file path fails closed without root'
    assert_output 'must run as root' "$OUT" 'the automation path reports the missing privilege'
    assert_no_file "$SB/marker" 'the automation path writes no marker when it cannot install'
  fi

  new_sandbox
  printf 'nope\n' >"$SB/dealer-id"
  run_bf bash "$BF" --dealer-id-file "$SB/dealer-id"
  assert_rc 2 "$RC" 'an invalid value in the dealer id file is rejected'
  assert_output 'invalid dealer number' "$OUT" 'an invalid file value names the format rule'

  new_sandbox
  printf '12010193\n' >"$SB/dealer-id"
  run_bf BF_FIRSTBOOT_NONINTERACTIVE=1 bash "$BF" --dealer-id-file "$SB/dealer-id"
  assert_no_output '# BLUEFORCE FIELD OS' "$OUT" 'explicit non-interactive mode never opens the wizard'
  assert_eq '0' "$(installer_calls)" 'explicit non-interactive mode runs no installer when it cannot install'
}

# ---------------------------------------------------------------------------
# Wizard behavior through a pseudo terminal.
# ---------------------------------------------------------------------------
check_wizard() {
  section 'wizard: pty input, confirmation, attempt limit'

  new_sandbox
  run_bf_tty '1234567
abcd
nope' bash "$BF"
  assert_rc 2 "$RC" 'three malformed entries abort the wizard'
  assert_output '# BLUEFORCE FIELD OS' "$OUT" 'the wizard shows the field console banner'
  assert_output '8 Haneli Bayi Numarası' "$OUT" 'the wizard shows the Turkish dealer number prompt'
  assert_output 'deneme 3/3' "$OUT" 'the wizard counts attempts and never accepts malformed input'
  assert_output 'not accepted after 3 attempts' "$OUT" 'the wizard aborts with an explicit error after the limit'
  assert_no_file "$SB/marker" 'the aborted wizard writes no marker'
  assert_eq '0' "$(installer_calls)" 'the aborted wizard never runs the installer'

  new_sandbox
  run_bf_tty '1201 0193
12010193
e' bash "$BF"
  assert_output 'Geçersiz giriş' "$OUT" 'the wizard rejects a malformed entry that contains a space'
  assert_output 'deneme 1/3' "$OUT" 'the wizard re-asks once a malformed entry is rejected'
  assert_output 'BF-12010193' "$OUT" 'the wizard accepts the corrected entry after a rejection'

  new_sandbox
  run_bf_tty '12010193
e' bash "$BF"
  assert_output 'BF-12010193' "$OUT" 'the confirmed wizard shows Device ID BF-<dealer-id>'
  assert_output 'bf-12010193' "$OUT" 'the confirmed wizard shows hostname bf-<dealer-id>'
  assert_eq '0' "$(installer_calls)" 'the wizard run does not reach the installer without root'
  if [[ "$(id -u)" -eq 0 ]]; then
    assert_rc 0 "$RC" 'the confirmed wizard completes when the test runs as root'
  else
    assert_rc 1 "$RC" 'the confirmed wizard stops at the privilege gate without root'
    assert_output 'must run as root' "$OUT" 'the confirmed wizard proceeds past identity validation'
  fi

  new_sandbox
  run_bf_tty '12010193
n
12010193
n
12010193
n' bash "$BF"
  assert_rc 2 "$RC" 'refusing the confirmation three times aborts the wizard'
  assert_output 'Onay verilmedi' "$OUT" 'the wizard re-asks when the identity is not confirmed'
  assert_eq '0' "$(installer_calls)" 'a refused confirmation never runs the installer'

  new_sandbox
  run_bf_tty_silent bash "$BF"
  assert_rc 2 "$RC" 'a silent console aborts the wizard instead of waiting forever'
  assert_output 'timed out' "$OUT" 'the silent console path explains the timeout'
  assert_eq '0' "$(installer_calls)" 'the silent console path never runs the installer'
}

# ---------------------------------------------------------------------------
# Root-only behavior in a separate user namespace.
# ---------------------------------------------------------------------------
check_root_paths() {
  section 'root (namespace): install run, marker, key gate, re-identity'

  new_sandbox
  run_bf BF_FIRSTBOOT_TEST_MODE=1 bash "$BF" --dealer-id 12010193
  assert_rc 0 "$RC" 'test mode completes successfully as root'
  assert_output "TEST: would run $SB/fake-install.sh --offline --dealer-id 12010193 --yes" "$OUT" 'test mode builds the exact offline installer command'
  assert_no_file "$SB/marker" 'test mode is mutation-free (no marker)'
  assert_eq '0' "$(installer_calls)" 'test mode never runs the installer'

  new_sandbox
  mkdir -p "$SB/state"
  printf '01-precheck=OK\n' >"$SB/state/install-state"
  run_bf BF_FIRSTBOOT_TEST_MODE=1 bash "$BF" --dealer-id 12010193
  assert_rc 0 "$RC" 'a partial install state is accepted'
  assert_output '--resume' "$OUT" 'a partial install is resumed instead of restarted'

  new_sandbox
  run_bf bash "$BF" --dealer-id 12010193
  assert_rc 0 "$RC" 'first boot completes with the (fake) installer'
  assert_file "$SB/marker" 'the completion marker is written'
  assert_eq '600' "$(file_mode "$SB/marker")" 'the marker is mode 600'
  assert_eq '12010193' "$(marker_content)" 'the marker records the provisioned dealer number'
  assert_eq '--offline --dealer-id 12010193 --yes' "$(installer_args)" 'the installer is called offline with the validated dealer number'

  run_bf bash "$BF" --dealer-id 12010193
  assert_rc 0 "$RC" 'a second run exits successfully'
  assert_output 'already completed' "$OUT" 'a provisioned device reports that first boot is done'
  assert_eq '1' "$(installer_calls)" 'a provisioned device never runs the installer again'

  run_bf bash "$BF" --dealer-id 87654321
  assert_rc 0 "$RC" 'a different dealer number does not fail the run'
  assert_output 'identity changes use the admin procedure' "$OUT" 'a different dealer number points at the admin procedure'
  assert_eq '12010193' "$(marker_content)" 'the provisioned identity is unchanged'
  assert_eq '1' "$(installer_calls)" 'the installer is not re-run for a different dealer number'

  run_bf_tty '87654321
e' bash "$BF"
  assert_eq '12010193' "$(marker_content)" 'the wizard cannot change a provisioned identity'
  assert_eq '1' "$(installer_calls)" 'the wizard does not re-run the installer on a provisioned device'

  new_sandbox
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAB3NzaC1yc2EFIRSTBOOTSECRETBODY\n-----END OPENSSH PRIVATE KEY-----\n' >"$SB/priv.key"
  chmod 600 "$SB/priv.key"
  run_bf BF_ADMIN_PUBLIC_KEY_FILE="$SB/priv.key" bash "$BF" --dealer-id 12010193
  assert_rc 1 "$RC" 'private key material is refused as an administrator key'
  assert_output 'must contain only a public SSH key' "$OUT" 'the refusal states the public-key rule'
  assert_no_output 'FIRSTBOOTSECRETBODY' "$OUT" 'no key material is echoed in the error output'
  assert_no_output 'PRIVATE KEY' "$OUT" 'the private key header is never echoed'
  assert_no_file "$SB/marker" 'a refused key writes no marker'
  assert_eq '0' "$(installer_calls)" 'a refused key never runs the installer'

  new_sandbox
  chmod 644 "$SB/key.pub"
  run_bf bash "$BF" --dealer-id 12010193
  assert_rc 1 "$RC" 'a group/world readable administrator key file is refused'
  assert_output 'root-owned' "$OUT" 'the refusal states the ownership and mode rule'
  assert_no_file "$SB/marker" 'a refused key mode writes no marker'

  new_sandbox
  run_bf BF_ADMIN_PUBLIC_KEY_FILE="$SB/missing.pub" bash "$BF" --dealer-id 12010193
  assert_rc 1 "$RC" 'a missing administrator key file blocks the offline install'
  assert_output 'OFFLINE BLOCKED' "$OUT" 'a missing administrator key is reported as an offline block'

  new_sandbox
  run_bf bash "$BF" --check --dealer-id 12010193
  assert_rc 0 "$RC" 'check mode succeeds as root'
  assert_no_file "$SB/marker" 'check mode writes no marker as root'
  assert_no_file "$SB/state" 'check mode creates no state directory as root'
  assert_eq '0' "$(installer_calls)" 'check mode runs no installer as root'
  assert_eq 'fake-install.sh,key.pub,' "$(sandbox_listing)" 'check mode leaves the sandbox untouched as root'

  new_sandbox
  write_marker 12010193
  run_bf bash "$BF" --force-reidentity --dealer-id 55555555
  assert_rc 1 "$RC" 're-identity is refused without the operator gate'
  assert_output 'disabled by default' "$OUT" 'the refusal explains that identity change is off by default'
  assert_eq '12010193' "$(marker_content)" 'a refused re-identity leaves the marker unchanged'
  assert_eq '0' "$(installer_calls)" 'a refused re-identity runs no installer'
  assert_no_file "$SB/audit.log" 'a refused re-identity writes no audit record'

  new_sandbox
  write_marker 12010193
  run_bf_tty '99999999' BF_ALLOW_REIDENTITY=1 bash "$BF" --force-reidentity --dealer-id 55555555
  assert_rc 2 "$RC" 'a mismatching confirmation aborts the identity change'
  assert_output 'confirmation did not match' "$OUT" 'the aborted identity change says why'
  assert_eq '12010193' "$(marker_content)" 'the aborted identity change leaves the marker unchanged'
  assert_eq '0' "$(installer_calls)" 'the aborted identity change runs no installer'

  new_sandbox
  write_marker 12010193
  printf 'not a directory\n' >"$SB/blocker"
  run_bf_tty '55555555' BF_ALLOW_REIDENTITY=1 BF_REIDENTITY_AUDIT_LOG="$SB/blocker/audit.log" bash "$BF" --force-reidentity --dealer-id 55555555
  assert_rc 1 "$RC" 'an unwritable audit log fails the identity change closed'
  assert_output 'audit log is not writable' "$OUT" 'the failure names the unwritable audit log'
  assert_eq '12010193' "$(marker_content)" 'a failed audit leaves the marker unchanged'
  assert_eq '0' "$(installer_calls)" 'a failed audit runs no installer'

  new_sandbox
  write_marker 12010193
  run_bf_tty '55555555' BF_ALLOW_REIDENTITY=1 bash "$BF" --force-reidentity --dealer-id 55555555
  assert_rc 0 "$RC" 'an admitted identity change completes'
  assert_eq '55555555' "$(marker_content)" 'the marker carries the new dealer number'
  assert_eq '--offline --dealer-id 55555555 --yes' "$(installer_args)" 'the installer is re-run with the new dealer number'
  if compgen -G "$SB/marker.reidentified-*" >/dev/null; then
    ok 'the previous identity marker is archived'
  else
    bad 'the previous identity marker is archived'
  fi
  assert_output 'AUDIT: identity-change applied' "$OUT" 'the identity change is announced in the run log'
  assert_file "$SB/audit.log" 'the identity change writes an audit record'
  assert_eq '600' "$(file_mode "$SB/audit.log")" 'the audit record is mode 600'
  assert_grep 'identity-change applied old=12010193 new=BF-55555555' "$SB/audit.log" 'the audit record names the old and the new identity'

  new_sandbox
  run_bf_tty '12010193
e' bash "$BF"
  assert_rc 0 "$RC" 'the wizard completes the first boot as root'
  assert_output '# BLUEFORCE FIELD OS' "$OUT" 'the interactive run shows the banner'
  assert_output 'BF-12010193' "$OUT" 'the interactive run shows the Device ID'
  assert_eq '12010193' "$(marker_content)" 'the interactive run writes the marker for the confirmed identity'
  assert_eq '--offline --dealer-id 12010193 --yes' "$(installer_args)" 'the interactive run calls the installer offline'
}

if [[ -n "${BF_TEST_RESULTS:-}" ]]; then
  # Child mode: only the root-required scenarios run; results go to the parent's file.
  cd "$REPO_ROOT"
  check_root_paths
  exit 0
fi

check_sources
check_cli
check_wizard

section 'root (namespace): install run, marker, key gate, re-identity'
RESULTS_FILE="$WORK/root-results.tsv"
: >"$RESULTS_FILE"
if unshare -r true >/dev/null 2>&1 && [[ "$(unshare -r id -u 2>/dev/null)" == 0 ]]; then
  CHILD_LOG="$WORK/child.log"
  if unshare -r env BF_TEST_RESULTS="$RESULTS_FILE" bash "$TEST_SCRIPT" >"$CHILD_LOG" 2>&1; then
    :
  else
    printf 'FAIL the privileged (namespace) section did not complete; see the log below\n' >&2
    sed -n '1,20p' "$CHILD_LOG" >&2
    FAILED=$((FAILED + 1))
  fi
  if [[ -s "$RESULTS_FILE" ]]; then
    while IFS=$'\t' read -r status name; do
      case "$status" in
        PASS) ok "$name";;
        SKIP) skip "$name";;
        *) bad "$name";;
      esac
    done <"$RESULTS_FILE"
  else
    skip 'the privileged (namespace) section produced no results'
  fi
else
  skip 'unshare -r is unavailable here: root-only first-boot scenarios were not run'
fi

printf '\ntest-firstboot-static: %s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
if [[ "$FAILED" -ne 0 ]]; then
  printf 'test-firstboot-static: FAILED\n' >&2
  exit 1
fi
printf 'test-firstboot-static: all passed\n'
