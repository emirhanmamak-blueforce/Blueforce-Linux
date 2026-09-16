#!/usr/bin/env bash
# Offline APT repository intake.
#
# Validate reviewed Debian packages and copy them into
# provisioning/offline-repo/packages/ so that they can be committed to git. The
# repository owner runs this on an Ubuntu machine; the device that later
# installs from the bundle never downloads anything.
#
# Guarantees:
#   * nothing is downloaded and nothing is resolved from a remote source,
#   * a file that is not a readable Debian binary package is refused,
#   * a package for a foreign architecture is refused (the target is amd64,
#     packages marked "all" are accepted),
#   * a second version of a package that is already accepted is refused instead
#     of silently overwritten: manifests/*.txt pin exactly one version,
#   * manifests/*.txt is never edited here. For every pin that still reads the
#     UNPINNED sentinel the exact replacement line is printed for the owner.
#
# --check performs the same validation without copying anything.
#
# User-facing output is Turkish; code and comments are English.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="$SCRIPT_DIR/packages"
TARGET_ARCH='amd64'
ALLOWED_ARCH_RE='^(amd64|all)$'
PACKAGE_NAME_RE='^[a-z0-9][a-z0-9+.-]*$'
PIN_RE='^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$'
UNPINNED='UNPINNED'

usage() {
  cat <<'EOF'
Kullanım: add-packages.sh [seçenekler] <dosya.deb> [<dosya.deb> ...]
          add-packages.sh --from DIZIN [--manifest DOSYA]

İncelenmiş .deb dosyalarını provisioning/offline-repo/packages/ altına ekler.
Hiçbir indirme yapmaz: dosyaları siz verirsiniz, bu araç yalnızca doğrular.

Seçenekler:
  --from DIZIN       DIZIN içindeki tüm *.deb dosyalarını aday olarak alır
  --manifest DOSYA   Yalnızca bu manifestteki pinlere uyan adayları ekler
                     (birden fazla --manifest verilebilir)
  --include-all      --manifest ile birlikte: pin dışı adayları da ekler
                     (bağımlılık paketleri için gerekir)
  --packages DIZIN   Hedef dizin (varsayılan: <script>/packages)
  --check            Ön izleme: hiçbir dosyayı kopyalamaz, yalnızca raporlar
  -h, --help         Bu yardımı yazar

Çıkış kodları: 0 başarılı, 1 doğrulama hatası, 2 kullanım hatası.
EOF
}

CHECK_ONLY=0
FROM_DIR=''
INCLUDE_ALL=0
declare -a MANIFEST_ARGS=() CANDIDATES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ -n "${2:-}" ]] || { printf 'HATA: --from için dizin adı verilmedi.\n' >&2; exit 2; }
      FROM_DIR="$2"; shift 2 ;;
    --manifest)
      [[ -n "${2:-}" ]] || { printf 'HATA: --manifest için dosya adı verilmedi.\n' >&2; exit 2; }
      MANIFEST_ARGS+=("$2"); shift 2 ;;
    --packages)
      [[ -n "${2:-}" ]] || { printf 'HATA: --packages için dizin adı verilmedi.\n' >&2; exit 2; }
      PACKAGES_DIR="$2"; shift 2 ;;
    --include-all) INCLUDE_ALL=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'HATA: bilinmeyen seçenek: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) CANDIDATES+=("$1"); shift ;;
  esac
done

if [[ -n "$FROM_DIR" ]]; then
  [[ -d "$FROM_DIR" ]] || { printf 'HATA: dizin bulunamadı: %s\n' "$FROM_DIR" >&2; exit 2; }
  while IFS= read -r -d '' deb; do CANDIDATES+=("$deb"); done \
    < <(find "$FROM_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  printf 'HATA: eklenecek .deb dosyası verilmedi.\n' >&2
  printf '      Örnek: ./add-packages.sh --from /secure/reviewed-debs\n' >&2
  usage >&2
  exit 2
fi

for manifest in "${MANIFEST_ARGS[@]}"; do
  [[ -f "$manifest" ]] || { printf 'HATA: manifest dosyası bulunamadı: %s\n' "$manifest" >&2; exit 2; }
done

# dpkg-deb is the only way to read a Debian control file; it exists on
# Ubuntu/Debian only, which is why this tool runs on the repository owner's
# machine and never on an Arch/CachyOS workstation.
if ! command -v dpkg-deb >/dev/null 2>&1; then
  cat >&2 <<'EOF'
HATA: dpkg-deb bulunamadı; .deb dosyaları bu araçla okunur.
      Bu araç yalnızca Ubuntu/Debian makinelerinde çalışır. Ubuntu 26.04
      makinesinde şunu kurun:
        sudo apt-get install -y dpkg
      CachyOS/Arch gibi bir makinede paketleri TOPLAYAMAZSINIZ; toplama işi
      Ubuntu makinesinde yapılır, depo dosyaları git ile taşınır.
EOF
  exit 1
fi

human_size() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s\n", b, unit[i]; else printf "%.1f %s\n", b, unit[i]
  }'
}

