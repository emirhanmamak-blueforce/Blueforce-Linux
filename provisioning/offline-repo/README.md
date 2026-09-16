# Offline APT deposu (paketler git ile taşınır)

Saha cihazı internetsiz kuruluyor. Bu dizin, kurulumda kullanılacak Ubuntu
paketlerini ve bunların APT indeksini **bu git deposunun içinde** taşır.

İki kural:

1. **Paketleri repo sorumlusu toplar** ve bu dizine commit eder (Ubuntu makinesi gerekir).
2. **Kuran kişi hiçbir şey indirmez.** Cihazdaki kurucu yalnızca git'ten gelen
   yerel depoyu okur; internet, apt kaynağı, anahtar indirme, `apt download`
   gibi hiçbir yol kullanılmaz.

## Roller

| Rol | Kimdir | Ne yapar |
|---|---|---|
| Repo sorumlusu | bu depoyu yöneten kişi | Ubuntu 26.04 makinesinde paketleri toplar, doğrular, indeksi üretir, commit eder |
| Kuran kişi | sahada cihazı kuran teknisyen | ISO/seed ile kurar, `blueforce-install.sh --offline` çalıştırır; paket aramaz, indirmez |

## Dosya haritası

| Dosya / dizin | Ne işe yarar | Kim çalıştırır |
|---|---|---|
| `packages/` | Doğrulanmış `.deb` dosyaları (kaynak havuz) | repo sorumlusu (`add-packages.sh` ile doldurur) |
| `add-packages.sh` | `.deb` doğrular, `packages/` altına ekler, Türkçe rapor verir | repo sorumlusu (Ubuntu) |
| `build-index.sh` | `packages/`tan offline indeksi üretir (`built/`), `repo-manifest.yaml` yazar | repo sorumlusu (Ubuntu) |
| `built/` | Git'e giren hazır depo: `pool/`, `Packages`, `Packages.gz`, `packages.lock.tsv`, `SHA256SUMS` | üretilir |
| `repo-manifest.yaml` | Deponun künyesi: sürüm, mimari, paket listesi, boyut, tarih | `build-index.sh` üretir |
| `build-offline-repo.sh` | Sözleşme doğrulayıcı (`--dry-run-plan`) ve alternatif derleyici | repo sorumlusu / CI |
| `manifests/*.txt` | Pin listesi: `paket=sürüm`. Cihazda **ne olması gerektiği** | repo sorumlusu doldurur |
| `manifests/requirements.tsv` | Hangi paket neden gerekli (denetim tablosu) | insan okur |
| `manifests/packages.lock.schema.tsv` | `packages.lock.tsv` biçiminin tanımı | insan okur |
| `packages/.gitkeep` | Boş dizinin git'te durması için yer tutucu | — |

---

# 1. Repo sorumlusu: sıfırdan adım adım

## 1.0 Gereksinimler

* Ubuntu 26.04 LTS makinesi, mimari **amd64**, internet erişimi var (paketleri
  toplamak için). Docker CE ve RustDesk paketleri Ubuntu arşivinde değildir;
  aşağıda ayrı anlatılıyor.
* Şu iki araç kurulu olmalı:

  ```bash
  sudo apt-get install -y dpkg apt-utils
  dpkg-deb --version        # okunur: .deb künyesini okur
  apt-ftparchive --version  # okunur: APT indeksini üretir
  ```

  CachyOS/Arch gibi bir makinede `apt-ftparchive` ve `dpkg-deb` yoktur; orada
  paket toplanamaz ve indeks üretilemez. Toplama işi Ubuntu makinesinde yapılır,
  sonuç bu depoya commit edilir.

## 1.1 Paketleri indir

Çalışma dizini açın:

```bash
mkdir -p ~/bf-debs && cd ~/bf-debs
```

Hangi sürümün "aday" olduğunu görün (pini bu sürümle dolduracaksınız):

```bash
apt-cache policy openssh-server | head -n 3
```

Paketleri **ve bağımlılıklarını** indirin (`--download-only` hiçbir şey kurmaz):

