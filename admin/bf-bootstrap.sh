#!/usr/bin/env bash
#
# bf-bootstrap.sh — one-command install of the Blueforce Linux admin toolbox.
#
# Documented entry points:
#   curl -fsSL https://raw.githubusercontent.com/emirhanmamak-blueforce/Blueforce-Linux/main/admin/bf-bootstrap.sh | sudo bash
#   sudo admin/bf-bootstrap.sh            # from a checkout
#
# Steps, in order:
#   1. root check (apply mode only; --check is read-only and needs no root),
#   2. Ubuntu release check against the supported baseline (24.04 / 26.04),
#   3. dependency install: git, curl, ansible-core,
#   4. clone the repository into <dir> (default /opt/blueforce-linux) or
#      fast-forward an existing checkout (never resets, never discards work),
#   5. link admin/bf-*, scripts/diagnostics/bf-* and scripts/maintenance/bf-*
#      into /usr/local/bin (idempotent; a re-run refreshes the links),
#   6. make admin/bf-menu executable so `sudo bf-menu` starts the on-device
#      installer menu,
#   7. print a clear summary.
#
# Safety
#   * This script writes no secret and installs code only: credentials stay on
#     the device and are never fetched by the installer (see admin/bf-creds).
#   * Re-running it is safe: the checkout is fast-forwarded and the tool links
#     are re-created. Nothing is deleted and no `git reset` is ever performed,
#     so local work in the checkout is never discarded.
#   * --check reports the same plan without touching the system.
#
set -euo pipefail

REPO_URL="${BF_REPO_URL:-https://github.com/emirhanmamak-blueforce/Blueforce-Linux.git}"
BRANCH_DEFAULT="main"
INSTALL_DIR_DEFAULT="/opt/blueforce-linux"
BIN_DIR="${BF_BIN_DIR:-/usr/local/bin}"
SUPPORTED_UBUNTU=("24.04" "26.04")
# Command name / apt package name pairs for the installer prerequisites.
DEPENDENCY_COMMANDS=(git curl ansible-playbook)
DEPENDENCY_PACKAGES=(git curl ansible-core)

CHECK_MODE=0
ASSUME_YES=0
BRANCH="$BRANCH_DEFAULT"
DIR=""
LINKED=0
MENU_READY=0

usage() {
    cat <<'EOF'
Usage: sudo bf-bootstrap.sh [--check] [--dir DIR] [--branch BRANCH] [--yes] [--help]

Install (or refresh) the Blueforce Linux admin toolbox from git: fetch the
repository, install the prerequisites, link the bf-* tools into
/usr/local/bin, and make `sudo bf-menu` available for the on-device setup.

Options:
  --check          Read-only: report what would happen. It never mutates
                   anything and never requires root.
  --dir DIR        Checkout directory. Default: the checkout this script lives
                   in, otherwise /opt/blueforce-linux.
  --branch BRANCH  Branch to track (default: main).
  --yes, -y        Do not ask for confirmation.
  --help, -h       Show this help and exit.

Environment:
  BF_REPO_URL     Repository URL (default: the upstream GitHub repository).
  BF_INSTALL_DIR  Checkout directory; same as --dir.
  BF_BIN_DIR      Tool link directory (default: /usr/local/bin).

Notes:
  * Installer prerequisites are git, curl and ansible-core (ansible-playbook).
  * Supported baseline is Ubuntu 24.04 / 26.04; any other release only warns.
  * This script installs code only. It never writes, fetches, or prints a
    secret; device credentials are handled by admin/bf-creds.
EOF
}

say() { printf 'bf-bootstrap: %s\n' "$*"; }
warn() { printf 'bf-bootstrap: WARN: %s\n' "$*" >&2; }
die() { printf 'bf-bootstrap: ERROR: %s\n' "$*" >&2; exit 1; }
# run: executes a mutating command, or only reports it under --check.
run() {
    if [[ "$CHECK_MODE" -eq 1 ]]; then
        printf 'bf-bootstrap: check: would run: %s\n' "$*"
        return 0
    fi
    "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_MODE=1; shift ;;
        --dir) DIR="${2:?missing value for --dir}"; shift 2 ;;
        --branch) BRANCH="${2:?missing value for --branch}"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'bf-bootstrap: ERROR: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------- #
# Where does this script live? When it runs from a checkout, that checkout is
# the default target; the piped one-command form has no checkout, so the
# default install directory is used.
# --------------------------------------------------------------------------- #
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && -r "$SCRIPT_SOURCE" ]]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")"
    CANDIDATE="$(cd "$(dirname "$SCRIPT_REAL")/.." 2>/dev/null && pwd || true)"
    if [[ -n "$CANDIDATE" && -f "$CANDIDATE/admin/bf-bootstrap.sh" && -d "$CANDIDATE/scripts/diagnostics" ]]; then
        CHECKOUT_ROOT="$CANDIDATE"
    fi
fi
if [[ -z "$DIR" ]]; then
    DIR="${BF_INSTALL_DIR:-${CHECKOUT_ROOT:-$INSTALL_DIR_DEFAULT}}"