file_sha256() { sha256sum "$1" | awk '{print $1}'; }
file_size() { stat -c %s "$1" 2>/dev/null || wc -c < "$1"; }

# Read the essential control fields of one candidate. Sets DEB_PKG, DEB_VER,
# DEB_ARCH, DEB_SHA, DEB_SIZE and returns non-zero with a Turkish diagnostic.
inspect_deb() {
  local file="$1" raw
  DEB_PKG=''; DEB_VER=''; DEB_ARCH=''; DEB_SHA=''; DEB_SIZE=0

  if [[ ! -e "$file" ]]; then
    printf 'HATA: dosya bulunamadı: %s\n' "$file" >&2
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    printf 'HATA: bir dosya değil: %s\n' "$file" >&2
    return 1
  fi
  if [[ "$file" != *.deb ]]; then
    printf 'HATA: dosya adı .deb ile bitmiyor; Debian paketi değil: %s\n' "$file" >&2
    return 1
  fi
  if [[ ! -s "$file" ]]; then
    printf 'HATA: dosya boş (0 bayt): %s\n' "$file" >&2
    return 1
  fi
  if ! raw="$(dpkg-deb -f "$file" Package Version Architecture 2>&1)"; then
    printf 'HATA: geçerli bir Debian paketi okunamadı: %s\n' "$file" >&2
    printf '      dpkg-deb çıktısı: %s\n' "$raw" >&2
    return 1
  fi
  DEB_PKG="$(printf '%s\n' "$raw" | sed -n '1p')"
  DEB_VER="$(printf '%s\n' "$raw" | sed -n '2p')"
  DEB_ARCH="$(printf '%s\n' "$raw" | sed -n '3p')"

  if [[ ! "$DEB_PKG" =~ $PACKAGE_NAME_RE ]]; then
    printf 'HATA: paket adı geçersiz: "%s" (%s)\n' "$DEB_PKG" "$file" >&2
    return 1
  fi
  if [[ -z "$DEB_VER" || "$DEB_VER" == "$UNPINNED" || "$DEB_VER" == *[[:space:]]* ]]; then
    printf 'HATA: paket sürümü geçersiz: "%s" (%s)\n' "$DEB_VER" "$file" >&2
    return 1
  fi
  if [[ ! "$DEB_ARCH" =~ $ALLOWED_ARCH_RE ]]; then
    printf 'HATA: mimari uyumsuz: %s paketi "%s" için; hedef mimari %s.\n' \
      "$DEB_PKG" "$DEB_ARCH" "$TARGET_ARCH" >&2
    return 1
  fi
  DEB_SHA="$(file_sha256 "$file")"
  DEB_SIZE="$(file_size "$file")"
  return 0
}

declare -A EXISTING_SHA=() EXISTING_PKG=() EXISTING_PKG_SHA=() EXISTING_FILE=()