```bash
sudo apt-get install --download-only --reinstall -y \
  curl wget ca-certificates gnupg lsb-release apt-transport-https \
  openssh-server wireguard-tools smartmontools ufw iptables \
  prometheus-node-exporter xrdp xorgxrdp gnome-session ubuntu-desktop-minimal

cp /var/cache/apt/archives/*.deb ~/bf-debs/
rm -f ~/bf-debs/*partial*
```

`ubuntu-desktop-minimal` çok sayıda bağımlılık getirir; bu normaldir ve offline
kurulum için gereklidir.

**Docker CE** (Ubuntu arşivinde yok, Docker deposundan gelir):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install --download-only --reinstall -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
cp /var/cache/apt/archives/*.deb ~/bf-debs/
```

`containerd.io` Docker'ın kendi çalışma zamanıdır; Ubuntu'nun `containerd`
paketi ile karıştırmayın.

**RustDesk** (Ubuntu arşivinde yok, üretici `.deb` dosyası):

* Projenin sürüm sayfasından amd64 paketini indirin:
  `https://github.com/rustdesk/rustdesk/releases` → `rustdesk-<sürüm>-x86_64.deb`
* Dosyayı `~/bf-debs/` içine kopyalayın. Kullanılacak sürüm, incelenmiş
  (self-hosted sunucuya bağlanan) istemci sürümü olmalıdır.

## 1.2 Paketleri depoya ekle

```bash
cd provisioning/offline-repo

# Ön izleme: hiçbir dosya kopyalanmaz, ne olacağını söyler
./add-packages.sh --from ~/bf-debs --check

# Gerçek ekleme (pinlenen + bağımlılıklar)
./add-packages.sh --from ~/bf-debs
```

Yalnız manifestte pinlenen paketleri eklemek isterseniz:

```bash
./add-packages.sh --from ~/bf-debs --manifest manifests/base-packages.txt
# bağımlılıkları da eklemek için sonuna --include-all ekleyin
```

Araç her dosyayı denetler ve Türkçe yazar:

* `EKLENDİ:` → eklendi,
* `ATLANDI: aynı dosya zaten repoda` → tekrar eklemeye çalıştınız (zararsız),
* `HATA: mimari uyumsuz` → paket `amd64`/`all` değil; o dosyayı kullanmayın,
* `HATA: çakışma: <paket> repoda <sürüm> ile duruyor` → aynı paketin ikinci bir
  sürümü. Manifestler tek sürüm pinler, bu yüzden otomatik üzerine yazılmaz;
  ekranda yazan `rm` komutu ile eski dosyayı kaldırıp yeniden ekleyin,
* `ATLANDI: manifestte istenen sürüm farklı` → manifestteki pin başka bir sürümü
  istiyor; pini güncelleyin ya da doğru sürümün `.deb` dosyasını indirin.

Sonda `MANIFEST GÜNCELLEMESİ GEREKİYOR` listesi çıkar: bu araç manifest
dosyalarını **değiştirmez**, yalnızca yazmanız gereken satırı söyler.

## 1.3 Manifest pinlerini doldur

`manifests/base-packages.txt`, `remote-access.txt`, `docker.txt` içindeki her
satır şu biçimdedir:

```text
openssh-server=UNPINNED
```

`UNPINNED` bir yer tutucudur, sürüm değildir. `add-packages.sh` çıktısındaki
listeyi kullanarak gerçek sürümü yazın:

```text
openssh-server=9.6p1-3ubuntu13
```

Kurallar: küçük harfli paket adı, `=` çevresinde boşluk yok, satır sonuna not
yazılmaz, bir paket yalnızca bir manifestte pinlenir. Yeni paket ekler/çıkarırsanız
`manifests/requirements.tsv` tablosunu **aynı işlemde** güncelleyin.

Kontrol:

```bash
./build-offline-repo.sh --dry-run-plan     # PLAN READY görmelisiniz
```

`PLAN READY` görünene kadar derleme yapmayın. Bir sürümden emin değilseniz
elinizdeki dosyadan okuyun:

```bash
dpkg-deb -f ~/bf-debs/openssh-server_*.deb Package Version Architecture
```

## 1.4 İndeksi üret

```bash
./build-index.sh --check     # yalnızca doğrular, hiçbir şey yazmaz
./build-index.sh             # built/ altına indeksi yazar
```

Çıktı:

```text
built/pool/*.deb            paketlerin kopyası
built/Packages              APT indeksi (apt-ftparchive)
built/Packages.gz           sıkıştırılmış indeks (zaman damgasız)
built/packages.lock.tsv     SBOM: package/version/architecture/sha256/source
built/SHA256SUMS            indeks dosyalarının özetleri
repo-manifest.yaml          deponun künyesi (güncellenir)
```

Araç fail-closed çalışır:

* manifestteki bir pin repoda yoksa **hiçbir şey yazmaz** ve eksikleri liste
  hâlinde söyler (`manifestlerde istenen şu paketler eksik:`),
* bir pin hâlâ `UNPINNED` ise yine yazmaz; önce manifesti doldurun,
* aynı havuzla tekrar çalıştırıldığında indeks birebir aynı çıkar; içerik
  değişmediyse `DEĞİŞİKLİK YOK` yazar ve dizini yeniden yazmaz.

## 1.5 Git'e ekle ve commit et

```bash
# Paketler ve manifestler:
git add provisioning/offline-repo/packages provisioning/offline-repo/manifests

# İndeks: .gitignore, Packages / Packages.gz / packages.lock.tsv adlarını her
# dizinde yok sayar (eski LAB akışından kalma kural), bu yüzden -f gerekir:
git add -f provisioning/offline-repo/built

git add provisioning/offline-repo/repo-manifest.yaml
git commit -m "offline repo: <paket sayısı> paket, offline APT indeksi"
```

`build-index.sh` çalıştığınızda bu komutları ekrana da yazar (kopyala-yapıştır).
`.gitignore` dosyasının sahibi isterse bu üç ad için daha sonra istisna kuralı
ekleyebilir; o zaman `-f` gereksizleşir.

## 1.6 Bitirmeden önce kontrol

```bash
bash tests/check-offline-repo-static.sh
./build-offline-repo.sh --dry-run-plan
cd built && sha256sum -c SHA256SUMS      # OK görmelisiniz
```

---

# 2. Kuran kişi neden hiç indirme yapmaz

* Saha cihazında internet yok (ya da güvenilmez). Bu yüzden kurulumun ihtiyaç
  duyduğu her şey **medyanın ve git deposunun içinde** taşınır.
* Kurucu `--offline` ile çalıştığında tek kaynak şudur:
  `/opt/blueforce/offline-repo` dizinine konan yerel depo
  (`deb [trusted=yes] file:/opt/blueforce/offline-repo ./`). Uzak APT kaynağı,
  anahtar indirme, `curl`, `wget`, `apt download` kullanılmaz.
* Bu dizin (git deposundaki `built/`) ISO ile hedefe taşınır ve kurucu şu
  dosyaları arar ve doğrular: `Packages`, `Packages.gz`, `packages.lock.tsv`,
  `SHA256SUMS` ve `pool/` içinde manifestlerdeki pinlere karşılık gelen `.deb`
  dosyaları.
* Kurucu kurulum sonunda cihazı `PROVISIONED_OFFLINE` durumuna getirir. Cihaz,
  bir kerelik enrollment ve merkezi kanal doğrulaması yapılmadan `READY` olmaz.
* Sonuç: kuran kişinin yaptığı tek şey `git`/ISO'dan gelen dosyaları yerine
  koymak ve kurucuyu çalıştırmaktır. Hangi sürümün kurulduğu
  `packages.lock.tsv` ve `repo-manifest.yaml` ile kanıtlanır.

Kuran kişinin komutu:

```bash
sudo ./scripts/install/blueforce-install.sh --offline --dealer-id <8 haneli numara>
```

---

# 3. Eksik paket olursa ne olur? (`OFFLINE BLOCKED`)

Cihazdaki kurucu, paket modüllerinden **önce** yerel depoyu doğrular. Bir şey
eksik ya da bozuksa kurulum durur ve ekrana `OFFLINE BLOCKED` ile başlayan bir
satır yazar. `OFFLINE BLOCKED` demek: "cihazda kurulum yapılmadı, depo
tamamlanmadı, sorumluya haber verin".

| Ekranda ne yazar (kısaltılmış) | Ne anlama gelir | Sorumlu tarafında çözüm |
|---|---|---|
| `BF_OFFLINE_REPO must be an existing absolute local directory` | Depo dizini hiç yok: medya ya da kopyalama eksik | `built/` içeriğini `/opt/blueforce/offline-repo` altına koyun |
| `local APT index, lock, or checksums are missing; ISO bundle is incomplete` | `Packages`, `Packages.gz`, `packages.lock.tsv` veya `SHA256SUMS` yok. Genelde indeks üretilmeden commit edilmiştir | `./build-index.sh` çalıştırıp `built/` dizinini commit edin |
| `local APT repository checksum validation failed` | Dosyalar elle değişmiş ya da kopyalama bozulmuş (`sha256sum -c SHA256SUMS` hatası) | Depoyu git'ten yeniden alın; indeksi yeniden üretin |
| `package lock is empty or invalid` | `packages.lock.tsv` başlığı/kolonları bozuk ya da dosya boş | `./build-index.sh` ile yeniden üretin, elle düzenlemeyin |
| `pinned package absent from bundle: <paket>` | Manifestteki sürüm depoda yok: pin ile paket eşleşmiyor | `add-packages.sh` ile doğru sürümü ekleyip pini güncelleyin |

Yani "eksik paket" sahada değil, **commit öncesinde** çözülür:
`./build-index.sh` eksikleri listeler ve yazmadan durur. Sahada `OFFLINE BLOCKED`
görürseniz ISO, bilgi eksik bir depoyla üretilmiş demektir; çözüm depoyu düzeltip
yeni ISO üretmektir.

---

# 4. Hangi paketler gerekli ve neden?

Liste `manifests/requirements.tsv` dosyasının okunabilir hâlidir; kaynak
doğrudur. Her satır bir `paket=sürüm` pinidir ve kurucu bu pinlerin **tamamını**
depoda arar; biri eksikse `OFFLINE BLOCKED` ile durur.

## Temel araçlar — `manifests/base-packages.txt`

| Paket | Neden gerekli | Nerede kullanılır |
|---|---|---|
| `curl` | HTTPS aktarımı yapan temel araç | `02-system.sh` |
| `wget` | Saha runbook'larının beklediği dosya çekme aracı | `02-system.sh` |
| `ca-certificates` | TLS doğrulaması için kök sertifika deposu | `02-system.sh` |
| `gnupg` | İncelenmiş dosyaların imza işlemleri | `02-system.sh` |
| `lsb-release` | Dağıtım sürümünü tanıma | `02-system.sh` |
| `apt-transport-https` | apt 2.0+ üzerinde geçiş (dummy) paket; referans derlemeyle uyum için tutuluyor | `02-system.sh` |
| `openssh-server` | Yönetilen SSH erişim kanalı | `07-ssh.sh` |
| `wireguard-tools` | `wg` komutu (VPN tüneli) | `06-wireguard.sh` |
| `smartmontools` | Disk sağlığı kanıtı (SMART) | `scripts/diagnostics/bf-diagnostics` |
| `ufw` | Güvenlik duvarı temeli | `13-firewall.sh` |
| `iptables` | Güvenlik duvarı kural arka ucu | `13-firewall.sh` |
| `prometheus-node-exporter` | Cihaz metrikleri (textfile collector paketin içinde) | `12-monitoring.sh` |

## Uzak erişim ve masaüstü — `manifests/remote-access.txt`

| Paket | Neden gerekli | Nerede kullanılır |
|---|---|---|
| `xrdp` | RDP erişim kanalı | `08-rdp.sh` |
| `xorgxrdp` | xRDP için X11 arka ucu (bağımlılık kapatması LAB'da doğrulanır) | `08-rdp.sh` |
| `gnome-session` | xRDP oturumunda başlatılan masaüstü oturumu | `08-rdp.sh` |
| `ubuntu-desktop-minimal` | En küçük masaüstü yığını | `16-gui.sh` |
| `rustdesk` | Uzak masaüstü istemcisi. **Ubuntu arşivinde yoktur**: üreticinin incelenmiş `.deb` dosyası | `09-rustdesk.sh` |

## Docker CE — `manifests/docker.txt`

| Paket | Neden gerekli | Nerede kullanılır |
|---|---|---|
| `docker-ce` | Konteyner motoru | `10-docker.sh` |
| `docker-ce-cli` | `docker` komutu | `10-docker.sh` |
| `containerd.io` | Docker CE ile gelen çalışma zamanı (Ubuntu'nun `containerd` paketi değil) | `10-docker.sh` |
| `docker-buildx-plugin` | buildx eklentisi | `10-docker.sh` |
| `docker-compose-plugin` | Compose v2 eklentisi | `10-docker.sh` |

Notlar:

* Pinler sürüm doldurulmadan `UNPINNED` görünür ve bu hâlde derleme yapılmaz.
* Bu 22 paketin dışındaki paketler (bağımlılıklar) da depoda bulunur; ancak
  yalnız **pinlenen 22 paket** sözleşmedir.
* Çekirdek modülleri gibi `.deb` olarak taşınmayan dosyalar bu deponun kapsamı
  dışındadır.

---

# 5. `repo-manifest.yaml` ve `built/` nedir?

* `repo-manifest.yaml` = deponun künyesi (kimlik kartı): hedef Ubuntu sürümü,
  mimari, kaç paket, toplam boyut, üretim tarihi ve her paketin adı/sürümü/
  sha256'sı. ISO release manifesti ve denetim kaydı ile birlikte saklanır.
* `built/` = cihaza gidecek depo. Hedef cihazda `/opt/blueforce/offline-repo`
  olur; içinde `pool/`, `Packages`, `Packages.gz`, `packages.lock.tsv`,
  `SHA256SUMS` bulunur. Kurucu bu dosyaları `sha256sum -c SHA256SUMS` ile ve
  manifestteki her pini `pool/` içindeki bir dosyayla eşleştirerek doğrular.

---

# 6. Sık karşılaşılan durumlar

| Belirti | Neden / çözüm |
|---|---|
| `apt-ftparchive bulunamadı` | Ubuntu makinesinde kurun: `sudo apt-get install -y apt-utils` |
| `dpkg-deb bulunamadı` | `sudo apt-get install -y dpkg` (Arch/CachyOS'ta yoktur; orada derleme yapılamaz) |
| `git add` indeks dosyalarını almıyor | `.gitignore` bu adları yok sayıyor; `git add -f provisioning/offline-repo/built` kullanın |
| `HATA: çakışma` | Aynı paketin ikinci sürümü eklenmeye çalışıldı. Manifestler tek sürüm pinler; ekrandaki `rm` ile eskiyi kaldırın |
| `mimari uyumsuz` | Yalnız `amd64` ve `all` kabul edilir; `arm64`/`i386` paketi eklemeyin |
| `manifestlerde istenen şu paketler eksik` | Paketi indirip `add-packages.sh` ile ekleyin; pin hâlâ `UNPINNED` ise sürümü yazın |
| ISO betiği depoyu bulamıyor | `provisioning/iso/build-blueforce-iso.sh` şu an `provisioning/offline-repo/build` adını arıyor; `built/` kullanacaksanız `./build-index.sh --output build` ile de üretin ya da ISO betiğinin otomatik bulma yolunu güncelleyin |
| Depo boyutu beklenenden büyük | `packages/` ve `built/pool/` aynı `.deb` dosyalarını iki kez tutar (git içeriği bir kez saklar, çalışma kopyasında iki dosya durur). Kasıtlıdır: biri kaynak, diğeri teslim depo |

---

# 7. Commit öncesi kontrol listesi

- [ ] `./add-packages.sh --from <dizin> --check` temiz geçti.
- [ ] `manifests/*.txt` içinde `UNPINNED` kalmadı.
- [ ] `./build-offline-repo.sh --dry-run-plan` → `PLAN READY`.
- [ ] `./build-index.sh` eksiksiz geçti, eksik paket listesi boş.
- [ ] `cd built && sha256sum -c SHA256SUMS` → `OK`.
- [ ] `repo-manifest.yaml` güncel (paket sayısı ve tarih yazılmış).
- [ ] `bash tests/check-offline-repo-static.sh` geçti.
- [ ] Commit: paketler, manifestler, `built/` (`-f` ile) ve `repo-manifest.yaml`.
