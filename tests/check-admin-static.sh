#!/usr/bin/env bash
#
# Static + behavioural contract tests for the git-based bootstrap and the
# optional credential tool:
#
#   admin/bf-bootstrap.sh   one-command install from git
#   admin/bf-creds          optional, default-OFF credential generation/delivery
#   admin/lib/creds.sh      shared helpers
#
# Everything here is mock/sandboxed: no network, no real apt, no root, and no
# write outside a mktemp sandbox. The bootstrap apply path is exercised with
# `id` and `apt-get` shims placed first in PATH, every PATH entry providing
# ansible-playbook removed (so the dependency branch runs deterministically and
# still only reaches the apt-get shim), and BF_INSTALL_DIR / BF_BIN_DIR /
# BF_REPO_URL pointed at the sandbox — a real package install or a real
# /usr/local/bin link can never happen from this suite.
#
# Every load-bearing check is paired with a negative control: the same
# predicate is run against a deliberately broken copy and MUST trip, so a
# check that has quietly stopped testing anything fails the suite instead of
# passing silently.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$REPO_ROOT/admin/bf-bootstrap.sh"
CREDS="$REPO_ROOT/admin/bf-creds"
CREDS_LIB="$REPO_ROOT/admin/lib/creds.sh"
GITIGNORE="$REPO_ROOT/.gitignore"

