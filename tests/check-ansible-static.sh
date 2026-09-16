#!/usr/bin/env bash
# Ansible playbook statik güvenlik kapısı (read-only; ansible-playbook kurulumu GEREKTİRMEZ).
# Denetledikleri:
#   1) 21 playbook envanteri (5 dalga işlemi + 5 rapor + 11 dokümante edilmiş tek-hedef/legacy) ve
#      sınıflandırılamayan yeni playbook'a kapalı kapı (fail-closed). Dalga işlemi ve rapor
#      playbook'ları TAM dalga kapısına tabidir ve hosts: blueforce kullanamaz; tek cihaz
#      teşhis/bakım playbook'ları (docs/09 hedefleme seviyeleri) hedef sınırlama talimatı
#      taşımak zorundadır -- bunları dalga kapısına taşımak ayrı bir değişikliktir, bu kapı onları
#      sessizce genişletmeye izin vermez.
#   2) dalga kapsamı kapısı: dinamik hosts dalgası, alt çizgili approved dalga listesi, onay
#      değişkeni, ansible_play_hosts_all kesişimi ve AYRI production_override (production için şart),
#   3) rapor playbook'larının read-only kalması (mutasyon modülü yok, shell/raw yok, her command
#      changed_when: false) ve operation_wave_gate ön kapısı,
#   4) moving tag (:latest) ve Watchtower yasağı,
#   5) bf-security-updates-check.yml'in report-only kalması,
#   6) tüm playbook + inventory YAML'larının parse ve yapı doğrulaması.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PB="$REPO_ROOT/ansible/playbooks"
INV="$REPO_ROOT/ansible/inventory/hosts.example.yml"
GV="$REPO_ROOT/ansible/inventory/group_vars/all.yml"
FAIL=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
pass() { printf 'OK: %s\n' "$*"; }

# --- 1) Envanter: 16 mevcut + 5 yeni rapor playbook = 21 -------------------------------------
WAVE_PLAYBOOKS=(bf-collect-logs.yml bf-deploy-update.yml bf-gui-off.yml bf-gui-on.yml bf-run-script.yml)
REPORT_PLAYBOOKS=(bf-fieldos-version.yml bf-provisioning-status.yml bf-enrollment-status.yml bf-remote-channels-check.yml bf-offline-ready-check.yml)
LEGACY_PLAYBOOKS=(bf-ping.yml bf-uptime.yml bf-reboot.yml bf-disk-check.yml bf-package-check.yml bf-security-updates-check.yml bf-docker-status.yml bf-service-restart.yml bf-wireguard-restart.yml bf-rdp-restart.yml bf-rustdesk-restart.yml)
ALL_PLAYBOOKS=("${WAVE_PLAYBOOKS[@]}" "${REPORT_PLAYBOOKS[@]}" "${LEGACY_PLAYBOOKS[@]}")
GATED_PLAYBOOKS=("${WAVE_PLAYBOOKS[@]}" "${REPORT_PLAYBOOKS[@]}")

