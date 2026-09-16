#!/usr/bin/env bash
# Harden sshd only after a validated Blueforce administrator key is installed.
set -euo pipefail
MODULE="07-ssh"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
CHECK_MODE=0
[[ "${1:-}" == "--check" ]] && CHECK_MODE=1
DROPIN="/etc/ssh/sshd_config.d/99-blueforce.conf"
AUTHORIZED_KEYS="/home/blueforce/.ssh/authorized_keys"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [07-ssh] $1" | tee -a "$LOG_FILE"; }
key_ready() { [[ -s "$AUTHORIZED_KEYS" ]] && ssh-keygen -l -f "$AUTHORIZED_KEYS" >/dev/null 2>&1; }
ADMIN_KEY="${BF_ADMIN_PUBLIC_KEY:-}"
ADMIN_KEY_FILE="${BF_ADMIN_PUBLIC_KEY_FILE:-}"
install_admin_key() {
    [[ -n "$ADMIN_KEY" || -n "$ADMIN_KEY_FILE" ]] || return 0
    [[ -z "$ADMIN_KEY" ]] || printf '%s\n' "$ADMIN_KEY" > /tmp/blueforce-admin-key
    [[ -z "$ADMIN_KEY_FILE" ]] || { [[ -r "$ADMIN_KEY_FILE" ]] || { log "FAIL: BF_ADMIN_PUBLIC_KEY_FILE is unreadable"; exit 1; }; cp "$ADMIN_KEY_FILE" /tmp/blueforce-admin-key; }
    ssh-keygen -l -f /tmp/blueforce-admin-key >/dev/null 2>&1 || { log "FAIL: BF_ADMIN_PUBLIC_KEY is not a valid public key"; exit 1; }
    install -d -m 700 -o blueforce -g blueforce /home/blueforce/.ssh
    install -m 600 -o blueforce -g blueforce /tmp/blueforce-admin-key "$AUTHORIZED_KEYS"
}
read -r -d '' WANT <<'EOF' || true
# Managed by blueforce-installer (07-ssh). Local edits will be overwritten.
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
AllowUsers blueforce
EOF
if [[ "$CHECK_MODE" -eq 1 ]]; then
    [[ -f "$DROPIN" ]] || { log "FAIL(check): sshd drop-in missing"; exit 1; }
    key_ready || { log "FAIL(check): no valid non-empty blueforce authorized_keys"; exit 1; }
    grep -qx 'AllowUsers blueforce' "$DROPIN" || { log "FAIL(check): AllowUsers policy is incorrect"; exit 1; }
    sshd -t 2>/dev/null || { log "FAIL(check): sshd config test failed"; exit 1; }
    log "OK(check): hardened SSH permits only blueforce with a valid key"; exit 0
fi
export DEBIAN_FRONTEND=noninteractive
command -v sshd >/dev/null 2>&1 || apt-get install -y openssh-server
install_admin_key
key_ready || { log "FAIL: valid non-empty /home/blueforce/.ssh/authorized_keys or BF_ADMIN_PUBLIC_KEY(_FILE) is required before SSH hardening"; exit 1; }
printf '%s\n' "$WANT" > /tmp/99-blueforce.conf.bf
install -m 644 /tmp/99-blueforce.conf.bf "$DROPIN"
sshd -t || { log "FAIL: sshd -t rejected the new config"; exit 1; }
if systemctl list-unit-files | grep -q '^sshd\.service'; then SVC=sshd; else SVC=ssh; fi
systemctl enable "$SVC" >/dev/null 2>&1 || true
systemctl reload-or-restart "$SVC"
log "OK: hardened SSH installed after valid key verification; AllowUsers=blueforce"