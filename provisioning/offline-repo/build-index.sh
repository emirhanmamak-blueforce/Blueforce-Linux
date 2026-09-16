#!/usr/bin/env bash
# Build the offline APT repository bundle that is committed to git.
#
# Input : <packages dir>/*.deb      reviewed packages accepted by add-packages.sh
# Output: <output dir>/pool/*.deb   copy of every package
#         <output dir>/Packages     APT index of the pool (apt-ftparchive)
#         <output dir>/Packages.gz  gzip of the index, timestamp free
#         <output dir>/packages.lock.tsv  SBOM: package/version/architecture/sha256/source
#         <output dir>/SHA256SUMS   digests of the three index files
#         <repo>/repo-manifest.yaml  repository record (release, arch, sizes, packages)
#
# The bundle layout is exactly what scripts/install/blueforce-install.sh --offline
# validates in /opt/blueforce/offline-repo, so the device that installs from it
# never needs a package source of its own.
#
# Guarantees:
#   * nothing is downloaded and no dependency is resolved from a remote source,
#   * every manifest pin must be satisfied by a pool package with the exact
#     version, otherwise no bundle is written and the gaps are listed in Turkish,
#   * the index is written in a canonical order and gzip carries no timestamp, so
#     re-running over the same pool leaves the bundle byte-identical (the bundle
#     is committed, so a stable rebuild keeps git diffs empty),
#   * an existing output directory is only replaced when it holds a previous
#     bundle of ours and no foreign file,
#   * the result is verified with `sha256sum -c SHA256SUMS` before it is reported.
#
# User-facing output is Turkish; code and comments are English.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGES_DIR="$SCRIPT_DIR/packages"
OUTPUT="$SCRIPT_DIR/built"
# BF_MANIFEST_DIR points a test run at a fixture directory; a real build always
# reads the reviewed manifests next to this script.
MANIFEST_DIR="${BF_MANIFEST_DIR:-$SCRIPT_DIR/manifests}"
MANIFEST_OUT="$SCRIPT_DIR/repo-manifest.yaml"
TARGET_ARCH='amd64'
ALLOWED_ARCH_RE='^(amd64|all)$'
PACKAGE_NAME_RE='^[a-z0-9][a-z0-9+.-]*$'
PIN_RE='^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$'
PIN_PLACEHOLDER_RE='(placeholder|replace|todo|tbd|fixme|changeme|fillme|example)'
LOCK_HEADER="$(printf 'package\tversion\tarchitecture\tsha256\tsource')"
UNPINNED='UNPINNED'
SCHEMA_VERSION=1
# Entries an output directory may hold without being treated as foreign.
ALLOWED_ENTRIES='pool Packages Packages.gz packages.lock.tsv SHA256SUMS .gitkeep'

