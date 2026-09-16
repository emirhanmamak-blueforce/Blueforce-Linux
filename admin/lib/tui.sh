#!/usr/bin/env bash
# admin/lib/tui.sh -- terminal UI helpers for the Blueforce operator console.
#
# Sourced by admin/bf-menu. This file contains presentation and input helpers
# only: no fleet logic, no inventory parsing, and no side effects when sourced.
#
# Contract:
#   * user-facing output goes to stdout, diagnostics/warnings to stderr,
#   * no helper calls exit except tui_die (and it only does so when called),
#   * no helper ever prints a secret, and nothing here writes to the log,
#   * every helper tolerates `set -u`: optional arguments use ${x:-} defaults.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Colors. Disabled automatically when stdout is not a terminal, when NO_COLOR
# is set, or when the caller asks for "never".
# ---------------------------------------------------------------------------
TUI_COLOR_MODE="${TUI_COLOR_MODE:-auto}"

# shellcheck disable=SC2034  # color variables are consumed by bf-menu
tui_init_colors() {
    local want="${1:-$TUI_COLOR_MODE}"
    local enable=0
    case "$want" in
        always) enable=1 ;;
        never)  enable=0 ;;
        *)
            if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
                enable=1
            fi
            ;;
    esac
    if [[ "$enable" -eq 1 ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'
        C_MAGENTA=$'\033[35m'
        C_CYAN=$'\033[36m'
    else
        C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
        C_BLUE="" C_MAGENTA="" C_CYAN=""
    fi
    export C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN
}

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
TUI_WIDTH="${TUI_WIDTH:-78}"

tui_hr() {
    local char="${1:--}"
    local line
    line="$(printf "%*s" "$TUI_WIDTH" "" | tr ' ' "$char")"
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
}

# tui_banner TITLE [SUBTITLE]
tui_banner() {
    local title="$1" subtitle="${2:-}"
    printf '\n'
    tui_hr '='
    printf '  %s%s%s\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"
    if [[ -n "$subtitle" ]]; then
        printf '  %s%s%s\n' "$C_DIM" "$subtitle" "$C_RESET"
    fi
    tui_hr '='
    printf '\n'
}

# tui_screen TITLE [SUBTITLE]
# Clears the terminal first when interactive so one screen fits one page; the
# clear is skipped for non-interactive runs (pipes, tests, logs).
tui_screen() {
    if [[ -t 1 && "${TUI_CLEAR:-yes}" == "yes" ]]; then
        printf '\033[H\033[2J'
    fi
    tui_banner "${1:-}" "${2:-}"
}

# tui_item NUMBER LABEL [DESCRIPTION]
tui_item() {
    local number="$1" label="$2" desc="${3:-}"
    if [[ -n "$desc" ]]; then
        printf '   %s%2s%s) %-46s %s%s%s\n' "$C_BOLD" "$number" "$C_RESET" "$label" "$C_DIM" "$desc" "$C_RESET"
    else
        printf '   %s%2s%s) %s\n' "$C_BOLD" "$number" "$C_RESET" "$label"
    fi
}

# tui_section LABEL -- visual separator inside a long menu.
tui_section() {
    printf '\n   %s%s%s\n' "$C_MAGENTA" "${1:-}" "$C_RESET"
}

# tui_footer [BACK_LABEL] -- every screen ends with back and quit.
tui_footer() {
    local back="${1:-Back}"
    printf '\n'
    tui_hr '-'
    printf '   %s%2s%s) %-46s %s%2s%s) %s\n' \
        "$C_BOLD" "0" "$C_RESET" "$back" "$C_BOLD" "q" "$C_RESET" "Quit the console"
    tui_hr '-'
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
# tui_read PROMPT -> TUI_REPLY
# Returns 0 on a line, 1 on EOF (stdin closed / non-interactive); on EOF the
# reply is "q" so the caller's menu loop quits instead of spinning forever.
tui_read() {
    local prompt="${1:-} "
    TUI_REPLY=""
    printf '%s' "$prompt"
    if ! IFS= read -r TUI_REPLY; then
        TUI_REPLY="q"
        printf '\n'
        return 1
    fi
    # Trim surrounding whitespace so " 2 " is accepted like "2".
    TUI_REPLY="${TUI_REPLY#"${TUI_REPLY%%[![:space:]]*}"}"
    TUI_REPLY="${TUI_REPLY%"${TUI_REPLY##*[![:space:]]}"}"
    return 0
}

# tui_prompt LABEL [DEFAULT] -> TUI_REPLY
tui_prompt() {
    local label="$1" default="${2:-}" suffix=""
    if [[ -n "$default" ]]; then
        suffix=" [$default]"
    fi
    tui_read "${label}${suffix}: " || true
    if [[ -z "$TUI_REPLY" ]]; then
        TUI_REPLY="$default"
    fi
}

# tui_confirm QUESTION [yes|no] -- default is NO: only an explicit y/yes proceeds.
tui_confirm() {
    local question="$1" default="${2:-no}" suffix="[y/N]"
    [[ "$default" == "yes" ]] && suffix="[Y/n]"
    tui_read "${question} ${suffix} " || true
    case "${TUI_REPLY,,}" in
        y|yes) return 0 ;;
        n|no)  return 1 ;;
        "")
            [[ "$default" == "yes" ]] && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

# tui_confirm_token QUESTION TOKEN -- the operator must type the exact token.
# Used for the highest-risk operations (production waves, fleet-wide runs).
tui_confirm_token() {
    local question="$1" token="$2"
    tui_warn "$question"
    tui_read "$(printf 'Type %s%s%s to confirm (anything else cancels): ' "$C_BOLD" "$token" "$C_RESET")" || true
    [[ "$TUI_REPLY" == "$token" ]]
}

# tui_ask_run QUESTION -> 0 = run, 2 = run with --check, 1 = cancel
tui_ask_run() {
    local question="$1"
    tui_read "${question} [y=run / c=run with --check / N=cancel] " || true
    case "${TUI_REPLY,,}" in
        y|yes) return 0 ;;
        c|check) return 2 ;;
        *) return 1 ;;
    esac
}

# tui_menu_index NUMBER MAX -- true when NUMBER selects an item of the menu.
tui_menu_index() {
    local number="$1" max="$2"
    [[ "$number" =~ ^[0-9]+$ ]] || return 1
    ((number >= 1 && number <= max)) || return 1
    return 0
}

tui_pause() {
    local message="${1:-Press Enter to continue}"
    if [[ -t 0 ]]; then
        tui_read "${C_DIM}${message}${C_RESET}" || true
    fi
}

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------
tui_msg()  { printf '%s\n' "$*"; }
tui_info() { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
tui_ok()   { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
tui_warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
tui_error(){ printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
tui_note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# tui_kv KEY VALUE -- aligned key/value line for information screens.
tui_kv() {
    printf '   %-24s %s\n' "$1" "$2"
}

# tui_die MESSAGE [EXIT_CODE] -- last resort: report and exit with a non-zero
# status. Everything user-recoverable should return a status instead.
tui_die() {
    local message="$1" code="${2:-1}"
    tui_error "$message"
    exit "$code"
}