if [[ ${#ALL_PLAYBOOKS[@]} -ne 21 ]]; then
  fail "playbook envanteri 21 olmalı, tanım ${#ALL_PLAYBOOKS[@]}"
fi
for pb in "${ALL_PLAYBOOKS[@]}"; do
  if [[ -f "$PB/$pb" ]]; then pass "present: $pb"; else fail "missing playbook: $pb"; fi
done

# Sınıflandırılamayan YENİ playbook kabul edilmez: dalga kapısı veya dokümante edilmiş istisna şart.
unclassified=0
while IFS= read -r -d '' asset; do
  base="$(basename "$asset")"
  known=0
  for pb in "${ALL_PLAYBOOKS[@]}"; do [[ "$base" == "$pb" ]] && known=1; done
  if [[ "$known" -ne 1 ]]; then
    fail "unclassified playbook (fail-closed): $base -- ya dalga kapısı (operation_wave/release_wave) taşımalı ya da dokümante edilmiş tek-hedef istisnası olmalı"
    unclassified=$((unclassified + 1))
  fi
done < <(find "$PB" -maxdepth 1 -type f -name '*.yml' -print0)
[[ "$unclassified" -eq 0 ]] && pass "playbook sınıflandırması tam: 21/21 (dalga kapılı veya dokümante edilmiş istisna)"

# --- 2) Dalga kapsamı kapısı + ayrı production_override --------------------------------------
APPROVED_LITERAL='[lab, pilot_1, pilot_2, wave_1, wave_2, production]'
for group in lab pilot_1 pilot_2 wave_1 wave_2 production; do
  grep -q "^[[:space:]]*$group:" "$INV" || fail "inventory dalga grubu eksik: $group"
done
if grep -nE '^[[:space:]]*(lab|pilot|wave|production)-[0-9A-Za-z]' "$INV"; then
  fail "inventory dalga grup adları ALT ÇİZGİLİ olmalı; tireli varyant yasak"
else
  pass "inventory dalga grupları alt çizgili (lab/pilot_1/pilot_2/wave_1/wave_2/production)"
fi

for pb in "${GATED_PLAYBOOKS[@]}"; do
  file="$PB/$pb"
  [[ -f "$file" ]] || continue
  if grep -qE '^  hosts: "\{\{ (operation_wave|release_wave) \| default\(' "$file"; then
    pass "$pb: dinamik dalga hosts deseni"
  else
    fail "$pb: hosts dalga desenini ({{ operation_wave|release_wave | default(...) }}) korumalı"
  fi
  grep -Fq "$APPROVED_LITERAL" "$file" || fail "$pb: approved dalga listesi birebir olmalı: $APPROVED_LITERAL"
  if grep -q -- 'operation_confirmed | bool' "$file" || grep -q -- 'wave_gate_confirmed | bool' "$file"; then
    pass "$pb: onay kapısı (operation_confirmed/wave_gate_confirmed) mevcut"
  else
    fail "$pb: onay kapısı eksik (operation_confirmed | bool)"
  fi
  grep -q 'ansible_play_hosts_all' "$file" || fail "$pb: seçilen hostlar ansible_play_hosts_all ile denetlenmeli"
  grep -q 'difference(groups\[' "$file" || fail "$pb: seçilen hostlar dalga grubundan fark olarak denetlenmeli (difference(groups[...]))"
  grep -q 'production_override: false' "$file" || fail "$pb: production_override varsayılan false olmalı"
  grep -q "'production' or production_override | bool" "$file" || fail "$pb: production dalgası AYRI production_override isteğini denetlemeli"
  if grep -qE '^  hosts: blueforce$' "$file"; then
    fail "$pb: hosts: blueforce (tüm filo) yasak; dalga kapsamı zorunlu"
  else
    pass "$pb: tüm-filo hedefi (hosts: blueforce) yok"
  fi
done

if grep -nE '(lab|pilot|wave|production)-[0-9]' "$PB"/*.yml; then
  fail "playbook'larda tireli dalga adı bulundu; alt çizgili grup adları zorunlu"
else
  pass "playbook'larda tireli dalga adı yok"
fi

# Rapor playbook'ları: operation_wave_gate ön kapısı (--limit mutabakatı dahil) zorunlu.
for pb in "${REPORT_PLAYBOOKS[@]}"; do
  file="$PB/$pb"
  [[ -f "$file" ]] || continue
  grep -Fq 'operation_wave_gate' "$file" || fail "$pb: operation_wave_gate ön kapısı eksik"
  grep -Fq 'hosts: "{{ ansible_limit | default(' "$file" || fail "$pb: dalga ön kapısı --limit ile mutabakat için ansible_limit deseni kullanmalı"
  grep -q 'does not intersect the' "$file" || fail "$pb: dalga/limit kesişim reddi (fail-closed mesajı) eksik"
done

# --- 3) Rapor playbook'ları read-only olmalı -------------------------------------------------
MUTATING_MODULES='ansible\.builtin\.(shell|raw|script|copy|template|file|lineinfile|replace|blockinfile|user|group|cron|mount|apt|apt_repository|apt_key|apt_repository_key|dpkg_selections|debconf|systemd|systemd_service|service|reboot|package|yum|dnf|pip|get_url|uri|unarchive|archive|git|hostname|sysctl|redhat_subscription|ufw|firewalld|nmcli|command_shell):'
for pb in "${REPORT_PLAYBOOKS[@]}"; do
  file="$PB/$pb"
  [[ -f "$file" ]] || continue
  if grep -nE "$MUTATING_MODULES" "$file"; then
    fail "$pb: read-only rapor playbook'unda mutasyon modülü bulundu"
  else
    pass "$pb: mutasyon modülü yok (stat/slurp/command/debug/assert/set_fact)"
  fi
  cmd_count="$(grep -c 'ansible\.builtin\.command:' "$file" || true)"
  cw_count="$(grep -c 'changed_when: false' "$file" || true)"
  if [[ "$cw_count" -ge "$cmd_count" ]]; then
    pass "$pb: command görevleri changed_when: false (${cmd_count} command / ${cw_count} changed_when)"
  else
    fail "$pb: her command görevi changed_when: false taşımalı (${cmd_count} command / ${cw_count} changed_when)"
  fi
  grep -qi 'read-only' "$file" || fail "$pb: başlıkta read-only sözleşmesi belirtilmeli"
  if grep -nE 'changed_when: true|state: (restarted|started|stopped|absent)|--force|git pull|docker pull|rm -rf|mkfs|dd if=' "$file"; then
    fail "$pb: read-only sözleşmesini bozan ifade bulundu"
  else
    pass "$pb: mutasyon/force ifadesi yok"
  fi
done

# --- 4) security-updates-check report-only kalmalı ------------------------------------------
SU="$PB/bf-security-updates-check.yml"
if [[ -f "$SU" ]]; then
  if grep -nE 'state:[[:space:]]*(present|latest)|^[[:space:]]*upgrade:|apt(-get)?[[:space:]].*[[:space:]]install|(apt-get|apt)[[:space:]].*dist-upgrade[[:space:]]*(-y|--assume-yes)|dpkg[[:space:]]+-i|unattended-upgrade[[:space:]]+--' "$SU"; then
    fail 'bf-security-updates-check.yml kurulum/yükseltme içeriyor; report-only kalmalı'
  else
    pass 'bf-security-updates-check.yml report-only (kurulum/yükseltme komutu yok)'
  fi
  grep -q 'REPORT ONLY' "$SU" && pass 'bf-security-updates-check.yml REPORT ONLY uyarısını koruyor' || fail 'bf-security-updates-check.yml REPORT ONLY uyarısı kaybolmuş'
  if grep -qE 'dist-upgrade' "$SU" && ! grep -q 'apt-get -s dist-upgrade' "$SU"; then
    fail 'bf-security-updates-check.yml dist-upgrade yalnız simülasyon (-s) olarak koşmalı'
  fi
fi

# Dalga kapısı taşımayan playbook'lar (tek cihaz teşhis/bakım; docs/09 hedefleme seviyeleri)
# en azından hedef sınırlama talimatı veya kendi kapsam assert'ini korumalı. Yeni ve
# sınıflandırılmamış bir playbook bu kapıdan geçemez (bkz. bölüm 1, fail-closed).
for pb in "${LEGACY_PLAYBOOKS[@]}"; do
  file="$PB/$pb"
  [[ -f "$file" ]] || continue
  if grep -q -- '--limit' "$file" || grep -q 'ansible.builtin.assert' "$file"; then
    pass "$pb: dalga dışı kullanım hedef sınırlama talimatı taşıyor (--limit veya kapsam assert'i)"
  else
    fail "$pb: dalga kapısı yok ve hedef sınırlama talimatı da yok (fail-closed)"
  fi
done

# --- 5) Moving tag / Watchtower yasağı -------------------------------------------------------
if grep -RniE --include='*.yml' --include='*.yaml' --include='*.json' \
  '^[[:space:]]*[^#].*(image:[^#]*:latest([[:space:]#]|$)|watchtower)' \
  "$REPO_ROOT/ansible" "$REPO_ROOT/config" "$REPO_ROOT/monitoring" "$REPO_ROOT/provisioning"; then
  fail 'moving tag (:latest) veya Watchtower (otomatik güncelleyici) yapılandırması bulundu'
else
  pass 'moving tag (:latest) ve Watchtower yasağı korunuyor'
fi
if grep -RniE --include='*.yml' 'image:[^#]*:latest' "$PB"; then
  fail "playbook'larda :latest etiketi bulundu"
else
  pass "playbook'larda sabitlenmemiş imaj etiketi yok"
fi

# --- 6) YAML parse + yapı doğrulaması -------------------------------------------------------
if python3 - "$REPO_ROOT" <<'PY'
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
playbooks = root / "ansible" / "playbooks"
problems = []

files = sorted(playbooks.glob("*.yml"))
if len(files) != 21:
    problems.append(f"expected 21 playbook YAML files, found {len(files)}")

for path in files:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - rapor amaçlı
        problems.append(f"{path.name}: YAML parse hatası: {exc}")
        continue
    if not isinstance(data, list) or not data:
        problems.append(f"{path.name}: en üst düzey play listesi olmalı")
        continue
    for index, play in enumerate(data):
        if not isinstance(play, dict):
            problems.append(f"{path.name}: play {index} mapping değil")
            continue
        if "hosts" not in play:
            problems.append(f"{path.name}: play {index} hosts anahtarı yok")
        if "tasks" not in play and "pre_tasks" not in play:
            problems.append(f"{path.name}: play {index} tasks/pre_tasks içermiyor")
        if not isinstance(play.get("hosts"), str) or not play.get("hosts", "").strip():
            problems.append(f"{path.name}: play {index} hosts boş veya metin değil")

for extra in (root / "ansible" / "inventory" / "hosts.example.yml", root / "ansible" / "inventory" / "group_vars" / "all.yml"):
    try:
        yaml.safe_load(extra.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - rapor amaçlı
        problems.append(f"{extra.name}: YAML parse hatası: {exc}")

if problems:
    print("\n".join(problems))
    sys.exit(1)
PY
then
  pass '21 playbook + inventory YAML parse ve yapı doğrulaması'
else
  fail 'YAML parse/yapı doğrulaması başarısız (yukarıdaki satırlar)'
fi

if [[ "$FAIL" -ne 0 ]]; then
  printf 'check-ansible-static: FAILED\n' >&2
  exit 1
fi
printf 'check-ansible-static: all passed\n'
