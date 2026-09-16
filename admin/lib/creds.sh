#!/usr/bin/env bash
#
# creds.sh — shared helpers for the Blueforce credential tooling (admin/bf-creds).
#
# Contract
#   * No helper here ever writes a secret to stdout, stderr, or a log file.
#     Secrets travel through files only: root-owned, mode 0600, inside a mode
#     0700 directory. Callers capture generated values with `$( ... )` (which
#     never prints) and must never echo, printf, export, or log them.
#   * Lookup helpers are read-only. Only the `bf_write_secret_file` /
#     `bf_deliver_secret` helpers touch the filesystem, and only at the target
#     the caller names explicitly.
#   * A WireGuard *private key is never read* by this library: only its path is
#     ever reported. The same rule applies to every other private key material.
#   * This library does not change the remote-access decision recorded in
#     docs/06-USERS-SSH-AND-PERMISSIONS.md: OpenSSH password authentication
#     stays disabled (`PasswordAuthentication no`) and the `blueforce`
#     maintenance account stays locked. bf-creds is an optional *local*
#     delivery helper: it never edits sshd_config, never unlocks an account,
#     and never opens a password login path. See the header of admin/bf-creds
#     and the "admin/" section of README.md.
#
# Usage: sourced by admin/bf-creds. Not meant to be executed on its own.
#
set -euo pipefail

# Executing the library directly would silently do nothing useful; say so.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf 'creds.sh is a library: source it (see admin/bf-creds).\n' >&2
    exit 2
fi

if [[ -n "${BF_CREDS_LIB_LOADED:-}" ]]; then
    return 0
fi
BF_CREDS_LIB_LOADED=1

# --------------------------------------------------------------------------- #
# Locations. Every path is overridable so tests can point the helpers at a
# sandbox and so a site can relocate the credential record deliberately.
# --------------------------------------------------------------------------- #
: "${BF_STATE_FILE:=/var/lib/blueforce/state.json}"
: "${BF_WG_DIR:=/etc/wireguard}"
: "${BF_RUSTDESK_ID_FILE:=/var/lib/blueforce/rustdesk-id}"
: "${BF_CREDENTIALS_FILE:=/root/blueforce-credentials.txt}"
: "${BF_SECRETS_SUBDIR:=admin/secrets}"
: "${BF_CREDENTIALS_MODE:=600}"
: "${BF_SECRETS_DIR_MODE:=700}"