fi

if [[ -z "$BRANCH" ]]; then
    die 'branch must not be empty'
fi

# --------------------------------------------------------------------------- #
# 1. Root check. --check only reports, so it works as an unprivileged user.
# --------------------------------------------------------------------------- #
if [[ "$CHECK_MODE" -eq 1 ]]; then
    if [[ "$(id -u)" -ne 0 ]]; then
        say 'check: not running as root; apply mode will require sudo'
    fi
else
    if [[ "$(id -u)" -ne 0 ]]; then
        die "must run as root: sudo $0 (or: sudo bf-bootstrap.sh)"
    fi
fi

# --------------------------------------------------------------------------- #
# 2. Ubuntu release check. A different release is only a warning: the goal is
#    to install the toolbox, not to block a working host.
# --------------------------------------------------------------------------- #
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_PRETTY="unknown"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_PRETTY="${PRETTY_NAME:-unknown}"
fi
if [[ "$DISTRO_ID" == "ubuntu" ]]; then
    SUPPORTED=0
    for release in "${SUPPORTED_UBUNTU[@]}"; do
        if [[ "$DISTRO_VERSION" == "$release" ]]; then
            SUPPORTED=1
        fi
    done
    if [[ "$SUPPORTED" -eq 1 ]]; then
        say "ubuntu ${DISTRO_VERSION} is a supported baseline"
    else
        warn "Ubuntu ${DISTRO_VERSION:-unknown} is outside the tested baseline (${SUPPORTED_UBUNTU[*]}); continuing"
    fi
else
    warn "this is not an Ubuntu host (ID=${DISTRO_ID:-unknown}, ${DISTRO_PRETTY}); the Field OS baseline is Ubuntu ${SUPPORTED_UBUNTU[*]}"
fi