FAIL=0
CHECKS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
pass() { printf 'OK: %s\n' "$*"; }
note() { printf 'NOTE: %s\n' "$*"; }
check() { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-admin.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# Predicates and assertion helpers.
# --------------------------------------------------------------------------- #
has() { [[ -f "$1" ]] && grep -qE -- "$2" "$1"; }
lacks() { [[ -f "$1" ]] && ! grep -qE -- "$2" "$1"; }
# Case-insensitive variants, used for the secret-material scan (a planted
# `DEMO_TOKEN=...` must be found just like a lowercase one).
has_i() { [[ -f "$1" ]] && grep -qiE -- "$2" "$1"; }
lacks_i() { [[ -f "$1" ]] && ! grep -qiE -- "$2" "$1"; }

# contract <desc> <file> <predicate> <regex>   -- the predicate must hold.
contract() {
    check
    if "$3" "$2" "$4"; then
        pass "$1"
    else
        fail "$1 [file=${2#"$REPO_ROOT"/} pattern=$4]"
    fi
}

# control <desc> <broken-file> <predicate> <regex> -- the predicate must NOT hold.
control() {
    check
    if "$3" "$2" "$4"; then
        fail "negative control did not trip: $1"
    else
        pass "negative control trips: $1"
    fi
}

expect_rc() { # <desc> <expected-rc> <actual-rc>
    check
    if [[ "$2" -eq "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected exit $2, got $3)"
    fi
}

expect_absent() { # <desc> <path>
    check
    if [[ ! -e "$2" ]]; then
        pass "$1"
    else
        fail "$1 (path exists: $2)"
    fi
}

expect_present() { # <desc> <path>
    check
    if [[ -e "$2" ]]; then
        pass "$1"
    else
        fail "$1 (path missing: $2)"
    fi
}

expect_mode() { # <desc> <path> <mode>
    check
    local mode=""
    mode="$(stat -c '%a' "$2" 2>/dev/null || true)"
    if [[ "$mode" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (mode is '${mode:-missing}', expected $3)"
    fi
}

expect_contains() { # <desc> <file> <literal>
    check
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        pass "$1"
    else
        fail "$1 (literal not found: $3)"
    fi
}

expect_absent_text() { # <desc> <file> <literal>
    check
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        fail "$1 (literal found: $3)"
    else
        pass "$1"
    fi
}

# secret_leaked <output-file> <secret>  -- 0 when the secret is visible.
# This is the leak detector used for the generated credential; its negative
# control below proves it can actually find a secret.
secret_leaked() { grep -qF -- "$2" "$1" 2>/dev/null; }

# --------------------------------------------------------------------------- #
# 1. Presence, shebang, strict mode, syntax.
# --------------------------------------------------------------------------- #
for target in "$BOOTSTRAP" "$CREDS" "$CREDS_LIB"; do
    check
    if [[ -f "$target" ]]; then
        pass "present: ${target#"$REPO_ROOT"/}"
    else
        fail "missing: ${target#"$REPO_ROOT"/}"
    fi
done

for target in "$BOOTSTRAP" "$CREDS" "$CREDS_LIB"; do
    [[ -f "$target" ]] || continue
    name="${target#"$REPO_ROOT"/}"
    check
    if [[ "$(head -n 1 "$target")" == '#!/usr/bin/env bash' ]]; then
        pass "bash shebang: $name"
    else
        fail "bash shebang missing: $name"
    fi
    check
    if grep -q '^set -euo pipefail$' "$target"; then
        pass "strict mode (set -euo pipefail): $name"
    else
        fail "strict mode missing: $name"
    fi
    check
    if bash -n "$target" 2>/dev/null; then
        pass "bash parses: $name"
    else
        fail "bash parse error: $name"
    fi
done

# The two entry points are invoked directly and symlinked into /usr/local/bin.
for target in "$BOOTSTRAP" "$CREDS"; do
    [[ -f "$target" ]] || continue
    check
    if [[ -x "$target" ]]; then
        pass "executable bit: ${target#"$REPO_ROOT"/}"
    else
        fail "not executable: ${target#"$REPO_ROOT"/}"
    fi
done

# Negative control for the syntax gate: a broken script must be rejected.
printf '#!/usr/bin/env bash\nif true; then\n' > "$WORK/broken.sh"
check
if bash -n "$WORK/broken.sh" 2>/dev/null; then
    fail 'negative control did not trip: bash -n accepted broken syntax'
else
    pass 'negative control trips: bash -n rejects broken syntax'
fi

# --------------------------------------------------------------------------- #
# 2. --help works and documents the documented interface.
# --------------------------------------------------------------------------- #
check
if bash "$BOOTSTRAP" --help > "$WORK/bootstrap-help.out" 2>&1; then
    pass 'bf-bootstrap.sh --help exits 0'
else
    fail 'bf-bootstrap.sh --help failed'
fi
for flag in '--check' '--dir' '--branch' '--yes'; do
    contract "bf-bootstrap --help documents $flag" "$WORK/bootstrap-help.out" has "\\${flag}"
done

check
if bash "$CREDS" --help > "$WORK/creds-help.out" 2>&1; then
    pass 'bf-creds --help exits 0'
else
    fail 'bf-creds --help failed'
fi
for flag in '--generate' '--fetch' '--repo' '--dealer-id'; do
    contract "bf-creds --help documents $flag" "$WORK/creds-help.out" has "\\${flag}"
done

# Unknown arguments are refused with exit 2 (and never mutate anything).
set +e
bash "$BOOTSTRAP" --definitely-not-a-flag > "$WORK/bootstrap-bad.out" 2>&1
bootstrap_bad_rc=$?
bash "$CREDS" --definitely-not-a-flag > "$WORK/creds-bad.out" 2>&1
creds_bad_rc=$?
set -e
expect_rc 'bf-bootstrap.sh rejects an unknown argument with exit 2' 2 "$bootstrap_bad_rc"
expect_rc 'bf-creds rejects an unknown argument with exit 2' 2 "$creds_bad_rc"

# --------------------------------------------------------------------------- #
# 3. bf-bootstrap.sh static contracts (+ negative controls).
# --------------------------------------------------------------------------- #
contract 'bf-bootstrap checks for root before mutating' "$BOOTSTRAP" has 'id -u'
contract 'bf-bootstrap installs prerequisites with apt-get' "$BOOTSTRAP" has 'apt-get install'
contract 'bf-bootstrap prepares git/curl/ansible-core' "$BOOTSTRAP" has 'ansible-playbook'
contract 'bf-bootstrap clones the repository' "$BOOTSTRAP" has 'git clone'
contract 'bf-bootstrap updates an existing checkout fast-forward only' "$BOOTSTRAP" has 'merge --ff-only'
contract 'bf-bootstrap never rewrites the checkout history' "$BOOTSTRAP" lacks 'reset --hard|git clean'
contract 'bf-bootstrap links tools into /usr/local/bin' "$BOOTSTRAP" has '/usr/local/bin'
contract 'bf-bootstrap links idempotently' "$BOOTSTRAP" has 'ln -sfn'
contract 'bf-bootstrap discovers the admin tools' "$BOOTSTRAP" has 'admin/bf-\*'
contract 'bf-bootstrap discovers the diagnostics tools' "$BOOTSTRAP" has 'scripts/diagnostics/bf-\*'
contract 'bf-bootstrap discovers the maintenance tools' "$BOOTSTRAP" has 'scripts/maintenance/bf-\*'
contract 'bf-bootstrap wires up bf-menu' "$BOOTSTRAP" has 'bf-menu'
contract 'bf-bootstrap supports Ubuntu 24.04' "$BOOTSTRAP" has '24\.04'
contract 'bf-bootstrap supports Ubuntu 26.04' "$BOOTSTRAP" has '26\.04'
contract 'bf-bootstrap has a read-only check mode' "$BOOTSTRAP" has 'CHECK_MODE'
contract 'bf-bootstrap prints the completion contract' "$BOOTSTRAP" has 'Kurulum tamam\. Başlamak için: sudo bf'
contract 'bf-bootstrap carries no private key material' "$BOOTSTRAP" lacks 'BEGIN [A-Z ]*PRIVATE KEY'
contract 'bf-bootstrap generates no WireGuard key' "$BOOTSTRAP" lacks 'wg genkey'

# Negative controls: break each load-bearing property and prove the check trips.
sed -E 's#/usr/local/bin#/usr/bin#g' "$BOOTSTRAP" > "$WORK/b-ins-local-bin.sh"
chmod 0755 "$WORK/b-ins-local-bin.sh"
control 'bf-bootstrap target directory is checked' "$WORK/b-ins-local-bin.sh" has '/usr/local/bin'

sed -E 's#merge --ff-only#reset --hard#g' "$BOOTSTRAP" > "$WORK/b-reset.sh"
chmod 0755 "$WORK/b-reset.sh"
control 'bf-bootstrap fast-forward requirement is checked' "$WORK/b-reset.sh" has 'merge --ff-only'
control 'bf-bootstrap history-rewrite ban is checked' "$WORK/b-reset.sh" lacks 'reset --hard|git clean'

sed -E 's#id -u#true#g' "$BOOTSTRAP" > "$WORK/b-no-root.sh"
chmod 0755 "$WORK/b-no-root.sh"
control 'bf-bootstrap root check is checked' "$WORK/b-no-root.sh" has 'id -u'

sed -E '/Kurulum tamam/d' "$BOOTSTRAP" > "$WORK/b-no-summary.sh"
chmod 0755 "$WORK/b-no-summary.sh"
control 'bf-bootstrap completion contract is checked' "$WORK/b-no-summary.sh" has 'Kurulum tamam\. Başlamak için: sudo bf'

# --------------------------------------------------------------------------- #
# 4. bf-bootstrap.sh runtime: --check is mutation-free, apply mode works.
# --------------------------------------------------------------------------- #
# A sandbox PATH shim: `id` reports uid 0 (so the apply path can run unprivileged
# inside the sandbox) and `apt-get` only records the call. Nothing else changes.
SHIM="$WORK/shims"
mkdir -p "$SHIM"
cat > "$SHIM/id" <<'SHIMEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then printf '0\n'; exit 0; fi
printf 'uid=0(root) gid=0(root) groups=0(root)\n'
SHIMEOF
cat > "$SHIM/apt-get" <<'SHIMEOF'
#!/usr/bin/env bash
printf 'shim apt-get: %s\n' "$*" >> "${BF_SHIM_APT_LOG:-/dev/null}"
exit 0
SHIMEOF
chmod 0755 "$SHIM/id" "$SHIM/apt-get"

# Deterministic dependency-install branch: drop every PATH entry that provides
# ansible-playbook, so the bootstrap really sees a missing prerequisite and
# takes its apt-get path (against the shim, never the real package manager).
# git and curl must stay resolvable; when they would be filtered out too, the
# unmodified PATH is kept and the assertion below falls back to a note.
PATH_NO_ANSIBLE=""
while IFS= read -r path_dir; do
    [[ -z "$path_dir" ]] && continue
    [[ -x "$path_dir/ansible-playbook" ]] && continue
    PATH_NO_ANSIBLE="${PATH_NO_ANSIBLE:+$PATH_NO_ANSIBLE:}$path_dir"
done < <(printf '%s\n' "$PATH" | tr ':' '\n')
APPLY_PATH="$SHIM:$PATH_NO_ANSIBLE"
if ! PATH="$APPLY_PATH" command -v git >/dev/null 2>&1 || ! PATH="$APPLY_PATH" command -v curl >/dev/null 2>&1; then
    APPLY_PATH="$SHIM:$PATH"
fi

bootstrap_apply() { # <checkout-dir> <bin-dir> <out-file> <apt-log>
    PATH="$APPLY_PATH" \
    BF_SHIM_APT_LOG="$4" \
    BF_BIN_DIR="$2" \
    BF_INSTALL_DIR="$1" \
    BF_REPO_URL="$REPO_ROOT" \
    bash "$BOOTSTRAP" --yes < /dev/null > "$3" 2>&1
}

# 4a. --check must create nothing at all, even under a full sandbox prefix.
CHECK_ROOT="$WORK/check-root"
set +e
PATH="$APPLY_PATH" \
BF_BIN_DIR="$CHECK_ROOT/bin" \
BF_INSTALL_DIR="$CHECK_ROOT/checkout" \
BF_REPO_URL="$REPO_ROOT" \
bash "$BOOTSTRAP" --check < /dev/null > "$WORK/check.out" 2>&1
check_rc=$?
set -e
expect_rc 'bf-bootstrap --check exits 0' 0 "$check_rc"
expect_absent 'bf-bootstrap --check creates no checkout' "$CHECK_ROOT/checkout"
expect_absent 'bf-bootstrap --check creates no bin directory' "$CHECK_ROOT/bin"
expect_absent 'bf-bootstrap --check creates nothing under its target prefix' "$CHECK_ROOT"
expect_contains 'bf-bootstrap --check reports that nothing was changed' "$WORK/check.out" 'no changes were made'
if PATH="$APPLY_PATH" command -v ansible-playbook >/dev/null 2>&1; then
    note 'ansible-playbook resolves even after PATH filtering: the dependency-plan assertion is limited to the static contract'
else
    expect_contains 'check mode reports the dependency install it would perform' "$WORK/check.out" 'would install with apt-get'
fi

# 4b. --check against the real checkout must install nothing and must discover
#     the admin tools (this is the only non-sandboxed run in the suite).
local_bin_before="$(ls -1 /usr/local/bin 2>/dev/null | sort | tr '\n' ' ')"
mode_before="$(stat -c '%a' "$BOOTSTRAP" "$CREDS" 2>/dev/null | tr '\n' ' ')"
set +e
bash "$BOOTSTRAP" --check < /dev/null > "$WORK/check-repo.out" 2>&1
check_repo_rc=$?
set -e
expect_rc 'bf-bootstrap --check runs unprivileged against the checkout' 0 "$check_repo_rc"
expect_contains 'check mode reports admin/bf-bootstrap.sh as a tool' "$WORK/check-repo.out" 'admin/bf-bootstrap.sh'
expect_contains 'check mode reports admin/bf-creds as a tool' "$WORK/check-repo.out" 'admin/bf-creds'
expect_contains 'check mode reports a diagnostics tool' "$WORK/check-repo.out" 'scripts/diagnostics/bf-status'
check
if [[ "$local_bin_before" == "$(ls -1 /usr/local/bin 2>/dev/null | sort | tr '\n' ' ')" ]]; then
    pass 'bf-bootstrap --check installs nothing into /usr/local/bin'
else
    fail 'bf-bootstrap --check wrote into /usr/local/bin'
fi
check
if [[ "$mode_before" == "$(stat -c '%a' "$BOOTSTRAP" "$CREDS" 2>/dev/null | tr '\n' ' ')" ]]; then
    pass 'bf-bootstrap --check leaves tool modes unchanged'
else
    fail 'bf-bootstrap --check changed tool modes'
fi

# 4c. Harness self-test: prove the "nothing was created" assertion can detect a
#     mutation, so 4a is not a vacuous pass. A synthetic probe that only creates
#     its target when check mode is bypassed must trip the very same assertion.
PROBE="$WORK/probe.sh"
cat > "$PROBE" <<'PROBEEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--check" ]]; then
    printf 'check only\n'
    exit 0
fi
mkdir -p "$2"
printf 'created\n' > "$2/marker"
PROBEEOF
probe_ok="$WORK/probe-ok"
set +e
bash "$PROBE" --check "$probe_ok" >/dev/null 2>&1
set -e
expect_absent 'harness self-test: the probe creates nothing in check mode' "$probe_ok"
sed -E 's#--check#--never#g' "$PROBE" > "$WORK/probe-broken.sh"
probe_broken="$WORK/probe-broken"
set +e
bash "$WORK/probe-broken.sh" --check "$probe_broken" >/dev/null 2>&1
set -e
expect_present 'harness self-test control: the same assertion detects a mutation' "$probe_broken/marker"

# 4d. Apply mode in the sandbox (fresh clone path).
APPLY_ROOT="$WORK/apply-root"
mkdir -p "$APPLY_ROOT"
set +e
bootstrap_apply "$APPLY_ROOT/checkout" "$APPLY_ROOT/bin" "$WORK/apply1.out" "$WORK/apt1.log"
apply_rc=$?
set -e
expect_rc 'bf-bootstrap apply mode exits 0 in the sandbox' 0 "$apply_rc"
expect_present 'bf-bootstrap cloned the repository' "$APPLY_ROOT/checkout/.git"
expect_present 'bf-bootstrap linked a diagnostics tool' "$APPLY_ROOT/bin/bf-status"
expect_contains 'bf-bootstrap prints the completion contract' "$WORK/apply1.out" 'Kurulum tamam. Başlamak için: sudo bf'
expect_contains 'bf-bootstrap reports the repository in its summary' "$WORK/apply1.out" "$APPLY_ROOT/checkout"
expect_contains 'bf-bootstrap warns when the Python console is not in the clone' "$WORK/apply1.out" 'admin/bf is not present'
linked1="$(find "$APPLY_ROOT/bin" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
check
if [[ "$linked1" -ge 10 ]]; then
    pass "bf-bootstrap linked the tool set ($linked1 links)"
else
    fail "bf-bootstrap linked too few tools ($linked1 links)"
fi
# The dependency branch runs against the apt-get shim, never the real apt.
if PATH="$APPLY_PATH" command -v ansible-playbook >/dev/null 2>&1; then
    note 'ansible-playbook resolves even after PATH filtering: the dependency-install assertion is skipped'
else
    expect_contains 'dependency install goes through apt' "$WORK/apt1.log" 'install -y --no-install-recommends'
    expect_contains 'the package list names the missing prerequisite' "$WORK/apt1.log" 'ansible-core'
fi

# 4e. Idempotency: a second apply run must succeed and keep the same links.
set +e
bootstrap_apply "$APPLY_ROOT/checkout" "$APPLY_ROOT/bin" "$WORK/apply2.out" "$WORK/apt2.log"
apply2_rc=$?
set -e
expect_rc 'bf-bootstrap apply mode is idempotent on re-run' 0 "$apply2_rc"
linked2="$(find "$APPLY_ROOT/bin" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
check
if [[ "$linked1" == "$linked2" ]]; then
    pass "re-run keeps the same tool set ($linked2 links)"
else
    fail "re-run changed the tool set ($linked1 -> $linked2 links)"
fi

# 4f. An existing checkout is refreshed, not reset: local changes are reported
#     and preserved, and admin/bf-* tools are linked from it.
SEEDED="$WORK/seeded"
git clone --quiet "$REPO_ROOT" "$SEEDED"
cp -a "$REPO_ROOT/admin" "$SEEDED/admin"
set +e
bootstrap_apply "$SEEDED" "$WORK/seeded-bin" "$WORK/apply3.out" "$WORK/apt3.log"
apply3_rc=$?
set -e
expect_rc 'bf-bootstrap apply mode accepts an existing checkout' 0 "$apply3_rc"
expect_present 'bf-bootstrap linked admin/bf-bootstrap.sh' "$WORK/seeded-bin/bf-bootstrap.sh"
expect_present 'bf-bootstrap linked admin/bf-creds' "$WORK/seeded-bin/bf-creds"
expect_contains 'bf-bootstrap reports local changes instead of resetting them' "$WORK/apply3.out" 'local changes present'
expect_present 'bf-bootstrap left the existing checkout intact' "$SEEDED/admin/bf-creds"

# 4g. Apply mode without root must refuse before touching anything.
if [[ "$(id -u)" -ne 0 ]]; then
    ROOT_TARGET="$WORK/root-target"
    set +e
    BF_BIN_DIR="$WORK/root-bin" \
    BF_INSTALL_DIR="$ROOT_TARGET" \
    BF_REPO_URL="$REPO_ROOT" \
    bash "$BOOTSTRAP" --yes < /dev/null > "$WORK/root.out" 2>&1
    root_rc=$?
    set -e
    expect_rc 'bf-bootstrap refuses to apply without root' 1 "$root_rc"
    expect_contains 'bf-bootstrap explains the root requirement' "$WORK/root.out" 'must run as root'
    expect_absent 'the refused run created no checkout' "$ROOT_TARGET"
    expect_absent 'the refused run created no bin directory' "$WORK/root-bin"
else
    note 'running as root: the unprivileged refusal control is skipped'
fi

# 4h. A target directory that is not a git checkout must be refused untouched.
NOT_A_REPO="$WORK/not-a-repo"
mkdir -p "$NOT_A_REPO"
printf 'keep me\n' > "$NOT_A_REPO/precious.txt"
set +e
PATH="$SHIM:$PATH" \
BF_BIN_DIR="$WORK/not-a-repo-bin" \
BF_INSTALL_DIR="$NOT_A_REPO" \
BF_REPO_URL="$REPO_ROOT" \
bash "$BOOTSTRAP" --yes < /dev/null > "$WORK/not-a-repo.out" 2>&1
not_a_repo_rc=$?
set -e
expect_rc 'bf-bootstrap refuses a directory that is not a git checkout' 1 "$not_a_repo_rc"
expect_contains 'the refusal is explained' "$WORK/not-a-repo.out" 'not a git checkout'
expect_present 'the foreign directory was left untouched' "$NOT_A_REPO/precious.txt"

# --------------------------------------------------------------------------- #
# 5. bf-creds static contracts (+ negative controls).
# --------------------------------------------------------------------------- #
contract 'bf-creds is default-OFF by default' "$CREDS" has 'BF_GENERATE_CREDENTIALS:-0'
contract 'bf-creds has no default-ON regression' "$CREDS" lacks 'BF_GENERATE_CREDENTIALS:-1'
contract 'bf-creds accepts the explicit --generate opt-in' "$CREDS" has 'GENERATE=1'
contract 'bf-creds accepts the explicit --fetch opt-in' "$CREDS" has 'FETCH=1'
contract 'bf-creds marks generation disabled by default' "$CREDS" has 'DISABLED'
contract 'bf-creds never enables shell tracing' "$CREDS" lacks 'set -x'
contract 'bf-creds writes the record at mode 0600' "$CREDS_LIB" has 'BF_CREDENTIALS_MODE:=600'
contract 'bf-creds keeps the delivery path at admin/secrets' "$CREDS_LIB" has 'BF_SECRETS_SUBDIR:=admin/secrets'
contract 'bf-creds reports the WireGuard private key path only' "$CREDS" has 'private_key_path'
contract 'bf-creds documents that the SSH decision is unchanged' "$CREDS" has 'PasswordAuthentication no'
contract 'creds.sh forces 0600 on the written file' "$CREDS_LIB" has 'install -m "\$BF_CREDENTIALS_MODE"'
contract 'creds.sh forces 0700 on the delivery directory' "$CREDS_LIB" has 'install -d -m "\$BF_SECRETS_DIR_MODE"'
contract 'creds.sh refuses to write through a symlink' "$CREDS_LIB" has 'refusing to write through a symlink'
contract 'creds.sh never enables shell tracing' "$CREDS_LIB" lacks 'set -x'

# Mutation builder for bf-creds copies: the tool sources lib/creds.sh relative
# to its own real path, so a mutant needs a lib/ directory beside it.
creds_mutant() { # <name> <awk-program-file>
    local dir="$WORK/mut-$1"
    mkdir -p "$dir/lib"
    ln -sfn "$CREDS_LIB" "$dir/lib/creds.sh"
    awk -f "$2" "$CREDS" > "$dir/bf-creds"
    chmod 0755 "$dir/bf-creds"
    printf '%s' "$dir/bf-creds"
}

# Negative control: a default-ON variant must trip both default-off checks.
cat > "$WORK/default-on.awk" <<'AWKEOF'
{ gsub(/BF_GENERATE_CREDENTIALS:-0/, "BF_GENERATE_CREDENTIALS:-1"); print }
AWKEOF
DEFAULT_ON="$(creds_mutant default-on "$WORK/default-on.awk")"
control 'bf-creds default-off contract is checked' "$DEFAULT_ON" has 'BF_GENERATE_CREDENTIALS:-0'
control 'bf-creds default-ON ban is checked' "$DEFAULT_ON" lacks 'BF_GENERATE_CREDENTIALS:-1'

# Negative control: shell tracing (which would print secrets) must trip the ban.
mkdir -p "$WORK/mut-xtrace/lib"
ln -sfn "$CREDS_LIB" "$WORK/mut-xtrace/lib/creds.sh"
awk '{ print } END { print "set -x" }' "$CREDS" > "$WORK/mut-xtrace/bf-creds"
chmod 0755 "$WORK/mut-xtrace/bf-creds"
control 'bf-creds shell-tracing ban is checked' "$WORK/mut-xtrace/bf-creds" lacks 'set -x'

# Negative control: a leak of the generated secret must trip the leak detector.
cat > "$WORK/leak.awk" <<'AWKEOF'
/cannot generate a random secret/ {
    print
    print "    printf \"leaked-credential=%s\\n\" \"$password\""
    next
}
{ print }
AWKEOF
LEAK_MUTANT="$(creds_mutant leak "$WORK/leak.awk")"

# --------------------------------------------------------------------------- #
# 6. bf-creds runtime in a sandbox (identity, default-off, generate, fetch).
# --------------------------------------------------------------------------- #
CSB="$WORK/creds-sandbox"
mkdir -p "$CSB/wg"
FAKE_WG_PRIVATE='FAKEWGPRIVATE0000000000000000000000000000000='
FAKE_WG_PUBLIC='FAKEWGPUBLIC1111111111111111111111111111111='
FAKE_RUSTDESK='987654321'
printf '%s\n' "$FAKE_WG_PUBLIC" > "$CSB/wg/publickey"
printf '%s\n' "$FAKE_WG_PRIVATE" > "$CSB/wg/privatekey"
chmod 0600 "$CSB/wg/privatekey"
printf '%s\n' "$FAKE_RUSTDESK" > "$CSB/rustdesk-id"
printf '{ "phase": "PROVISIONED_OFFLINE", "device_id": "BF-12345678" }\n' > "$CSB/state.json"

CREDS_FILE="$CSB/credentials.txt"
CREDS_STATE_FILE="$CSB/state.json"
CREDS_DEVICE='BF-12345678'

# creds_env <script> <out-file> [args...]
creds_env() {
    local script="$1" out="$2"
    shift 2
    BF_STATE_FILE="${CREDS_STATE_FILE:-$CSB/state.json}" \
    BF_DEVICE="${CREDS_DEVICE-}" \
    BF_WG_DIR="$CSB/wg" \
    BF_RUSTDESK_ID_FILE="$CSB/rustdesk-id" \
    BF_CREDENTIALS_FILE="$CREDS_FILE" \
    bash "$script" "$@" > "$out" 2>&1
}

# 6a. Default behaviour: report only, no generation, and it says so.
CREDS_FILE="$CSB/default-run.txt"
set +e
creds_env "$CREDS" "$WORK/creds-default.out"
default_rc=$?
set -e
expect_rc 'bf-creds default run exits 0' 0 "$default_rc"
expect_absent 'bf-creds default run generates no credential file' "$CREDS_FILE"
expect_contains 'bf-creds states that generation is disabled by default' "$WORK/creds-default.out" 'DISABLED'
expect_contains 'bf-creds states that no password was generated' "$WORK/creds-default.out" 'no password was generated'
expect_absent_text 'bf-creds default run prints no credential line' "$WORK/creds-default.out" 'local_administrator_password'
expect_contains 'bf-creds reports the device identity' "$WORK/creds-default.out" 'device_id        : BF-12345678'
expect_contains 'bf-creds reports the WireGuard public key' "$WORK/creds-default.out" "$FAKE_WG_PUBLIC"
expect_contains 'bf-creds reports the private key path' "$WORK/creds-default.out" "$CSB/wg/privatekey"
expect_contains 'bf-creds reports the RustDesk ID' "$WORK/creds-default.out" "$FAKE_RUSTDESK"

# Negative control for the default-off behaviour: the default-ON mutant must
# create the credential file without any flag, proving 6a is not vacuous.
CREDS_FILE="$WORK/default-on-run.txt"
set +e
creds_env "$DEFAULT_ON" "$WORK/creds-default-on.out"
set -e
expect_present 'control: the default-ON mutant generates without a flag' "$CREDS_FILE"

# 6b. --generate writes the record, and the secret never reaches stdout.
CREDS_FILE="$CSB/credentials.txt"
set +e
creds_env "$CREDS" "$WORK/creds-generate.out" --generate
generate_rc=$?
set -e
expect_rc 'bf-creds --generate exits 0' 0 "$generate_rc"
expect_present 'bf-creds --generate writes the credential record' "$CREDS_FILE"
expect_mode 'the credential record is mode 600' "$CREDS_FILE" 600
expect_contains 'the record carries the device id' "$CREDS_FILE" 'device_id: BF-12345678'
expect_contains 'the record carries the dealer number' "$CREDS_FILE" 'dealer_number: 12345678'
expect_contains 'the record carries the hostname' "$CREDS_FILE" 'hostname:'
expect_contains 'the record carries the creation time' "$CREDS_FILE" 'generated_at:'
expect_contains 'the record carries the WireGuard public key' "$CREDS_FILE" "$FAKE_WG_PUBLIC"
expect_contains 'the record carries the private key path' "$CREDS_FILE" "$CSB/wg/privatekey"
expect_contains 'the record states the private key is not recorded' "$CREDS_FILE" 'NOT RECORDED'
expect_absent_text 'the record never contains the WireGuard private key value' "$CREDS_FILE" "$FAKE_WG_PRIVATE"
expect_absent_text 'stdout never contains the WireGuard private key value' "$WORK/creds-generate.out" "$FAKE_WG_PRIVATE"
expect_contains 'stdout names the credential record' "$WORK/creds-generate.out" "$CREDS_FILE"
expect_contains 'stdout confirms the record was written' "$WORK/creds-generate.out" 'written'

GENERATED_PASSWORD="$(sed -n 's/^local_administrator_password:[[:space:]]*//p' "$CREDS_FILE" | head -n 1)"
check
if [[ ${#GENERATED_PASSWORD} -ge 16 ]]; then
    pass "the generated password is long enough (${#GENERATED_PASSWORD} characters)"
else
    fail "the generated password is too short (${#GENERATED_PASSWORD} characters)"
fi
check
if secret_leaked "$WORK/creds-generate.out" "$GENERATED_PASSWORD"; then
    fail 'the generated password leaked to stdout'
else
    pass 'the generated password never reaches stdout'
fi
check
if secret_leaked "$WORK/creds-generate.out" "$FAKE_WG_PRIVATE"; then
    fail 'the WireGuard private key leaked to stdout'
else
    pass 'the WireGuard private key never reaches stdout'
fi

# Negative control for the leak detector: the leak mutant must be detected.
CREDS_FILE="$WORK/leak-run.txt"
set +e
creds_env "$LEAK_MUTANT" "$WORK/creds-leak.out" --generate
set -e
LEAKED_PASSWORD="$(sed -n 's/^local_administrator_password:[[:space:]]*//p' "$CREDS_FILE" | head -n 1)"
check
if [[ -n "$LEAKED_PASSWORD" ]] && secret_leaked "$WORK/creds-leak.out" "$LEAKED_PASSWORD"; then
    pass 'control: the leak detector finds a secret that is printed'
else
    fail 'control: the leak detector did not find a printed secret (vacuous check)'
fi

# 6c. --fetch delivers the record next to the checkout at 0600/0700.
FETCH_REPO="$WORK/fetch-repo"
mkdir -p "$FETCH_REPO"
CREDS_FILE="$CSB/credentials.txt"
set +e
creds_env "$CREDS" "$WORK/creds-fetch.out" --fetch --repo "$FETCH_REPO"
fetch_rc=$?
set -e
FETCH_DEST="$FETCH_REPO/admin/secrets/12345678.txt"
expect_rc 'bf-creds --fetch exits 0' 0 "$fetch_rc"
expect_present 'bf-creds --fetch delivers the credential file' "$FETCH_DEST"
expect_mode 'the delivered file is mode 600' "$FETCH_DEST" 600
expect_mode 'the delivery directory is mode 700' "$FETCH_REPO/admin/secrets" 700
check
if cmp -s "$CSB/credentials.txt" "$FETCH_DEST"; then
    pass 'the delivered file matches the credential record'
else
    fail 'the delivered file differs from the credential record'
fi
expect_contains '--fetch reports only the delivery path' "$WORK/creds-fetch.out" "$FETCH_DEST"
expect_absent_text '--fetch never prints the generated password' "$WORK/creds-fetch.out" "$GENERATED_PASSWORD"
expect_absent_text '--fetch never prints the WireGuard private key' "$WORK/creds-fetch.out" "$FAKE_WG_PRIVATE"

# 6d. --fetch fails closed when the dealer number cannot be determined.
CREDS_FILE="$WORK/no-device/credentials.txt"
mkdir -p "$WORK/no-device"
cp "$CSB/credentials.txt" "$CREDS_FILE"
CREDS_STATE_FILE="$WORK/absent-state.json"
CREDS_DEVICE=''
set +e
creds_env "$CREDS" "$WORK/creds-nodevice.out" --fetch --repo "$FETCH_REPO"
nodevice_rc=$?
set -e
expect_rc 'bf-creds --fetch fails closed without a dealer number' 1 "$nodevice_rc"
expect_contains 'the failure explains the missing dealer number' "$WORK/creds-nodevice.out" 'cannot determine the dealer number'
CREDS_STATE_FILE="$CSB/state.json"
CREDS_DEVICE='BF-12345678'

# 6e. --dealer-id and --repo argument validation.
set +e
creds_env "$CREDS" "$WORK/creds-bad-dealer.out" --dealer-id 123 >/dev/null 2>&1
bad_dealer_rc=$?
creds_env "$CREDS" "$WORK/creds-bad-repo.out" --fetch --repo "$WORK/does-not-exist" >/dev/null 2>&1
bad_repo_rc=$?
set -e
expect_rc 'bf-creds rejects a malformed --dealer-id' 2 "$bad_dealer_rc"
expect_rc 'bf-creds rejects a --repo that does not exist' 2 "$bad_repo_rc"

# --------------------------------------------------------------------------- #
# 7. .gitignore: the delivery path is ignored, the tools are not.
# --------------------------------------------------------------------------- #
check
if git -C "$REPO_ROOT" check-ignore -q -- 'admin/secrets/12345678.txt'; then
    pass 'admin/secrets/<dealer-number>.txt is git-ignored'
else
    fail 'the bf-creds delivery path is NOT git-ignored (add admin/secrets/ to .gitignore)'
fi

# Positive control for `git check-ignore` itself: a pattern that is definitely
# present must be reported as ignored, so the assertion above cannot pass by
# accident.
check
if git -C "$REPO_ROOT" check-ignore -q -- 'probe/example.key'; then
    pass 'control: git check-ignore evaluates this repository'
else
    fail 'control: git check-ignore did not report a *.key path as ignored'
fi

# The tools themselves must stay tracked: an over-broad rule would hide them.
check
if git -C "$REPO_ROOT" check-ignore -q -- 'admin/bf-bootstrap.sh'; then
    fail 'admin/bf-bootstrap.sh is git-ignored'
else
    pass 'admin/bf-bootstrap.sh is not git-ignored'
fi
check
if git -C "$REPO_ROOT" check-ignore -q -- 'admin/lib/creds.sh'; then
    fail 'admin/lib/creds.sh is git-ignored'
else
    pass 'admin/lib/creds.sh is not git-ignored'
fi
contract '.gitignore has no over-broad admin or catch-all rule' "$GITIGNORE" lacks '^([*]|admin/?)$'

# --------------------------------------------------------------------------- #
# 8. The shipped admin files carry no secret-like material.
# --------------------------------------------------------------------------- #
# Heuristic for a *literal* credential assignment:
#   * the separator is `:` or `=`,
#   * the value is NOT a shell reference (`${...}`, `$(...)`),
#   * the value contains a digit or a base64 symbol, which is what separates a
#     credential literal from prose (a log message such as
#     `bf_deliver_secret: destination required` must not be reported).
# A purely alphabetic secret would slip through: this is a guard against
# obviously planted material, not a replacement for the repository-wide scan.
SECRET_ASSIGNMENT='(^|[^A-Za-z])(password|passwd|token|api[_-]?key|secret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/=_.-]*[0-9+/=][A-Za-z0-9+/=_.-]*'
PRIVATE_KEY_BLOCK='BEGIN (OPENSSH|RSA|EC|DSA|PGP) PRIVATE KEY'

for target in "$BOOTSTRAP" "$CREDS" "$CREDS_LIB"; do
    [[ -f "$target" ]] || continue
    contract "no private key block in ${target#"$REPO_ROOT"/}" "$target" lacks_i "$PRIVATE_KEY_BLOCK"
    contract "no secret assignment in ${target#"$REPO_ROOT"/}" "$target" lacks_i "$SECRET_ASSIGNMENT"
done

# Negative controls: a planted secret must be found in each file.
for target in "$BOOTSTRAP" "$CREDS"; do
    [[ -f "$target" ]] || continue
    planted="$WORK/planted-$(basename "$target")"
    cp "$target" "$planted"
    printf '%s\n' 'DEMO_TOKEN=abcd1234efgh' >> "$planted"
    control "secret assignment detection in $(basename "$target")" "$planted" lacks_i "$SECRET_ASSIGNMENT"
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' >> "$planted"
    control "private key detection in $(basename "$target")" "$planted" lacks_i "$PRIVATE_KEY_BLOCK"
done

# --------------------------------------------------------------------------- #
# Summary.
# --------------------------------------------------------------------------- #
if [[ "$FAIL" -ne 0 ]]; then
    printf '\ncheck-admin-static: FAILED (%d checks)\n' "$CHECKS" >&2
    exit 1
fi
printf '\ncheck-admin-static: all passed (%d checks)\n' "$CHECKS"
