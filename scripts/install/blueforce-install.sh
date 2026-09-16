#!/usr/bin/env bash
# Blueforce one-click installer — single entry point for field setup.
#
# The field operator runs one command and answers no technical question:
#
#   sudo ./scripts/install/blueforce-install.sh --dealer-id 12345678
#
# Packages always come from the local bundle the repository owner commits with
# the repository; nothing is downloaded at install time. The bundle is found
# automatically, in this order (the first complete candidate wins):
#
#   1. BF_OFFLINE_REPO                          operator override (must be valid),
#   2. <repo>/provisioning/offline-repo/built   bundle committed to this repo,
#   3. /opt/blueforce/offline-repo              bundle installed on the device.
#
# A missing or incomplete bundle stops the run before the first module, with a
# Turkish explanation, and changes nothing on the system (fail-closed).
#
# --offline is kept for backward compatibility (it used to be mandatory) but is
# no longer needed: it only forces the local bundle. --online exists for
# development/test hosts only and is never the default.
#
# User-facing messages are Turkish; code and comments are English.
# Exit codes: 0 success, 1 blocked or module failure, 2 usage error.
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DIR="$(cd "$INSTALLER_DIR/../.." && pwd)"
MODULES_DIR="$INSTALLER_DIR/installer/modules"
MANIFEST_DIR="$REPO_ROOT_DIR/provisioning/offline-repo/manifests"
BUNDLE_IN_REPO="$REPO_ROOT_DIR/provisioning/offline-repo/built"
BUNDLE_ON_DEVICE="/opt/blueforce/offline-repo"
README_REF="provisioning/offline-repo/README.md"
LOG_FILE="${LOG_FILE:-/var/log/blueforce-install.log}"
STATE_DIR="${STATE_DIR:-/var/lib/blueforce}"
STATE_FILE="$STATE_DIR/install-state"
MODULES=(01-precheck 02-system 03-user 04-hostname 05-network 06-wireguard 07-ssh 08-rdp 09-rustdesk 10-docker 11-meg 12-monitoring 13-firewall 14-update-policy 15-logrotate 16-gui 17-healthcheck 18-final-check)

DEALER_ID="" FROM="" ONLY="" CHECK_MODE=0 RESUME=0 ASSUME_YES=0 FORCE_OFFLINE=0 ONLINE=0
# The operator's override is remembered before any default is applied: an
# explicitly set path must fail closed instead of being replaced silently.
REPO_OVERRIDE="${BF_OFFLINE_REPO:-}"
REPO_DIR="" REPO_ORIGIN="" BF_OFFLINE=0
REPO_SEARCH=()

usage() {
  cat <<'EOF'
Kullanım: sudo ./blueforce-install.sh --dealer-id <8 haneli numara> [seçenekler]

Paketler bu betiğin yanındaki yerel paket deposundan gelir. İnternet, paket
indirme ve teknik bilgi gerekmez; tek zorunlu bilgi bayi numarasıdır:

  sudo ./blueforce-install.sh --dealer-id 12345678

Seçenekler:
  --dealer-id NUMARA   Zorunlu. 8 haneli bayi numarası (ana makine adı bf-NUMARA).
  --yes, -y            Onay sormadan başla (otomatik kurulum).
  --check              Salt okunur denetim: sistemde hiçbir şeyi değiştirmez.
  --from NN            NN numaralı modülden başla.
  --only AD            Yalnız belirtilen modülü çalıştır (örn. --only 05-network).
  --resume             Daha önce tamamlanmış modülleri atla.
  --help, -h           Bu yardımı yaz.

Yalnız geliştirme/test için (sahada gerekmez):
  --offline            Yerel depoyu kullanmayı zorla; varsayılan davranış zaten budur.
  --online             Paketleri internetten çeker. ÜRETİM cihazlarında KULLANMAYIN.

Paket deposu şu sırayla aranır: BF_OFFLINE_REPO ortam değişkeni, depodaki
provisioning/offline-repo/built dizini, /opt/blueforce/offline-repo.
Depo bulunamazsa kurulum başlamaz. Ayrıntı: scripts/install/README.md
EOF
}