usage() {
  cat <<'EOF'
Kullanım: build-index.sh [seçenekler]

packages/ altındaki .deb dosyalarından git'e girecek offline APT deposunu üretir.

Seçenekler:
  --packages DIZIN     Kaynak paket dizini (varsayılan: <script>/packages)
  --output DIZIN       Çıktı dizini (varsayılan: <script>/built)
  --manifest-dir DIZIN Pin manifestlerinin dizini (varsayılan: <script>/manifests)
  --manifest-out DOSYA repo-manifest.yaml yolu (varsayılan: <script>/repo-manifest.yaml)
  --check              Yalnızca doğrular: hiçbir şey yazmaz, eksikleri listeler
  -h, --help           Bu yardımı yazar

Çıkış kodları: 0 başarılı, 1 eksik paket ya da araç, 2 kullanım hatası.

Bu araç hiçbir şey indirmez. apt-ftparchive (paket: apt-utils) ve dpkg-deb
(paket: dpkg) Ubuntu makinesinde kurulu olmalıdır.
EOF
}

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --packages)        [[ -n "${2:-}" ]] || { printf 'HATA: --packages için dizin verilmedi.\n' >&2; exit 2; }; PACKAGES_DIR="$2"; shift 2 ;;
    --output)          [[ -n "${2:-}" ]] || { printf 'HATA: --output için dizin verilmedi.\n' >&2; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --manifest-dir)    [[ -n "${2:-}" ]] || { printf 'HATA: --manifest-dir için dizin verilmedi.\n' >&2; exit 2; }; MANIFEST_DIR="$2"; shift 2 ;;
    --manifest-out)    [[ -n "${2:-}" ]] || { printf 'HATA: --manifest-out için dosya verilmedi.\n' >&2; exit 2; }; MANIFEST_OUT="$2"; shift 2 ;;
    --check)           CHECK_ONLY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) printf 'HATA: bilinmeyen seçenek: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

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
yq() { local v="$1"; printf "'%s'" "${v//\'/\'\'}"; }
# Paths in the report are printed relative to the repository root, so the printed
# git commands work no matter which directory the build was started from.
rel_to_repo() {
  local path="$1"
  if [[ "$path" == "$REPO_ROOT/"* ]]; then printf '%s' "${path#"$REPO_ROOT"/}"; else printf '%s' "$path"; fi
}
now_utc() {
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Canonical stanza order: Package, then Version, then the order apt-ftparchive
# produced (kept as a tie breaker for two builds of one version). Paragraph
# newlines travel through one line of `sort` escaped as 0x1e and are restored
# afterwards, so no external tool has to understand Packages paragraphs.
canonicalize_stanzas() {
  awk '
    BEGIN { RS = ""; FS = "\n" }
    {
      pkg = ""; ver = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) pkg = substr($i, 10)
        else if ($i ~ /^Version: /) ver = substr($i, 10)
      }
      body = $0
      gsub(/\n/, "\036", body)
      printf "%s\t%s\t%06d\t%s\n", pkg, ver, ++n, body
    }
  ' | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 | awk -F '\t' '
    {
      body = $4
      gsub(/\036/, "\n", body)
      if (NR > 1) printf "\n"
      printf "%s\n", body
    }
  '
}

if ! command -v dpkg-deb >/dev/null 2>&1; then
  cat >&2 <<'EOF'
HATA: dpkg-deb bulunamadı; .deb dosyalarının künyesi bu araçla okunur.
      Ubuntu 26.04 makinesinde şunu kurun: sudo apt-get install -y dpkg
      CachyOS/Arch gibi bir makinede apt aracı yoktur; indeks Ubuntu
      makinesinde üretilir, sonuç git ile taşınır.
EOF
  exit 1
fi
if [[ "$CHECK_ONLY" -eq 0 ]] && ! command -v apt-ftparchive >/dev/null 2>&1; then
  cat >&2 <<'EOF'
HATA: apt-ftparchive bulunamadı; APT indeksi bu araçla üretilir.
      Ubuntu 26.04 makinesinde kurulum:
        sudo apt-get install -y apt-utils
      Doğrulama yapmak istiyorsanız ve indeks üretmeyecekseniz:
        ./build-index.sh --check
EOF
  exit 1
fi