scan_existing() {
  local deb sha pkg ver
  [[ -d "$PACKAGES_DIR" ]] || return 0
  while IFS= read -r -d '' deb; do
    sha="$(file_sha256 "$deb")"
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    if [[ -z "$pkg" || -z "$ver" ]]; then
      printf 'UYARI: packages/ içindeki okunamayan dosya yok sayıldı: %s\n' "${deb##*/}" >&2
      continue
    fi
    EXISTING_SHA["$sha"]="$deb"
    EXISTING_PKG["$pkg"]="$ver"
    EXISTING_PKG_SHA["$pkg"]="$sha"
    EXISTING_FILE["$pkg"]="${deb##*/}"
  done < <(find "$PACKAGES_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
}

# Pin table of the manifests given with --manifest. Keys are package names.
declare -A PIN_VERSION=() PIN_MANIFEST=() PIN_SUPPLIED=()

load_pins() {
  local manifest line lineno pkg ver bad=0
  for manifest in "${MANIFEST_ARGS[@]}"; do
    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$((lineno + 1))
      if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
      if [[ ! "$line" =~ $PIN_RE ]]; then
        printf 'UYARI: %s:%d: pin biçimi geçersiz, yok sayıldı: %s\n' \
          "$(basename "$manifest")" "$lineno" "$line" >&2
        bad=$((bad + 1))
        continue
      fi
      pkg="${line%%=*}"
      ver="${line#*=}"
      if [[ -n "${PIN_VERSION[$pkg]:-}" ]]; then
        printf 'UYARI: %s paketi birden fazla manifestte pinli: %s ve %s\n' \
          "$pkg" "${PIN_MANIFEST[$pkg]}" "$(basename "$manifest")" >&2
      fi
      PIN_VERSION["$pkg"]="$ver"
      PIN_MANIFEST["$pkg"]="$(basename "$manifest")"
    done < "$manifest"
  done
  return 0
}

ADDED=0; WILL_ADD=0; SKIPPED=0; ERRORS=0; UNMATCHED=0; OFF_PIN=0
declare -a FILL_LINES=() UNSUPPLIED=() OFF_PIN_NAMES=()

scan_existing
if [[ ${#MANIFEST_ARGS[@]} -gt 0 ]]; then load_pins; fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf '=== Ön izleme (--check): hiçbir dosya kopyalanmaz ===\n'
else
  printf '=== Paket ekleme: %s ===\n' "${PACKAGES_DIR#$SCRIPT_DIR/}"
fi
printf 'Aday sayısı: %d\n\n' "${#CANDIDATES[@]}"

for file in "${CANDIDATES[@]}"; do
  base="${file##*/}"
  if ! inspect_deb "$file"; then
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Identical content already accepted, under any file name.
  if [[ -n "${EXISTING_SHA[$DEB_SHA]:-}" ]]; then
    printf 'ATLANDI: aynı dosya zaten repoda: %s (%s)\n' \
      "$base" "$(basename "${EXISTING_SHA[$DEB_SHA]}")"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # One version per package: manifests/*.txt carry a single pin per package.
  if [[ -n "${EXISTING_PKG[$DEB_PKG]:-}" ]]; then
    if [[ "${EXISTING_PKG[$DEB_PKG]}" == "$DEB_VER" ]]; then
      printf 'HATA: %s %s sürümü repoda farklı bir dosyayla duruyor: %s\n' \
        "$DEB_PKG" "$DEB_VER" "${EXISTING_FILE[$DEB_PKG]}"
      printf '      Aynı ad ve sürüm iki farklı içerikle kabul edilmez. Repodaki dosyayı inceleyin.\n'
    else
      printf 'HATA: çakışma: %s repoda %s sürümüyle duruyor (%s).\n' \
        "$DEB_PKG" "${EXISTING_PKG[$DEB_PKG]}" "${EXISTING_FILE[$DEB_PKG]}"
      printf '      Tek sürüm kuralı: yeni sürümü eklemek için önce eskiyi kaldırın:\n'
      printf '        rm "%s"\n' "$PACKAGES_DIR/${EXISTING_FILE[$DEB_PKG]}"
    fi
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [[ ${#MANIFEST_ARGS[@]} -gt 0 ]]; then
    if [[ -z "${PIN_VERSION[$DEB_PKG]:-}" ]]; then
      if [[ "$INCLUDE_ALL" -eq 1 ]]; then
        printf 'BİLGİ: pin dışı paket (bağımlılık) eklenecek: %s %s\n' "$DEB_PKG" "$DEB_VER"
      else
        printf 'ATLANDI: %s manifestte pinli değil (%s).\n' "$base" "$DEB_PKG"
        OFF_PIN_NAMES+=("$DEB_PKG $DEB_VER")
        OFF_PIN=$((OFF_PIN + 1))
        continue
      fi
    elif [[ "${PIN_VERSION[$DEB_PKG]}" == "$UNPINNED" ]]; then
      PIN_SUPPLIED["$DEB_PKG"]=1
      FILL_LINES+=("${PIN_MANIFEST[$DEB_PKG]}: $DEB_PKG=$DEB_VER")
    elif [[ "${PIN_VERSION[$DEB_PKG]}" != "$DEB_VER" ]]; then
      printf 'ATLANDI: %s için manifestte istenen sürüm farklı: %s (manifest: %s, dosya: %s)\n' \
        "$DEB_PKG" "${PIN_VERSION[$DEB_PKG]}" "$DEB_VER" "$base"
      UNMATCHED=$((UNMATCHED + 1))
      continue
    else
      PIN_SUPPLIED["$DEB_PKG"]=1
      printf 'PİN EŞLEŞTİ: %s=%s (%s)\n' "$DEB_PKG" "$DEB_VER" "${PIN_MANIFEST[$DEB_PKG]}"
    fi
  fi

  dest="$PACKAGES_DIR/$base"
  if [[ -e "$dest" ]] && [[ "$(file_sha256 "$dest")" != "$DEB_SHA" ]]; then
    printf 'HATA: hedef dosya farklı içerikle var: %s (elle müdahale gerekli)\n' "$dest"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    printf 'EKLENECEK: %s %s (%s, %s) <- %s\n' \
      "$DEB_PKG" "$DEB_VER" "$DEB_ARCH" "$(human_size "$DEB_SIZE")" "$file"
    WILL_ADD=$((WILL_ADD + 1))
  else
    mkdir -p "$PACKAGES_DIR"
    install -m 0644 -- "$file" "$dest"
    printf 'EKLENDİ: %s %s (%s, %s) -> packages/%s\n' \
      "$DEB_PKG" "$DEB_VER" "$DEB_ARCH" "$(human_size "$DEB_SIZE")" "$base"
    ADDED=$((ADDED + 1))
    EXISTING_SHA["$DEB_SHA"]="$dest"
    EXISTING_PKG["$DEB_PKG"]="$DEB_VER"
    EXISTING_PKG_SHA["$DEB_PKG"]="$DEB_SHA"
    EXISTING_FILE["$DEB_PKG"]="$base"
  fi
done

# Pins that this run received no .deb for: reported, never silently ignored.
if [[ ${#MANIFEST_ARGS[@]} -gt 0 ]]; then
  for pkg in "${!PIN_VERSION[@]}"; do
    ver="${PIN_VERSION[$pkg]}"
    if [[ -n "${PIN_SUPPLIED[$pkg]:-}" ]]; then continue; fi
    if [[ "$ver" != "$UNPINNED" && "${EXISTING_PKG[$pkg]:-}" == "$ver" ]]; then continue; fi
    if [[ "$ver" == "$UNPINNED" && -n "${EXISTING_PKG[$pkg]:-}" ]]; then
      FILL_LINES+=("${PIN_MANIFEST[$pkg]}: $pkg=${EXISTING_PKG[$pkg]} (repodaki sürüm)")
      continue
    fi
    UNSUPPLIED+=("${PIN_MANIFEST[$pkg]}: $pkg=$ver")
  done
fi

printf '\n'

if [[ ${#UNSUPPLIED[@]} -gt 0 ]]; then
  printf 'UYARI: şu manifest pinleri için .deb verilmedi:\n'
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${UNSUPPLIED[@]}" | sort)
  printf '  (Kalanları da ekleyin; build-index.sh eksik listesini tekrar gösterecek.)\n'
fi

if [[ ${#OFF_PIN_NAMES[@]} -gt 0 ]]; then
  printf 'BİLGİ: manifestte pini olmayan adaylar eklenmedi (%d):\n' "$OFF_PIN"
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${OFF_PIN_NAMES[@]}" | sort)
  printf '  Bağımlılık paketleriyse şununla çalıştırın: ./add-packages.sh --from <dizin> --manifest <dosya> --include-all\n'
fi

if [[ ${#FILL_LINES[@]} -gt 0 ]]; then
  printf 'MANIFEST GÜNCELLEMESİ GEREKİYOR (bu araç manifestleri değiştirmez):\n'
  printf '  Aşağıdaki satırlarda %s yerine gerçek sürümü yazın:\n' "$UNPINNED"
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${FILL_LINES[@]}" | sort -u)
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf '\nÖZET (ön izleme): eklenecek=%d atlanan=%d eşleşmeyen=%d hata=%d\n' \
    "$WILL_ADD" "$SKIPPED" "$UNMATCHED" "$ERRORS"
  printf 'Hiçbir dosya kopyalanmadı.\n'
else
  printf '\nÖZET: eklenen=%d atlanan=%d eşleşmeyen=%d hata=%d\n' \
    "$ADDED" "$SKIPPED" "$UNMATCHED" "$ERRORS"
  if [[ "$ADDED" -gt 0 ]]; then
    printf 'Sonraki adım:\n'
    printf '  1) manifests/*.txt içindeki pinleri güncelleyin (yukarıdaki liste).\n'
    printf '  2) ./build-index.sh ile offline indeksi üretin.\n'
    printf '  3) git add provisioning/offline-repo/packages provisioning/offline-repo/manifests\n'
  fi
fi

if [[ "$ERRORS" -gt 0 ]]; then
  printf 'SONUÇ: %d hata nedeniyle paket ekleme tamamlanmadı.\n' "$ERRORS" >&2
  exit 1
fi
exit 0