# --------------------------------------------------------------------------- #
# Operator confirmation. Only a terminal prompts: the documented one-command
# form (`curl ... | sudo bash`) has no terminal on stdin and never blocks.
# --------------------------------------------------------------------------- #
if [[ "$CHECK_MODE" -eq 0 && "$ASSUME_YES" -eq 0 && -t 0 ]]; then
    printf 'Install or update the Blueforce toolbox in %s? [y/N] ' "$DIR"
    ANSWER=""
    read -r ANSWER || ANSWER=""
    if [[ ! "$ANSWER" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        say 'aborted by the operator'
        exit 2
    fi
fi

# --------------------------------------------------------------------------- #
# 3. Dependencies.
# --------------------------------------------------------------------------- #
MISSING_COMMANDS=()
MISSING_PACKAGES=()
say 'dependency check'
for index in "${!DEPENDENCY_COMMANDS[@]}"; do
    if ! command -v "${DEPENDENCY_COMMANDS[$index]}" >/dev/null 2>&1; then
        MISSING_COMMANDS+=("${DEPENDENCY_COMMANDS[$index]}")
        MISSING_PACKAGES+=("${DEPENDENCY_PACKAGES[$index]}")
    fi
done
if [[ ${#MISSING_PACKAGES[@]} -eq 0 ]]; then
    say "dependencies present: ${DEPENDENCY_COMMANDS[*]}"
elif [[ "$CHECK_MODE" -eq 1 ]]; then
    say "check: would install with apt-get: ${MISSING_PACKAGES[*]} (missing: ${MISSING_COMMANDS[*]})"
else
    if ! command -v apt-get >/dev/null 2>&1; then
        die "apt-get not found; install these packages first: ${MISSING_PACKAGES[*]}"
    fi
    say "installing dependencies: ${MISSING_PACKAGES[*]}"
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    run apt-get install -y --no-install-recommends "${MISSING_PACKAGES[@]}"
fi

# --------------------------------------------------------------------------- #
# 4. Repository: clone once, then fast-forward only.
# --------------------------------------------------------------------------- #
update_checkout() {
    local remote="" origin_url="" dirty=""
    if ! git -C "$DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        warn "checkout has no commits yet: $DIR; skipping the update"
        return 0
    fi
    # Prefer `origin`, otherwise accept the checkout's single remote (a local
    # clone of this project may name it `github`, as the upstream checkout does).
    if git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
        remote="origin"
    else
        remote="$(git -C "$DIR" remote 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -z "$remote" ]]; then
        warn "checkout has no git remote: $DIR; skipping the update"
        return 0
    fi
    origin_url="$(git -C "$DIR" remote get-url "$remote" 2>/dev/null || true)"
    if [[ "$origin_url" != *"Blueforce-Linux"* ]]; then
        warn "remote '$remote' looks unexpected: $origin_url"
    fi
    dirty="$(git -C "$DIR" status --porcelain 2>/dev/null || true)"
    if [[ -n "$dirty" ]]; then
        warn "local changes present in $DIR; skipping the update (nothing was reset or stashed)"
        return 0
    fi
    if [[ "$CHECK_MODE" -eq 1 ]]; then
        say "check: would fast-forward $DIR to $remote/$BRANCH"
        return 0
    fi
    say "updating $DIR (fast-forward only, remote $remote)"
    if ! git -C "$DIR" fetch --prune --quiet "$remote" "$BRANCH"; then
        warn "fetch failed (offline?); keeping the current checkout"
        return 0
    fi
    if ! git -C "$DIR" merge --ff-only --quiet "$remote/$BRANCH"; then
        warn "cannot fast-forward to $remote/$BRANCH; keeping the current checkout (no reset performed)"
    fi
    return 0
}

if [[ -e "$DIR" && ! -d "$DIR" ]]; then
    die "install directory exists and is not a directory: $DIR"
fi
if [[ -d "$DIR" ]]; then
    if [[ -d "$DIR/.git" ]]; then
        say "existing checkout: $DIR"
        update_checkout
    else
        die "directory exists but is not a git checkout; refusing to touch it: $DIR"
    fi
elif [[ "$CHECK_MODE" -eq 1 ]]; then
    say "check: would clone $REPO_URL (branch $BRANCH) into $DIR"
else
    say "cloning $REPO_URL (branch $BRANCH) into $DIR"
    run install -d -m 0755 "$(dirname "$DIR")"
    run git clone --branch "$BRANCH" --single-branch -- "$REPO_URL" "$DIR"
fi

# --------------------------------------------------------------------------- #
# 5. Link the tools into /usr/local/bin. Idempotent: `ln -sfn` refreshes an
#    existing link, and a re-run after `git pull` needs no extra step.
# --------------------------------------------------------------------------- #
link_tools() {
    local source="" base=""
    for source in "$DIR"/admin/bf-* "$DIR"/scripts/diagnostics/bf-* "$DIR"/scripts/maintenance/bf-*; do
        if [[ ! -f "$source" ]]; then
            continue
        fi
        base="$(basename "$source")"
        if [[ "$CHECK_MODE" -eq 1 ]]; then
            say "check: would link $source -> $BIN_DIR/$base"
        else
            chmod 0755 "$source"
            ln -sfn "$source" "$BIN_DIR/$base"
        fi
        LINKED=$((LINKED + 1))
    done
}

if [[ -d "$DIR" ]]; then
    run install -d -m 0755 "$BIN_DIR"
    link_tools
    if [[ "$LINKED" -eq 0 ]]; then
        warn "no bf-* tools found under $DIR (admin/, scripts/diagnostics/, scripts/maintenance/)"
    elif [[ "$CHECK_MODE" -eq 0 ]]; then
        say "linked $LINKED tools into $BIN_DIR"
    fi
elif [[ "$CHECK_MODE" -eq 1 ]]; then
    say "check: would link the bf-* tools from $DIR into $BIN_DIR"
fi

# --------------------------------------------------------------------------- #
# 6. bf-menu: the on-device installer menu entry point.
# --------------------------------------------------------------------------- #
MENU_SOURCE="$DIR/admin/bf-menu"
if [[ -f "$MENU_SOURCE" ]]; then
    if [[ "$CHECK_MODE" -eq 1 ]]; then
        say "check: would make $MENU_SOURCE executable and link $BIN_DIR/bf-menu"
    else
        chmod 0755 "$MENU_SOURCE"
        ln -sfn "$MENU_SOURCE" "$BIN_DIR/bf-menu"
        say "bf-menu ready: $BIN_DIR/bf-menu"
    fi
    MENU_READY=1
else
    warn "admin/bf-menu is not present in $DIR; 'sudo bf-menu' will work once the menu module is in the checkout"
fi

# --------------------------------------------------------------------------- #
# 7. Summary.
# --------------------------------------------------------------------------- #
if [[ "$CHECK_MODE" -eq 1 ]]; then
    printf '\nbf-bootstrap: check complete -- no changes were made.\n'
    printf '  checkout    : %s\n' "$DIR"
    printf '  branch      : %s\n' "$BRANCH"
    printf '  tools       : %s tool(s) would be linked into %s\n' "$LINKED" "$BIN_DIR"
    printf '  next        : sudo bf-bootstrap.sh --yes\n'
    exit 0
fi

REVISION=""
if [[ -d "$DIR/.git" ]]; then
    REVISION="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || true)"
fi
printf '\nbf-bootstrap: summary\n'
printf '  repository  : %s\n' "$DIR"
printf '  branch      : %s\n' "$BRANCH"
if [[ -n "$REVISION" ]]; then
    printf '  revision    : %s\n' "$REVISION"
fi
printf '  tools       : %s linked into %s\n' "$LINKED" "$BIN_DIR"
if [[ "$MENU_READY" -eq 1 ]]; then
    printf '  bf-menu     : %s\n' "$BIN_DIR/bf-menu"
else
    printf '  bf-menu     : pending (admin/bf-menu is not in the checkout yet)\n'
fi
printf '  next        : sudo bf-menu\n'
printf '\nInstallation complete. To get started: sudo bf-menu\n'
printf 'Kurulum tamam. Başlamak için: sudo bf-menu\n'