log() {
  if [[ "$CHECK_MODE" -eq 1 ]]; then
    printf '[installer check] %s\n' "$1" >&2
  else
    mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [installer] $1" | tee -a "$LOG_FILE"
  fi
}
# notice: a message the operator must read. Always on stdout, and in apply mode
# also in the log file (the log stays the audit record of the run).
notice() {
  printf '%s\n' "$1"
  if [[ "$CHECK_MODE" -eq 0 ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s [installer] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE"
  fi
}
usage_error() { printf 'HATA: %s\n\n' "$1" >&2; usage >&2; exit 2; }
blocked_bundle() {
  printf 'OFFLINE BLOCKED: %s\n' "$1" >&2
  printf '   Depo       : %s\n' "${REPO_DIR:-tanımsız}" >&2
  printf '   Ne yapmalı : paket setini yeniden üretip git ile getirin (%s)\n' "$README_REF" >&2
  printf '   ÇIKIŞ NEDENİ: yerel paket deposu doğrulanamadı; kurulum başlamadı ve\n' >&2
  printf '                 sistemde hiçbir değişiklik yapılmadı.\n' >&2
  exit 1
}
record_state() { mkdir -p "$STATE_DIR"; local tmp="$STATE_FILE.tmp"; grep -v "^$1=" "$STATE_FILE" 2>/dev/null > "$tmp" || true; echo "$1=$2" >> "$tmp"; mv "$tmp" "$STATE_FILE"; }
state_of() { grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true; }

# ------------------------------------------------------- bundle discovery -----
human_size() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s\n", b, unit[i]; else printf "%.1f %s\n", b, unit[i]
  }'
}
repository_bytes() {
  local dir="$1" bytes
  bytes="$(du -sb "$dir" 2>/dev/null | awk '{print $1}')"
  if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
    bytes="$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}')"
  fi
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  printf '%s' "$bytes"
}
repository_package_count() {
  awk -F '\t' 'NR > 1 && NF >= 5 { n++ } END { printf "%d", n + 0 }' "$1/packages.lock.tsv"
}
repository_is_complete() {
  local repo="$1"
  [[ -n "$repo" && -d "$repo" && -s "$repo/Packages" && -s "$repo/Packages.gz" && -s "$repo/packages.lock.tsv" && -s "$repo/SHA256SUMS" ]]
}
# Fills REPO_DIR/REPO_ORIGIN and REPO_SEARCH (one readable line per candidate).
discover_offline_repository() {
  local -a dirs=() labels=()
  local i dir label
  if [[ -n "$REPO_OVERRIDE" ]]; then
    dirs=("$REPO_OVERRIDE"); labels=("BF_OFFLINE_REPO ortam değişkeni")
  else
    dirs=("$BUNDLE_IN_REPO" "$BUNDLE_ON_DEVICE")
    labels=("depodaki hazır paket seti" "cihazdaki kurulu paket deposu")
  fi
  for i in "${!dirs[@]}"; do
    dir="${dirs[$i]}"; label="${labels[$i]}"
    if [[ ! -e "$dir" ]]; then
      REPO_SEARCH+=("$label — yok: $dir")
      continue
    fi
    if repository_is_complete "$dir"; then
      REPO_DIR="$dir"; REPO_ORIGIN="$label"
      REPO_SEARCH+=("$label — kullanılabilir: $dir")
      return 0
    fi
    REPO_SEARCH+=("$label — eksik/bozuk: $dir (Packages, Packages.gz, packages.lock.tsv ve SHA256SUMS dosyalarının hepsi gerekli)")
  done
  return 1
}
report_missing_repository() {
  local entry
  printf 'HATA: Yerel paket deposu yok. Repo sorumlusuna başvurun: %s\n' "$README_REF" >&2
  printf '\n' >&2
  printf 'Kurulum paketleri yalnız yerel depodan kurar; bu makinede internetten paket\n' >&2
  printf 'alınmaz. Depo olmadığı için paket adımları çalışamaz.\n' >&2
  printf '\nAranan yerler:\n' >&2
  for entry in "${REPO_SEARCH[@]}"; do
    printf '  - %s\n' "$entry" >&2
  done
  printf '\nNe yapmalı:\n' >&2
  printf '  1) Paket setini git ile tam olarak getirin (repo sorumlusunun hazırladığı\n' >&2
  printf '     provisioning/offline-repo/built dizini) ya da repo sorumlusunun verdiği\n' >&2
  printf '     kopyayı /opt/blueforce/offline-repo altına koyun.\n' >&2
  printf '  2) Kurulumu yeniden çalıştırın: sudo ./blueforce-install.sh --dealer-id <numara>\n' >&2
  printf '\nKuruluma hiç başlanmadı; sistemde hiçbir değişiklik yapılmadı.\n' >&2
  printf 'ÇIKIŞ NEDENİ: yerel paket deposu bulunamadı.\n' >&2
  exit 1
}