# --------------------------------------------------------------------------- #
# Logging. Messages are always descriptions, never values.
# --------------------------------------------------------------------------- #
bf_log() { printf '[bf-creds] %s\n' "$*" >&2; }
bf_warn() { printf '[bf-creds] WARN: %s\n' "$*" >&2; }
bf_die() { printf '[bf-creds] ERROR: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Read-only identity helpers.
# --------------------------------------------------------------------------- #

# bf_detect_device_id -> prints BF-<8 digits> (BF_DEVICE, then the installer
# state file, then the hostname); prints nothing and returns 1 when unknown.
bf_detect_device_id() {
    local id=""
    if [[ "${BF_DEVICE:-}" =~ ^BF-[0-9]{8}$ ]]; then
        printf '%s' "$BF_DEVICE"
        return 0
    fi
    if [[ -r "$BF_STATE_FILE" ]] && grep -q 'device_id' "$BF_STATE_FILE" 2>/dev/null; then
        id="$(grep -oE 'BF-[0-9]{8}' "$BF_STATE_FILE" 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -z "$id" ]]; then
        id="$(hostname 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
    fi
    if [[ "$id" =~ ^BF-[0-9]{8}$ ]]; then
        printf '%s' "$id"
        return 0
    fi
    return 1
}

# bf_dealer_number <device-id> -> prints the 8-digit dealer number, else nothing.
bf_dealer_number() {
    local id="${1:-}"
    if [[ "$id" =~ ^BF-([0-9]{8})$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# bf_wireguard_public_key -> prints the public key (safe to display); nothing
# and return 1 when the installer has not created a keypair yet.
bf_wireguard_public_key() {
    local f="$BF_WG_DIR/publickey" key=""
    if [[ -s "$f" ]]; then
        key="$(tr -d '[:space:]' < "$f" 2>/dev/null || true)"
    fi
    if [[ -n "$key" ]]; then
        printf '%s' "$key"
        return 0
    fi
    return 1
}

# bf_wireguard_private_key_path -> prints the PATH of the private key only.
# The contents are never opened: only the file's existence is checked.
bf_wireguard_private_key_path() {
    local f="$BF_WG_DIR/privatekey"
    if [[ -e "$f" ]]; then
        printf '%s' "$f"
        return 0
    fi
    return 1
}

# bf_rustdesk_id -> prints the RustDesk peer ID recorded by module 09-rustdesk.
bf_rustdesk_id() {
    local f="$BF_RUSTDESK_ID_FILE" id=""
    if [[ -s "$f" ]]; then
        id="$(tr -d '[:space:]' < "$f" 2>/dev/null || true)"
    fi
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        printf '%s' "$id"
        return 0
    fi
    return 1
}

# --------------------------------------------------------------------------- #
# Secret generation and file handling.
# --------------------------------------------------------------------------- #

# bf_generate_secret -> prints a fresh random secret on stdout (openssl, then
# /dev/urandom as a fallback). Capturing the result with `$( ... )` never
# prints it; the value must reach a mode-0600 file and nothing else. It is
# deliberately never passed through argv or a command line.
bf_generate_secret() {
    local secret=""
    if command -v openssl >/dev/null 2>&1; then
        secret="$(openssl rand -base64 24 2>/dev/null | tr -d '\n' || true)"
    fi
    if [[ -z "$secret" ]] && [[ -r /dev/urandom ]] && command -v base64 >/dev/null 2>&1; then
        secret="$(head -c 32 /dev/urandom 2>/dev/null | base64 | tr -d '\n' || true)"
    fi
    if [[ -z "$secret" ]]; then
        return 1
    fi
    printf '%s' "$secret"
}

# bf_file_mode <path> -> prints the octal mode (Linux stat).
bf_file_mode() { stat -c '%a' "$1" 2>/dev/null || true; }

# bf_has_generated_password <file> -> 0 when the record carries a password line.
bf_has_generated_password() {
    local f="${1:-}"
    if [[ -s "$f" ]] && grep -qE '^local_administrator_password:[[:space:]]*[^[:space:]]+' "$f"; then
        return 0
    fi
    return 1
}

# bf_write_secret_file <dest>    (stdin: entire file body)
# Writes stdin to <dest> atomically, forces mode 0600 on the file and 0700 on
# the parent directory, and verifies the result. Never echoes the body.
bf_write_secret_file() {
    local dest="${1:-}" tmp=""
    if [[ -z "$dest" ]]; then
        bf_warn 'bf_write_secret_file: destination required'
        return 1
    fi
    if [[ -L "$dest" ]]; then
        bf_warn "refusing to write through a symlink: $dest"
        return 1
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/bf-creds.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$tmp" ]]; then
        bf_warn 'cannot create a temporary staging file'
        return 1
    fi
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        bf_warn 'cannot stage the credential body'
        return 1
    fi
    if ! install -d -m "$BF_SECRETS_DIR_MODE" -- "$(dirname "$dest")"; then
        rm -f "$tmp"
        bf_warn "cannot create the credential directory: $(dirname "$dest")"
        return 1
    fi
    if ! install -m "$BF_CREDENTIALS_MODE" -- "$tmp" "$dest"; then
        rm -f "$tmp"
        bf_warn "cannot write the credential file: $dest"
        return 1
    fi
    rm -f "$tmp"
    if [[ "$(bf_file_mode "$dest")" != "$BF_CREDENTIALS_MODE" ]]; then
        bf_warn "credential file mode is not $BF_CREDENTIALS_MODE: $dest"
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Delivery.
# --------------------------------------------------------------------------- #

# bf_secrets_target_path <repo-root> <dealer-number> -> destination path.
bf_secrets_target_path() {
    local repo_root="${1:-}" dealer="${2:-}"
    if [[ -z "$repo_root" || -z "$dealer" ]]; then
        return 1
    fi
    printf '%s/%s/%s.txt' "$repo_root" "$BF_SECRETS_SUBDIR" "$dealer"
}

# bf_deliver_secret <src> <dest>
# Copies a credential file to the delivery target: directory mode 0700, file
# mode 0600. Prints nothing; the caller reports the path only.
bf_deliver_secret() {
    local src="${1:-}" dest="${2:-}"
    if [[ ! -s "$src" ]]; then
        bf_warn "credential file is missing or empty: $src"
        return 1
    fi
    if [[ -z "$dest" ]]; then
        bf_warn 'bf_deliver_secret: destination required'
        return 1
    fi
    if [[ -L "$dest" ]]; then
        bf_warn "refusing to write through a symlink: $dest"
        return 1
    fi
    if ! install -d -m "$BF_SECRETS_DIR_MODE" -- "$(dirname "$dest")"; then
        bf_warn "cannot create the delivery directory: $(dirname "$dest")"
        return 1
    fi
    if ! install -m "$BF_CREDENTIALS_MODE" -- "$src" "$dest"; then
        bf_warn "cannot deliver the credential file to: $dest"
        return 1
    fi
    if [[ "$(bf_file_mode "$dest")" != "$BF_CREDENTIALS_MODE" ]]; then
        bf_warn "delivered file mode is not $BF_CREDENTIALS_MODE: $dest"
        return 1
    fi
    return 0
}
