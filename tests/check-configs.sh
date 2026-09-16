#!/usr/bin/env bash
# Parse fleet configuration and validate executable shell scripts without running them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
pass() { printf 'OK: %s\n' "$*"; }

# Every Bash script under scripts/ must pass syntax parsing. Non-Bash assets are ignored.
while IFS= read -r -d '' script; do
  if head -n 1 "$script" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash'; then
    bash -n "$script" && pass "bash parses: ${script#$REPO_ROOT/}" || fail "bash parse error: ${script#$REPO_ROOT/}"
  fi
done < <(find "$REPO_ROOT/scripts" -type f -print0)

# All Ansible and deployable configuration YAML must parse through PyYAML safe_load.
while IFS= read -r -d '' yaml_file; do
  if python3 - "$yaml_file" <<'PY'
import sys
import yaml
with open(sys.argv[1], encoding='utf-8') as handle:
    yaml.safe_load(handle)
PY
  then
    pass "yaml parses: ${yaml_file#$REPO_ROOT/}"
  else
    fail "yaml parse error: ${yaml_file#$REPO_ROOT/}"
  fi
done < <(find "$REPO_ROOT/ansible" "$REPO_ROOT/config" "$REPO_ROOT/monitoring" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)

# JSON configuration must parse as JSON, not merely as JavaScript.
while IFS= read -r -d '' json_file; do
  if python3 - "$json_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as handle:
    json.load(handle)
PY
  then
    pass "json parses: ${json_file#$REPO_ROOT/}"
  else
    fail "json parse error: ${json_file#$REPO_ROOT/}"
  fi
done < <(find "$REPO_ROOT/config" "$REPO_ROOT/monitoring" -type f -name '*.json' -print0)

# Required values preserve the naming and wave policy in docs/09 and docs/10.
INV="$REPO_ROOT/ansible/inventory/hosts.example.yml"
GV="$REPO_ROOT/ansible/inventory/group_vars/all.yml"
[[ -f "$INV" ]] || fail "missing inventory example: $INV"
[[ -f "$GV" ]] || fail "missing shared group variables: $GV"
for group in lab pilot_1 pilot_2 wave_1 wave_2 production; do
  grep -q "^[[:space:]]*$group:" "$INV" || fail "inventory missing wave group: $group"
done
for key in wg_subnet wg_interface monitoring_endpoint meg_image_tag reboot_grace_seconds support_bundle_dir; do
  grep -q "^$key:" "$GV" || fail "group_vars/all.yml missing key: $key"
done
for pb in bf-collect-logs.yml bf-gui-on.yml bf-gui-off.yml bf-run-script.yml; do
  grep -q '^  hosts: "{{ operation_wave' "$REPO_ROOT/ansible/playbooks/$pb" || fail "$pb must dynamically target operation_wave"
  grep -q 'production_override: false' "$REPO_ROOT/ansible/playbooks/$pb" || fail "$pb must default production_override to false"
done
FIREWALL_POLICY="$REPO_ROOT/config/firewall/blueforce-docker-user-restore.sh"
bash -n "$FIREWALL_POLICY" && pass 'bash parses: config/firewall/blueforce-docker-user-restore.sh' || fail 'bash parse error: config/firewall/blueforce-docker-user-restore.sh'
grep -q '^After=docker.service$' "$REPO_ROOT/config/systemd/blueforce-docker-firewall.service" || fail 'Docker firewall service must wait for Docker'
grep -q '^Wants=blueforce-docker-firewall.service$' "$REPO_ROOT/config/systemd/docker.service.d/blueforce-docker-firewall.conf" || fail 'Docker drop-in must start firewall policy'
if grep -RniE --include='*.yml' --include='*.yaml' --include='*.json' '^[[:space:]]*[^#].*(image:[^#]*:latest([[:space:]#]|$)|watchtower)' "$REPO_ROOT/ansible" "$REPO_ROOT/config" "$REPO_ROOT/monitoring"; then
  fail "forbidden moving tag or Watchtower configuration found"
fi

if [[ "$FAIL" -ne 0 ]]; then
  printf 'check-configs: FAILED\n' >&2
  exit 1
fi
printf 'check-configs: all passed\n'