# ------------------------------------------------------ bundle validation -----
# Fail-closed: every check has to pass before the first module runs. The local
# APT source and the pinned versions are the only package contract of the
# install, so a bundle that does not match its own lock file is refused.
validate_offline_repository() {
  local repo="$REPO_DIR" manifest pin package version source lpackage lversion larch lsha lsource
  [[ "$repo" = /* && -d "$repo" ]] || blocked_bundle 'BF_OFFLINE_REPO mutlak bir yerel dizin olmalıdır.'
  repository_is_complete "$repo" || blocked_bundle 'Yerel APT indeksi, kilit dosyası ya da checksum kaydı eksik; paket seti tamamlanmamış.'
  (cd "$repo" && sha256sum -c SHA256SUMS >/dev/null) || blocked_bundle 'Yerel APT deposunun checksum doğrulaması başarısız.'
  awk -F '\t' 'NR == 1 { if ($0 != "package\tversion\tarchitecture\tsha256\tsource") exit 1; next } $1 !~ /^[a-z0-9][a-z0-9+.-]*$/ || $2 == "" || $3 == "" || $4 !~ /^[a-f0-9]{64}$/ || $5 == "" { exit 1 } END { exit NR < 2 }' "$repo/packages.lock.tsv" || blocked_bundle 'Paket kilidi boş ya da biçimi bozuk.'
  # Every locked row must be present in the pool: the lock file is the SBOM the
  # bundle is installed from, so a row without its file is an incomplete set.
  while IFS=$'\t' read -r lpackage lversion larch lsha lsource; do
    [[ "$lpackage" == 'package' && "$lversion" == 'version' ]] && continue
    [[ -n "$lsource" && -f "$repo/pool/$lsource" ]] || blocked_bundle "Kilitte yazılı paket depoda yok: $lpackage $lversion ($lsource)."
  done < "$repo/packages.lock.tsv"
  # The pin manifests are the reviewed "what must be installed" contract of the
  # repository; when they travel with the checkout they are enforced too.
  if [[ -d "$MANIFEST_DIR" ]]; then
    for manifest in "$MANIFEST_DIR"/*.txt; do
      [[ -e "$manifest" ]] || continue
      [[ -s "$manifest" ]] || blocked_bundle "Gerekli pin manifestosu boş: $(basename "$manifest")."
      grep -qvE '^[[:space:]]*(#|$)' "$manifest" || blocked_bundle "Gerekli pin manifestosunda paket pini yok: $(basename "$manifest")."
      while IFS= read -r pin || [[ -n "$pin" ]]; do
        [[ -z "$pin" || "$pin" == \#* ]] && continue
        [[ "$pin" =~ ^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$ ]] && [[ "$pin" != *placeholder* && "$pin" != *REPLACE* && "$pin" != *replace* ]] || blocked_bundle "Geçersiz paket pini: $(basename "$manifest") içinde '$pin'."
        package="${pin%%=*}"; version="${pin#*=}"
        source="$(awk -F '\t' -v p="$package" -v v="$version" '$1 == p && $2 == v {print $5; exit}' "$repo/packages.lock.tsv")"
        [[ -n "$source" && -f "$repo/pool/$source" ]] || blocked_bundle "Pinlenen paket depoda yok: $package=$version."
      done < "$manifest"
    done
  else
    log "BİLGİ: pin manifestoları bu makinede yok; sözleşme packages.lock.tsv üzerinden doğrulandı."
  fi
  # The local APT source. --check stays read-only: its apt configuration lives
  # in a temporary directory and is removed on exit.
  if [[ "$CHECK_MODE" -eq 1 ]]; then
    CHECK_TMP="$(mktemp -d)"
    trap 'rm -rf "${CHECK_TMP:-}"' EXIT
    printf 'deb [trusted=yes] file:%s ./\n' "$repo" > "$CHECK_TMP/offline.list"
    BF_OFFLINE_APT_CONFIG="$CHECK_TMP/apt.conf"
    printf 'Dir::Etc::sourcelist "%s";\nDir::Etc::sourceparts "-";\nAcquire::Languages "none";\n' "$CHECK_TMP/offline.list" > "$BF_OFFLINE_APT_CONFIG"
    chmod 600 "$CHECK_TMP/offline.list" "$BF_OFFLINE_APT_CONFIG"
  else
    install -d -m 700 "$STATE_DIR"
    printf 'deb [trusted=yes] file:%s ./\n' "$repo" > "$STATE_DIR/offline.list"
    chmod 600 "$STATE_DIR/offline.list"
    BF_OFFLINE_APT_CONFIG="$(mktemp)"; chmod 600 "$BF_OFFLINE_APT_CONFIG"
    printf 'Dir::Etc::sourcelist "%s";\nDir::Etc::sourceparts "-";\nAcquire::Languages "none";\n' "$STATE_DIR/offline.list" > "$BF_OFFLINE_APT_CONFIG"
  fi
  export BF_OFFLINE_APT_CONFIG
}

# --------------------------------------------------------------- arguments ----
while [[ $# -gt 0 ]]; do case "$1" in
  --dealer-id) DEALER_ID="${2:-}"; shift 2;;
  --offline) FORCE_OFFLINE=1; shift;;
  --online) ONLINE=1; shift;;
  --from) FROM="${2:-}"; shift 2;;
  --only) ONLY="${2:-}"; shift 2;;
  --check) CHECK_MODE=1; shift;;
  --resume) RESUME=1; shift;;
  --yes|-y) ASSUME_YES=1; shift;;
  --help|-h) usage; exit 0;;
  *) usage_error "Bilinmeyen parametre: $1";;
esac; done
[[ -n "$DEALER_ID" ]] || usage_error 'Zorunlu parametre eksik: --dealer-id <8 haneli bayi numarası>. Örnek: sudo ./blueforce-install.sh --dealer-id 12345678'
[[ "$DEALER_ID" =~ ^[0-9]{8}$ ]] || usage_error "Geçersiz bayi numarası '$DEALER_ID': 8 haneli rakam olmalıdır (örn. 12345678)."
[[ "$FORCE_OFFLINE" -eq 1 && "$ONLINE" -eq 1 ]] && usage_error 'Bir kurulumda hem --offline hem --online verilemez.'

# ------------------------------------------------------------------- mode -----
# Default (no flag): find the local bundle and install from it. The flag the
# operator used to have to remember is now only a way to insist on it.
if [[ "$ONLINE" -eq 1 ]]; then
  BF_OFFLINE=0
  notice 'DİKKAT: --online yalnız geliştirme/test içindir. Paketler uzak APT kaynaklarından'
  notice '        çekilir; ÜRETİM cihazlarında KULLANMAYIN.'
  export BF_OFFLINE_REPO=""
else
  if ! discover_offline_repository; then
    report_missing_repository
  fi
  BF_OFFLINE=1
  notice "Yerel paket deposu bulundu: $(repository_package_count "$REPO_DIR") paket, $(human_size "$(repository_bytes "$REPO_DIR")")"
  notice "   Depo    : $REPO_DIR"
  notice "   Kaynak  : $REPO_ORIGIN"
  notice '   Kip     : yerel kurulum. İnternet, paket indirme ve ek anahtar gerekmez.'
  if [[ "$FORCE_OFFLINE" -eq 1 ]]; then
    log 'BİLGİ: --offline verildi; yerel depo zaten varsayılan kaynaktır.'
  fi
  validate_offline_repository
fi
export DEALER_ID BF_HOSTNAME="bf-${DEALER_ID}" BF_DEVICE="BF-${DEALER_ID}" STATE_DIR BF_OFFLINE BF_OFFLINE_REPO="${REPO_DIR:-}"

if [[ "$CHECK_MODE" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
  read -r -p "Kurulum $BF_DEVICE olarak başlatılsın mı? [e/H] " answer
  [[ "$answer" =~ ^[Ee]$ ]] || { echo 'Kurulum iptal edildi.'; exit 2; }
fi

RUN=(); for m in "${MODULES[@]}"; do
  if [[ -n "$ONLY" ]]; then [[ "$m" == "$ONLY" || "$m" == "$ONLY"* ]] && RUN+=("$m"); continue; fi
  [[ -n "$FROM" && "${m%%-*}" < "$FROM" ]] && continue
  if [[ "$CHECK_MODE" -eq 0 && "$RESUME" -eq 1 && "$(state_of "$m")" == OK ]]; then log "SKIP $m (already OK)"; continue; fi
  RUN+=("$m")
done
[[ ${#RUN[@]} -gt 0 ]] || { echo "No modules selected." >&2; exit 2; }
log "=== install start dealer=$BF_DEVICE mode=$([[ "$CHECK_MODE" -eq 1 ]] && echo check || echo apply) source=$([[ "$BF_OFFLINE" -eq 1 ]] && echo local || echo remote) modules=${RUN[*]} ==="
failures=0
for m in "${RUN[@]}"; do
 script="$MODULES_DIR/$m.sh"; if [[ ! -x "$script" ]]; then log "FAIL $m (script missing)"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" FAIL; failures=$((failures+1)); break; fi
 args=(); [[ "$CHECK_MODE" -eq 1 ]] && args+=(--check)
 set +e; if [[ "$CHECK_MODE" -eq 1 ]]; then LOG_FILE=/dev/null bash "$script" "${args[@]}"; else LOG_FILE="$LOG_FILE" bash "$script"; fi; rc=$?; set -e
 case "$rc" in 0) log "OK $m"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" OK;; 3) log "SKIP $m"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" SKIP;; *) log "FAIL $m (exit $rc)"; [[ "$CHECK_MODE" -eq 0 ]] && record_state "$m" FAIL; failures=$((failures+1)); [[ "$CHECK_MODE" -eq 0 ]] && exit 1;; esac
done
[[ "$CHECK_MODE" -eq 1 && "$failures" -gt 0 ]] && exit 1
if [[ "$CHECK_MODE" -eq 0 && "$BF_OFFLINE" -eq 1 && "$failures" -eq 0 ]]; then
  install -d -m 700 "$STATE_DIR"
  umask 077
  python3 - "$STATE_DIR/state.json" "$DEALER_ID" <<'PY'
import json, os, sys, tempfile, uuid
path, dealer = sys.argv[1:]
state={'phase':'PROVISIONED_OFFLINE','enrollment_status':'PENDING','fleet_status':'PENDING','device_id':'BF-'+dealer,'provisioning_id':str(uuid.uuid4())}
fd,tmp=tempfile.mkstemp(prefix='state.json.',dir=os.path.dirname(path)); os.fchmod(fd,0o600)
with os.fdopen(fd,'w') as f: json.dump(state,f,sort_keys=True); f.write('\n')
os.replace(tmp,path)
PY
  chmod 600 "$STATE_DIR/state.json"
  log "OFFLINE COMPLETE: device is PROVISIONED_OFFLINE; enrollment is required before READY"
  notice "Kurulum tamam: $BF_DEVICE yerel paket deposundan kuruldu."
  notice 'Cihaz şu an PROVISIONED_OFFLINE durumunda; kayıt (enrollment) tamamlanana kadar READY sayılmaz.'
fi
log "=== install done dealer=$BF_DEVICE failures=$failures ==="
