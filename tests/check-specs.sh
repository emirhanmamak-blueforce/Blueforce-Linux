#!/usr/bin/env bash
# Validate repository specifications and Ansible safety contracts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PB="$REPO_ROOT/ansible/playbooks"
ROLES="$REPO_ROOT/ansible/roles"
FAIL=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
pass() { printf 'OK: %s\n' "$*"; }

# The canonical documentation set is docs/00..NN. Adding a document is expected
# over time, so the set is derived from the tree instead of pinned to a literal:
# what must hold is that the numbering starts at 00 and has no gaps.
mapfile -t DOCS < <(printf '%s\n' "$REPO_ROOT"/docs/[0-9][0-9]-*.md | sort)
if [[ ${#DOCS[@]} -eq 0 ]]; then
  fail "no numbered docs found under docs/"
else
  highest=0
  for doc in "${DOCS[@]}"; do
    n="$(basename "$doc" | cut -c1-2)"
    n=$((10#$n))
    [[ $n -gt $highest ]] && highest=$n
  done
  for ((i = 0; i <= highest; i++)); do
    printf -v number '%02d' "$i"
    matches=("$REPO_ROOT"/docs/"$number"-*.md)
    [[ -f ${matches[0]} ]] || fail "missing numbered doc: $number (numbering must be gapless)"
  done
  pass "${#DOCS[@]} numbered docs present (00..$(printf '%02d' "$highest"), gapless)"
fi

# Docusaurus yalnız numaralı kanonik dokümanları yayımlamalıdır; şablon site içeriği değildir.
SYNC_SCRIPT="$REPO_ROOT/docs-site/sync-docs.sh"
SITE_DOCS="$REPO_ROOT/docs-site/docs"
if [[ ! -x "$SYNC_SCRIPT" ]]; then
  fail "docs-site sync script missing or not executable"
elif ! grep -Fq '[0-9][0-9]-*.md' "$SYNC_SCRIPT"; then
  fail "docs-site sync script must select only numbered Markdown files"
elif ! grep -Fq '_TEMPLATE.md is never site content' "$SYNC_SCRIPT"; then
  fail "docs-site sync script must explicitly exclude the template"
else
  pass "docs-site sync contract selects numbered docs and excludes the template"
fi
if [[ -f "$SITE_DOCS/_TEMPLATE.md" ]]; then
  fail "docs-site must not contain docs/_TEMPLATE.md"
else
  pass "docs-site template is absent"
fi

# Each numbered doc must retain ordered sections 1 through 13 and at least one diagram.
mermaid_total=0
for doc in "${DOCS[@]}"; do
  heading_list="$(grep -E '^## [0-9]+\.' "$doc" | sed -E 's/^## ([0-9]+)\..*/\1/' | paste -sd, -)"
  if [[ "$heading_list" != '1,2,3,4,5,6,7,8,9,10,11,12,13' ]]; then
    fail "non-sequential numbered headings in ${doc#$REPO_ROOT/}: ${heading_list:-none}"
  fi
  count="$(grep -c '^```mermaid$' "$doc" || true)"
  if [[ "$count" -lt 1 ]]; then
    fail "missing Mermaid block in ${doc#$REPO_ROOT/}"
  fi
  mermaid_total=$((mermaid_total + count))
done
# Every numbered doc carries at least one diagram. A fixed global total is
# deliberately not asserted: documents are added over time and a pinned sum turns
# a legitimate addition into a red test.
if [[ "$mermaid_total" -lt "${#DOCS[@]}" ]]; then
  fail "Mermaid count ($mermaid_total) is below the document count (${#DOCS[@]}); every doc needs a diagram"
else
  pass "${#DOCS[@]}/${#DOCS[@]} docs carry a diagram ($mermaid_total Mermaid blocks total)"
fi

EXPECTED_PLAYBOOKS=(bf-ping.yml bf-uptime.yml bf-reboot.yml bf-docker-status.yml bf-service-restart.yml bf-wireguard-restart.yml bf-rustdesk-restart.yml bf-rdp-restart.yml bf-collect-logs.yml bf-disk-check.yml bf-package-check.yml bf-security-updates-check.yml bf-deploy-update.yml bf-run-script.yml bf-gui-on.yml bf-gui-off.yml bf-fieldos-version.yml bf-provisioning-status.yml bf-enrollment-status.yml bf-remote-channels-check.yml bf-offline-ready-check.yml)
for pb in "${EXPECTED_PLAYBOOKS[@]}"; do
  [[ -f "$PB/$pb" ]] && pass "playbook present: $pb" || fail "missing playbook: $pb"
done

for role in common wireguard docker monitoring; do
  for file in tasks/main.yml defaults/main.yml README.md; do
    [[ -f "$ROLES/$role/$file" ]] && pass "role file present: $role/$file" || fail "missing role file: $role/$file"
  done
done

# Safety contracts from docs/09 and docs/10.
grep -q 'serial' "$PB/bf-reboot.yml" || fail 'bf-reboot.yml must batch hosts with serial'
grep -q 'any_errors_fatal: true' "$PB/bf-reboot.yml" || fail 'bf-reboot.yml must halt on errors'
grep -q 'release_wave' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must require a release wave'
grep -q 'wave_gate_confirmed' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must require a wave gate'
grep -q 'halt_on_fail' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must enforce halt_on_fail'
grep -q 'max_fail_percentage: 0' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must stop the wave on failure'
grep -q 'serial: 5' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must use the fixed batch size'
grep -q 'production_override' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must require a separate production override'
grep -q 'ansible_play_hosts_all' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must verify selected hosts against the release wave'
grep -q 'Run mandatory post-batch health gate' "$PB/bf-deploy-update.yml" || fail 'bf-deploy-update.yml must run a post-batch health gate'
for pb in bf-collect-logs.yml bf-gui-on.yml bf-run-script.yml bf-gui-off.yml; do
  grep -q 'operation_wave' "$PB/$pb" || fail "$pb must require operation_wave"
  grep -q 'operation_confirmed' "$PB/$pb" || fail "$pb must require operation_confirmed"
  grep -q 'ansible_play_hosts_all' "$PB/$pb" || fail "$pb must verify its selected hosts"
  grep -q 'production_override' "$PB/$pb" || fail "$pb must require a separate production override"
  grep -q "operation_wave != 'production' or production_override | bool" "$PB/$pb" || fail "$pb must refuse production without production_override=true"
done
if grep -q '^  hosts: blueforce$' "$PB/bf-gui-off.yml"; then
  fail 'bf-gui-off.yml must not target the blueforce group by default'
fi
grep -q '^operation_wave:' "$REPO_ROOT/ansible/inventory/group_vars/all.yml" || fail 'shared operation_wave variable missing'
grep -q '^operation_confirmed:' "$REPO_ROOT/ansible/inventory/group_vars/all.yml" || fail 'shared operation_confirmed variable missing'
for asset in config/firewall/blueforce-docker-user-restore.sh config/systemd/blueforce-docker-firewall.service config/systemd/docker.service.d/blueforce-docker-firewall.conf; do
  [[ -f "$REPO_ROOT/$asset" ]] || fail "missing persistent Docker firewall asset: $asset"
done
grep -q 'systemctl enable "$DOCKER_POLICY_UNIT"' "$REPO_ROOT/scripts/install/installer/modules/13-firewall.sh" || fail 'firewall module must enable persistent Docker firewall unit'
grep -q 'docker.service.d/blueforce-docker-firewall.conf' "$REPO_ROOT/scripts/install/installer/modules/13-firewall.sh" || fail 'firewall module must install Docker restart coupling'
grep -q 'DOCKER_POLICY_BIN" --check' "$REPO_ROOT/scripts/install/installer/modules/13-firewall.sh" || fail 'firewall module check must verify Docker policy rules'
grep -q '13-firewall' "$REPO_ROOT/scripts/install/installer/modules/18-final-check.sh" || fail 'final check must include the firewall rule verification gate'
grep -q 'bash "$SCRIPT_DIR/$g.sh" --check' "$REPO_ROOT/scripts/install/installer/modules/18-final-check.sh" || fail 'final check must execute every gate in check mode'
grep -q 'ctorigdstport' "$REPO_ROOT/config/firewall/blueforce-docker-user-restore.sh" || fail 'Docker firewall must consume published-port allowlist rules'
grep -q 'iptables -C DOCKER-USER' "$REPO_ROOT/config/firewall/blueforce-docker-user-restore.sh" || fail 'Docker firewall check must verify every installed allowlist rule'
grep -q -- '-i br+ -j RETURN' "$REPO_ROOT/config/firewall/blueforce-docker-user-restore.sh" || fail 'Docker firewall must permit egress from user-defined bridge interfaces'
grep -q '^BindsTo=docker.service$' "$REPO_ROOT/config/systemd/blueforce-docker-firewall.service" || fail 'Docker firewall service must bind to Docker lifecycle'
grep -q '^PartOf=docker.service$' "$REPO_ROOT/config/systemd/blueforce-docker-firewall.service" || fail 'Docker firewall service must restart with Docker'
grep -q '^Wants=blueforce-docker-firewall.service$' "$REPO_ROOT/config/systemd/docker.service.d/blueforce-docker-firewall.conf" || fail 'Docker must start the firewall service on every start'
grep -q 'BF_WG_HANDSHAKE_MAX_AGE' "$REPO_ROOT/scripts/install/installer/modules/06-wireguard.sh" || fail 'WireGuard module must enforce handshake freshness'
grep -q 'configured ||' "$REPO_ROOT/scripts/install/installer/modules/09-rustdesk.sh" || fail 'RustDesk module must prove client configuration'
grep -q 'service_allowlist' "$PB/bf-service-restart.yml" || fail 'bf-service-restart.yml must enforce an allowlist'
grep -q 'script_allowed_dirs' "$PB/bf-run-script.yml" || fail 'bf-run-script.yml must enforce allowed script paths'
grep -Fq "collect_logs_dir is match('^/var/lib/blueforce/support-bundles" "$PB/bf-collect-logs.yml" || fail 'bf-collect-logs.yml must restrict bundles to the approved support directory'
if [[ "$(grep -Fc '| quote' "$PB/bf-collect-logs.yml")" -lt 2 ]]; then
  fail 'bf-collect-logs.yml must shell-quote every generated bundle path'
fi

if grep -RniE --include='*.yml' '^[[:space:]]*[^#].*(image:[^#]*:latest([[:space:]#]|$)|watchtower)' "$PB" "$ROLES/docker"; then
  fail "forbidden moving tag or Watchtower configuration found in deploy paths"
else
  pass 'no moving tags or auto-updaters in deploy paths'
fi

if grep -qniE 'state:[[:space:]]*(present|latest)|apt-get .*(upgrade|dist-upgrade)[[:space:]]+-y|apt:.*name:' "$PB/bf-security-updates-check.yml"; then
  fail 'bf-security-updates-check.yml must remain report-only'
else
  pass 'security update check is report-only'
fi

# Field OS lifecycle and enrollment contracts must remain explicit and safe.
for asset in scripts/diagnostics/bf-enroll scripts/diagnostics/bf-enroll-now scripts/diagnostics/bf-enrollment-status scripts/diagnostics/bf-release scripts/diagnostics/bf-remote-status scripts/diagnostics/bf-check-local scripts/diagnostics/bf-check-enrollment scripts/diagnostics/bf-check-ready config/systemd/blueforce-enroll.service config/systemd/blueforce-enroll.timer; do
  [[ -f "$REPO_ROOT/$asset" ]] && pass "Field OS asset present: $asset" || fail "missing Field OS asset: $asset"
done
grep -q -- '--offline' "$REPO_ROOT/scripts/install/blueforce-install.sh" || fail 'installer must support --offline'
grep -q 'PROVISIONED_OFFLINE' "$REPO_ROOT/scripts/install/blueforce-install.sh" || fail 'installer must record PROVISIONED_OFFLINE'
grep -q 'BF_ADMIN_PUBLIC_KEY' "$REPO_ROOT/scripts/install/installer/modules/07-ssh.sh" || fail 'SSH module must accept an explicit admin public key only before hardening'
grep -q 'systemctl is-active --quiet xrdp' "$REPO_ROOT/scripts/install/installer/modules/08-rdp.sh" || fail 'RDP check must require active xrdp'
if grep -Eq 'systemctl (stop|disable) (xrdp|xrdp-sesman)' "$REPO_ROOT/scripts/maintenance/bf-gui-off"; then fail 'bf-gui-off must never stop or disable xRDP'; else pass 'bf-gui-off preserves xRDP'; fi
grep -q -- '--data-binary "@\$REQUEST_FILE"' "$REPO_ROOT/scripts/diagnostics/bf-enroll" || fail 'enrollment curl must consume the request file'
grep -q -- '-H @<(printf' "$REPO_ROOT/scripts/diagnostics/bf-enroll" || fail 'enrollment Authorization header must use process substitution'
if grep -q 'Authorization: Bearer \*\*\*' "$REPO_ROOT/scripts/diagnostics/bf-enroll"; then fail 'enrollment must not send a redacted literal Authorization value'; fi
grep -q 'central_verification' "$REPO_ROOT/scripts/diagnostics/bf-remote-status" || fail 'remote status must require central verification evidence'
if grep -q 'bf-enrollment-status\|phase="' "$REPO_ROOT/scripts/diagnostics/bf-remote-status"; then fail 'remote status must not infer proof from persisted lifecycle phase'; fi
grep -q 'UNAPPROVED_SKELETON' "$REPO_ROOT/scripts/diagnostics/bf-release" || fail 'release report must reject skeleton manifests'
"$REPO_ROOT/tests/test-field-os-lifecycle.sh" && pass 'Field OS lifecycle shell tests pass' || fail 'Field OS lifecycle shell tests failed'
grep -q 'PROVISIONED_OFFLINE.*ENROLLED.*READY' "$REPO_ROOT/scripts/diagnostics/bf-enrollment-status" || fail 'status must define canonical lifecycle states'
grep -q 'blueforce-install.sh' "$REPO_ROOT/provisioning/firstboot/bf-firstboot" && grep -q -- '--offline' "$REPO_ROOT/provisioning/firstboot/bf-firstboot" || fail 'firstboot must invoke offline installer after dealer ID validation'
grep -q 'BF_FIRSTBOOT_TEST_MODE' "$REPO_ROOT/provisioning/firstboot/bf-firstboot" || fail 'firstboot must provide mutation-free test mode'

if [[ "$FAIL" -ne 0 ]]; then
  printf 'check-specs: FAILED\n' >&2
  exit 1
fi
printf 'check-specs: all passed\n'
