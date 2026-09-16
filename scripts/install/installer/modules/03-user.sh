#!/usr/bin/env bash
# Blueforce maintenance user, restricted sudoers, mandatory administrator key.
set -euo pipefail
MODULE="03-user"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
CHECK_MODE=0
[[ "${1:-}" == "--check" ]] && CHECK_MODE=1
SUDOERS_FILE="/etc/sudoers.d/blueforce"
AUTHORIZED_KEYS="/home/blueforce/.ssh/authorized_keys"
BF_ADMIN_PUBLIC_KEY="${BF_ADMIN_PUBLIC_KEY:-}"
BF_ADMIN_PUBLIC_KEY_FILE="${BF_ADMIN_PUBLIC_KEY_FILE:-}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [03-user] $1" | tee -a "$LOG_FILE"; }
valid_key_file() { [[ -s "$AUTHORIZED_KEYS" ]] && ssh-keygen -l -f "$AUTHORIZED_KEYS" >/dev/null 2>&1; }
load_admin_key() {
    [[ -z "$BF_ADMIN_PUBLIC_KEY" && -n "$BF_ADMIN_PUBLIC_KEY_FILE" && -r "$BF_ADMIN_PUBLIC_KEY_FILE" ]] || { log "FAIL: a seed-provided BF_ADMIN_PUBLIC_KEY_FILE is required; inline keys are refused"; return 1; }
    [[ "$(stat -c '%U:%a' "$BF_ADMIN_PUBLIC_KEY_FILE")" =~ ^root:6[04]0$ ]] || { log "FAIL: administrator key file must be root-owned and not group/world writable"; return 1; }
    grep -qE '^(ssh-(ed25519|rsa|ecdsa)|sk-ssh-ed25519)' "$BF_ADMIN_PUBLIC_KEY_FILE" && ! grep -q 'PRIVATE KEY' "$BF_ADMIN_PUBLIC_KEY_FILE" || { log "FAIL: administrator key file must contain a public SSH key only"; return 1; }
    cat "$BF_ADMIN_PUBLIC_KEY_FILE"
}
if [[ "$CHECK_MODE" -eq 1 ]]; then
    id blueforce >/dev/null 2>&1 || { log "FAIL(check): user blueforce missing"; exit 1; }
    [[ -f "$SUDOERS_FILE" ]] && visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1 || { log "FAIL(check): sudoers invalid"; exit 1; }
    valid_key_file || { log "FAIL(check): authorized_keys is empty or invalid"; exit 1; }
    log "OK(check): user, sudoers, and a valid administrator key are present"; exit 0
fi
key_data="$(load_admin_key)" || exit 1
[[ -n "${key_data//[[:space:]]/}" ]] || { log "FAIL: administrator key is empty"; exit 1; }
tmp_key="$(mktemp)"; trap 'rm -f "$tmp_key"' EXIT
printf '%s\n' "$key_data" > "$tmp_key"
ssh-keygen -l -f "$tmp_key" >/dev/null 2>&1 || { log "FAIL: supplied administrator public key is invalid"; exit 1; }
if ! id blueforce >/dev/null 2>&1; then useradd -m -s /bin/bash blueforce; fi
passwd -l blueforce >/dev/null 2>&1 || true
install -d -m 700 -o blueforce -g blueforce /home/blueforce/.ssh
install -m 600 -o blueforce -g blueforce "$tmp_key" "$AUTHORIZED_KEYS"
valid_key_file || { log "FAIL: atomic authorized_keys install did not validate"; exit 1; }
cat > /tmp/blueforce.sudoers <<'EOF'
# Managed by blueforce-installer (03-user). Local edits will be overwritten.
blueforce ALL=(root) NOPASSWD: /usr/local/bin/bf-status, /usr/local/bin/bf-gui-on, /usr/local/bin/bf-gui-off, /bin/systemctl status *, /bin/systemctl is-active *, /bin/systemctl is-enabled *, /usr/bin/docker ps, /usr/bin/docker logs *
EOF
visudo -cf /tmp/blueforce.sudoers
install -m 440 /tmp/blueforce.sudoers "$SUDOERS_FILE"
log "OK: user blueforce has a validated administrator key and restricted sudoers"