[[ -d "$PACKAGES_DIR" ]] || { printf 'HATA: paket dizini yok: %s\n' "$PACKAGES_DIR" >&2; exit 2; }
[[ "$OUTPUT" = /* ]] || OUTPUT="$PWD/$OUTPUT"
[[ "$OUTPUT" != '/' && "$OUTPUT" != "$HOME" && "$OUTPUT" != "$SCRIPT_DIR" && "$OUTPUT" != "$SCRIPT_DIR/packages" && "$OUTPUT" != "$SCRIPT_DIR/manifests" ]] \
  || { printf 'HATA: --output güvenli olmayan bir dizini gösteriyor: %s\n' "$OUTPUT" >&2; exit 2; }

printf '=== Blueforce offline APT deposu derlemesi ===\n'
printf 'Paket dizini : %s\n' "$PACKAGES_DIR"
printf 'Manifestler  : %s\n' "$MANIFEST_DIR"
printf 'Çıktı dizini : %s\n\n' "$OUTPUT"

# ---------------------------------------------------------------- manifest contract
declare -A PIN_VERSION=() PIN_MANIFEST=()
declare -a PIN_ORDER=() MANIFEST_NAMES=() PIN_ERRORS=() AWAITING=()
declare -a RELEASES=() DECLARED_ARCHS=()
PIN_TOTAL=0

if [[ ! -d "$MANIFEST_DIR" ]]; then
  printf 'HATA: manifest dizini yok: %s\n' "$MANIFEST_DIR" >&2
  exit 1
fi

while IFS= read -r -d '' manifest; do
  name="$(basename "$manifest")"
  MANIFEST_NAMES+=("$name")
  if [[ ! -s "$manifest" ]]; then
    PIN_ERRORS+=("$name: manifest boş; offline kurucu boş manifest ile başlamaz")
    continue
  fi
  # Header contract: every manifest names its release and architecture.
  release_line="$(sed -n 's/^# *Target release *: *//p' "$manifest" | head -n 1)"
  if [[ -n "$release_line" ]]; then
    RELEASES+=("$(printf '%s' "$release_line" | grep -oE '[0-9]+\.[0-9]+' | head -n 1)")
    declared_arch="$(printf '%s' "$release_line" | grep -oE 'amd64|arm64|armhf|i386' | head -n 1)"
    if [[ -n "$declared_arch" ]]; then
      DECLARED_ARCHS+=("$declared_arch")
      if [[ "$declared_arch" != "$TARGET_ARCH" ]]; then
        PIN_ERRORS+=("$name: hedef mimari $declared_arch; bu depo yalnızca $TARGET_ARCH üretir")
      fi
    fi
  else
    PIN_ERRORS+=("$name: '# Target release :' satırı yok; hedef Ubuntu sürümü belirsiz")
  fi

  lineno=0
  pins_in_file=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
    if [[ ! "$line" =~ $PIN_RE ]]; then
      PIN_ERRORS+=("$name:$lineno: tam pin değil (package=version beklenir): $line")
      continue
    fi
    if [[ "${line,,}" =~ $PIN_PLACEHOLDER_RE ]]; then
      PIN_ERRORS+=("$name:$lineno: pin içinde yer tutucu var: $line")
      continue
    fi
    package="${line%%=*}"
    version="${line#*=}"
    PIN_TOTAL=$((PIN_TOTAL + 1))
    pins_in_file=$((pins_in_file + 1))
    if [[ -n "${PIN_VERSION[$package]:-}" ]]; then
      PIN_ERRORS+=("$name:$lineno: $package iki kez pinlenmiş (ilki: ${PIN_MANIFEST[$package]})")
    else
      PIN_VERSION["$package"]="$version"
      PIN_MANIFEST["$package"]="$name"
      PIN_ORDER+=("$package")
    fi
    if [[ "${version^^}" == "$UNPINNED" || ! "$version" =~ [0-9] ]]; then
      AWAITING+=("$name: $package=$version")
    fi
  done < "$manifest"
  if [[ "$pins_in_file" -eq 0 ]]; then
    PIN_ERRORS+=("$name: hiç paket pini yok")
  fi
done < <(find "$MANIFEST_DIR" -maxdepth 1 -type f -name '*.txt' -print0 | sort -z)

if [[ ${#PIN_ORDER[@]} -eq 0 ]]; then
  printf 'HATA: hiç pin okunamadı (%s içinde *.txt yok).\n' "$MANIFEST_DIR" >&2
  exit 1
fi

unique_releases="$(printf '%s\n' "${RELEASES[@]:-}" | grep -v '^$' | sort -u | tr '\n' ' ')"
release_count="$(printf '%s\n' "${RELEASES[@]:-}" | grep -v '^$' | sort -u | grep -c . || true)"
if [[ "$release_count" -gt 1 ]]; then
  PIN_ERRORS+=("manifestler farklı Ubuntu sürümü belirtiyor: $unique_releases")
fi
UBUNTU_RELEASE="$(printf '%s\n' "${RELEASES[@]:-}" | grep -v '^$' | sort -u | head -n 1)"
[[ -n "$UBUNTU_RELEASE" ]] || UBUNTU_RELEASE='unknown'

# ----------------------------------------------------------------------- package pool
declare -A POOL_VER=() POOL_SHA=() POOL_ARCH=() POOL_SIZE=() POOL_SOURCE=()
declare -a POOL_ORDER=() POOL_ERRORS=() FOREIGN=()
POOL_TOTAL=0
TOTAL_BYTES=0

if [[ -n "${PIN_ERRORS[*]:-}" ]]; then
  printf 'HATA: manifest sözleşmesi bozuk; derleme yapılmadı:\n'
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${PIN_ERRORS[@]}" | sort)
  exit 1
fi

while IFS= read -r -d '' deb; do
  base="$(basename "$deb")"
  raw="$(dpkg-deb -f "$deb" Package Version Architecture 2>/dev/null || true)"
  package="$(printf '%s\n' "$raw" | sed -n '1p')"
  version="$(printf '%s\n' "$raw" | sed -n '2p')"
  arch="$(printf '%s\n' "$raw" | sed -n '3p')"
  if [[ ! "$package" =~ $PACKAGE_NAME_RE || -z "$version" ]]; then
    POOL_ERRORS+=("$base: geçerli bir Debian paketi okunamadı; add-packages.sh ile ekleyin")
    continue
  fi
  if [[ ! "$arch" =~ $ALLOWED_ARCH_RE ]]; then
    FOREIGN+=("$base: $package $version ($arch)")
    continue
  fi
  sha="$(file_sha256 "$deb")"
  size="$(file_size "$deb")"
  if [[ -n "${POOL_SHA["$package:$version"]:-}" ]]; then
    if [[ "${POOL_SHA["$package:$version"]}" != "$sha" ]]; then
      POOL_ERRORS+=("$base: $package $version repoda farklı içerikle var (${POOL_SOURCE["$package:$version"]})")
    fi
    continue
  fi
  POOL_SHA["$package:$version"]="$sha"
  POOL_VER["$package"]="$version"
  POOL_ARCH["$package:$version"]="$arch"
  POOL_SIZE["$package:$version"]="$size"
  POOL_SOURCE["$package:$version"]="$base"
  POOL_ORDER+=("$package:$version")
  POOL_TOTAL=$((POOL_TOTAL + 1))
  TOTAL_BYTES=$((TOTAL_BYTES + size))
done < <(find "$PACKAGES_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)

if [[ ${#FOREIGN[@]} -gt 0 ]]; then
  printf 'HATA: repoda hedef mimari (%s) dışında paket var; bu paketler indekse girmez:\n' "$TARGET_ARCH"
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${FOREIGN[@]}" | sort)
  printf '      Bu dosyaları packages/ altından kaldırın ya da doğru mimari sürümünü ekleyin.\n'
  exit 1
fi

if [[ "$POOL_TOTAL" -eq 0 ]]; then
  printf 'HATA: %s içinde .deb dosyası yok.\n' "$PACKAGES_DIR"
  printf '      Önce paketleri ekleyin: ./add-packages.sh --from <dizin>\n'
  exit 1
fi

# ------------------------------------------------------------- pins vs. pool matching
declare -a MISSING=() EXTRA_PACKAGES=()
for package in "${PIN_ORDER[@]}"; do
  version="${PIN_VERSION[$package]}"
  manifest="${PIN_MANIFEST[$package]}"
  if [[ "${version^^}" == "$UNPINNED" ]]; then
    MISSING+=("$manifest: $package=$version -> manifestte sürüm hâlâ doldurulmadı (diğer adı: $UNPINNED)")
    continue
  fi
  if [[ -z "${POOL_SHA["$package:$version"]:-}" ]]; then
    if [[ -n "${POOL_VER[$package]:-}" ]]; then
      MISSING+=("$manifest: $package=$version -> repoda bu sürüm yok (repodaki sürüm: ${POOL_VER[$package]})")
    else
      MISSING+=("$manifest: $package=$version -> paket repoda hiç yok")
    fi
  fi
done

# Packages in the pool that no manifest pin mentions: dependencies are expected
# here, so this is informational and never a failure.
for key in "${POOL_ORDER[@]}"; do
  package="${key%%:*}"
  [[ -z "${PIN_VERSION[$package]:-}" ]] || continue
  EXTRA_PACKAGES+=("$package ${key#*:}")
done

printf 'Bulunan paket : %d (%s)\n' "$POOL_TOTAL" "$(human_size "$TOTAL_BYTES")"
printf 'Pin sayısı    : %d\n' "${#PIN_ORDER[@]}"
printf 'Manifestler   : %s\n\n' "${MANIFEST_NAMES[*]}"

if [[ ${#POOL_ERRORS[@]} -gt 0 ]]; then
  printf 'HATA: paket havuzunda tutarsızlık var:\n'
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${POOL_ERRORS[@]}" | sort)
  exit 1
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  printf 'HATA: manifestlerde istenen şu paketler eksik (%d):\n' "${#MISSING[@]}"
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${MISSING[@]}" | sort)
  printf '\nEksik paketler giderilmeden indeks YAZILMADI.\n'
  printf 'Bu eksiklerle kurulum yapılırsa kurucu OFFLINE BLOCKED ile durur.\n'
  printf 'Sırayla yapılacaklar:\n'
  printf '  1) ./add-packages.sh --from <incelenmiş-deb-dizini> --manifest manifests/<dosya>\n'
  printf '  2) manifests/*.txt içindeki %s satırlarını gerçek sürümle doldurun\n' "$UNPINNED"
  printf '  3) ./build-index.sh\n'
  exit 1
fi
printf 'OK: %d pinin tamamı repodaki paketlerle eşleşti.\n' "${#PIN_ORDER[@]}"
if [[ ${#EXTRA_PACKAGES[@]} -gt 0 ]]; then
  printf 'BİLGİ: pin dışı %d paket var (bağımlılık kapatması için normaldir):\n' "${#EXTRA_PACKAGES[@]}"
  while IFS= read -r line; do printf '  - %s\n' "$line"; done < <(printf '%s\n' "${EXTRA_PACKAGES[@]}" | sort)
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf '\nSONUÇ (--check): sözleşme tamam; hiçbir şey yazılmadı. Derlemek için: ./build-index.sh\n'
  exit 0
fi

# --------------------------------------------------------------------------- staging
STAGE="$(mktemp -d "$(dirname "$OUTPUT")/.build-index.XXXXXX")"
cleanup() { if [[ -n "${STAGE:-}" && -d "${STAGE:-}" ]]; then rm -rf "$STAGE"; fi; }
trap cleanup EXIT

mkdir -p "$STAGE/pool"
if [[ -f "$OUTPUT/.gitkeep" ]]; then cp -- "$OUTPUT/.gitkeep" "$STAGE/.gitkeep"; fi

lock="$STAGE/packages.lock.tsv"
printf '%s\n' "$LOCK_HEADER" > "$lock"
while IFS= read -r key; do
  deb="$PACKAGES_DIR/${POOL_SOURCE[$key]}"
  cp -- "$deb" "$STAGE/pool/${POOL_SOURCE[$key]}"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${key%%:*}" "${key#*:}" "${POOL_ARCH[$key]}" "${POOL_SHA[$key]}" "${POOL_SOURCE[$key]}" >> "$lock"
done < <(printf '%s\n' "${POOL_ORDER[@]}" | LC_ALL=C sort -t: -k1,1 -k2,2)

( cd "$STAGE" && apt-ftparchive packages pool > raw-packages )
canonicalize_stanzas < "$STAGE/raw-packages" > "$STAGE/Packages"
rm -f "$STAGE/raw-packages"
gzip -n -9 -c "$STAGE/Packages" > "$STAGE/Packages.gz"
( cd "$STAGE" && sha256sum Packages Packages.gz packages.lock.tsv > SHA256SUMS )
( cd "$STAGE" && sha256sum -c SHA256SUMS >/dev/null ) \
  || { printf 'HATA: üretilen indeks kendi checksum kaydıyla doğrulanamadı.\n' >&2; exit 1; }
printf 'OK: indeks üretildi ve doğrulandı: Packages, Packages.gz, packages.lock.tsv, SHA256SUMS\n'

# ------------------------------------------------------- replace the output directory
if [[ -e "$OUTPUT" ]]; then
  if [[ -L "$OUTPUT" || ! -d "$OUTPUT" ]]; then
    printf 'HATA: çıktı yolu bir dizin değil ya da sembolik bağ: %s\n' "$OUTPUT" >&2
    exit 1
  fi
  foreign=0
  while IFS= read -r entry; do
    known=0
    for allowed in $ALLOWED_ENTRIES; do
      [[ "$entry" == "$allowed" ]] && known=1
    done
    if [[ "$known" -eq 0 ]]; then
      printf 'HATA: çıktı dizininde bu depoya ait olmayan dosya var: %s/%s\n' "$OUTPUT" "$entry" >&2
      foreign=1
    fi
  done < <(find "$OUTPUT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  if [[ "$foreign" -eq 1 ]]; then
    printf '      Yanlışlıkla dosya silmemek için derleme durduruldu. Dizini boşaltın ya da --output kullanın.\n' >&2
    exit 1
  fi
  if diff -rq -- "$OUTPUT" "$STAGE" >/dev/null 2>&1; then
    UNCHANGED=1
  else
    UNCHANGED=0
  fi
else
  UNCHANGED=0
fi

if [[ "$UNCHANGED" -eq 1 ]]; then
  printf 'DEĞİŞİKLİK YOK: %s zaten bu paketlerle birebir aynı; dizin yeniden yazılmadı.\n' "$(rel_to_repo "$OUTPUT")"
else
  rm -rf "$OUTPUT"
  mv -- "$STAGE" "$OUTPUT"
  STAGE=''
  printf 'OK: depo yazıldı: %s\n' "$(rel_to_repo "$OUTPUT")"
fi

PKG_PACKAGES_SHA="$(file_sha256 "$OUTPUT/Packages")"
PKG_GZ_SHA="$(file_sha256 "$OUTPUT/Packages.gz")"
PKG_LOCK_SHA="$(file_sha256 "$OUTPUT/packages.lock.tsv")"

# ------------------------------------------------------------ repo-manifest.yaml
# The repository record. Regenerated content that differs only in generated_at
# is not rewritten, so an unchanged rebuild leaves git clean.
STAMP="$(now_utc)"
YAML_TMP="$(mktemp)"
{
  printf '%s\n' '# Blueforce Field OS - offline APT deposu künyesi (repository record)'
  printf '%s\n' '#'
  printf '%s\n' '# Bu dosyayı provisioning/offline-repo/build-index.sh üretir; elle düzenlemeyin.'
  printf '%s\n' '# Depoda hangi Ubuntu sürümü, hangi mimari ve hangi paketlerin bulunduğunu'
  printf '%s\n' '# kanıtlar. Kurucu bu dosyayı okumaz; denetim ve yeniden üretim içindir.'
  printf '%s\n' '#'
  printf '%s\n' '# Yol: provisioning/offline-repo/built/ -> hedef cihazda /opt/blueforce/offline-repo'
  printf 'schema_version: %d\n' "$SCHEMA_VERSION"
  printf '%s\n' 'description: "Offline APT deposunun künyesi"'
  printf '%s\n' 'repository:'
  printf '%s\n' "  name: 'blueforce-offline-apt'"
  printf '%s\n' "  format: 'apt-deb'"
  printf '%s\n' "  state: 'BUILT'"
  printf '  ubuntu_release: %s\n' "$(yq "$UBUNTU_RELEASE")"
  printf '  architecture: %s\n' "$(yq "$TARGET_ARCH")"
  printf '  generated_at: %s\n' "$(yq "$STAMP")"
  printf '%s\n' "  generated_by: 'provisioning/offline-repo/build-index.sh'"
  printf '  package_count: %d\n' "$POOL_TOTAL"
  printf '  total_bytes: %d\n' "$TOTAL_BYTES"
  printf '  total_size: %s\n' "$(yq "$(human_size "$TOTAL_BYTES")")"
  printf '%s\n' "  pool: 'pool/'"
  printf '%s\n' "  bundle_dir: 'provisioning/offline-repo/built'"
  printf '%s\n' "  install_path: '/opt/blueforce/offline-repo'"
  printf '%s\n' "  consumer: 'scripts/install/blueforce-install.sh --offline'"
  printf '%s\n' '  index_files:'
  printf '%s\n' "    - 'Packages'"
  printf '%s\n' "    - 'Packages.gz'"
  printf '%s\n' "    - 'packages.lock.tsv'"
  printf '%s\n' "    - 'SHA256SUMS'"
  printf '%s\n' '  index_sha256:'
  printf '    Packages: %s\n' "$(yq "$PKG_PACKAGES_SHA")"
  printf '    Packages.gz: %s\n' "$(yq "$PKG_GZ_SHA")"
  printf '    packages.lock.tsv: %s\n' "$(yq "$PKG_LOCK_SHA")"
  printf '%s\n' '  manifests:'
  while IFS= read -r manifest_name; do
    printf "    - '%s'\n" "$manifest_name"
  done < <(printf '%s\n' "${MANIFEST_NAMES[@]}" | LC_ALL=C sort)
  printf '  pinned_packages: %d\n' "${#PIN_ORDER[@]}"
  printf '%s\n' 'packages:'
  while IFS= read -r key; do
    package="${key%%:*}"
    version="${key#*:}"
    printf '  - package: %s\n' "$(yq "$package")"
    printf '    version: %s\n' "$(yq "$version")"
    printf '    architecture: %s\n' "$(yq "${POOL_ARCH[$key]}")"
    printf '    sha256: %s\n' "$(yq "${POOL_SHA[$key]}")"
    printf '    size_bytes: %s\n' "${POOL_SIZE[$key]}"
    printf '    source: %s\n' "$(yq "${POOL_SOURCE[$key]}")"
    if [[ "${PIN_VERSION[$package]:-}" == "$version" ]]; then
      printf '    pinned_in: %s\n' "[$(yq "${PIN_MANIFEST[$package]}")]"
    else
      printf '%s\n' '    pinned_in: []'
    fi
  done < <(printf '%s\n' "${POOL_ORDER[@]}" | LC_ALL=C sort -t: -k1,1 -k2,2)
} > "$YAML_TMP"

MANIFEST_WRITTEN='yazıldı'
if [[ -f "$MANIFEST_OUT" ]] && diff -q <(grep -v '^  generated_at:' "$YAML_TMP") <(grep -v '^  generated_at:' "$MANIFEST_OUT") >/dev/null 2>&1; then
  MANIFEST_WRITTEN='içerik değişmedi (tarih korundu)'
else
  install -m 0644 -- "$YAML_TMP" "$MANIFEST_OUT"
fi
rm -f "$YAML_TMP"
printf 'OK: künye %s: %s\n' "$MANIFEST_WRITTEN" "$(rel_to_repo "$MANIFEST_OUT")"

# ------------------------------------------------------------------ final report
printf '\n=== ÖZET ===\n'
printf 'Paket sayısı : %d\n' "$POOL_TOTAL"
printf 'Toplam boyut : %s (%d bayt)\n' "$(human_size "$TOTAL_BYTES")" "$TOTAL_BYTES"
printf 'Ubuntu sürümü: %s\n' "$UBUNTU_RELEASE"
printf 'Mimari       : %s\n' "$TARGET_ARCH"
printf 'Çıktı        : %s\n' "$(rel_to_repo "$OUTPUT")"
printf 'İndeks       : Packages %s | Packages.gz %s | packages.lock.tsv %s\n' \
  "${PKG_PACKAGES_SHA:0:12}" "${PKG_GZ_SHA:0:12}" "${PKG_LOCK_SHA:0:12}"
printf '\nGit eklemesi (komutları depo kökünden çalıştırın; .gitignore Packages/Packages.gz/\npackages.lock.tsv adlarını her yerde yok saydığı için -f gerekir):\n'
printf '  git add provisioning/offline-repo/packages provisioning/offline-repo/manifests\n'
printf '  git add -f %s\n' "$(rel_to_repo "$OUTPUT")"
printf '  git add %s\n' "$(rel_to_repo "$MANIFEST_OUT")"
printf '  git commit -m "offline repo: %d paket, offline APT indeksi"\n' "$POOL_TOTAL"
if [[ ! -d "$SCRIPT_DIR/build" ]]; then
  printf '\nNOT: provisioning/iso/build-blueforce-iso.sh offline depoyu "build" adıyla arıyor.\n'
  printf '     ISO ile aynı yolu kullanmak isterseniz: ./build-index.sh --output build\n'
fi
printf '\nDoğrulama (hedef cihazda /opt/blueforce/offline-repo):\n'
printf '  cd /opt/blueforce/offline-repo && sha256sum -c SHA256SUMS\n'
