# Blueforce Field OS — Uygulama Raporu

**Tarih:** 2026-09-16
**Kapsam:** Windows 10 saha PC'lerinin Blueforce Field OS'a dönüştürülmesi için provisioning, ISO üretimi, offline kurulum, cihaz durumu ve enrollment katmanları.
**Yöntem:** Bu rapordaki her sayı depodaki gerçek dosyalardan, çalıştırılan testlerden ve üretilen ISO artefaktından okunmuştur. Doğrulanamayan hiçbir iddia "tamam" sayılmamıştır.

> **Dürüstlük sınırı:** Gerçek bir ISO üretildi ve doğrulandı. Ancak gerçek donanımda boot, gerçek Windows cihaz, gerçek merkez enrollment endpoint'i ve gerçek air-gapped `.deb` kurulumu **henüz yapılmadı**. Bu maddeler §7'de listelidir.

---

## 1. Önceden ne vardı?

- 00–25 numaralı mimari, işletim, güvenlik, rollout ve runbook dokümantasyonu; `scripts/` (installer + diagnostics), `ansible/`, `config/`, `monitoring/`, `rustdesk/`, `docs-site/` iskeleti.
- Çalışan `blueforce-install.sh` + 18 modül, `BF-<8 hane>` kimlik standardı, `bf-status` / `bf-diagnostics` / `bf-support-bundle` / `bf-hardware-inventory.sh`.
- WireGuard, SSH, xRDP, RustDesk OSS, Docker politikaları, UFW/Docker firewall, log yönetimi, recovery runbook'ları.
- **Eksik olan:** Field OS medya yaşam döngüsü (ISO gerçekten üretilmiyordu), offline paket deposu (manifestler boştu), firstboot kimlik akışı, 3 aşamalı durum modeli, enrollment sözleşmesi, Windows geçiş araçları ve doküman tutarlılığı.

---

## 2. Ne değişti?

### 2.1 ISO artık gerçekten üretiliyor (en kritik kazanım)

Önceki durumda `build-blueforce-iso.sh` bir iskeletti: `--allow-remaster` olmadan çıktı üretmiyor, boot menüsünü entegre etmiyor, offline repo eklemiyordu. Şimdi gerçek medya üretiyor.

**Üretilen artefakt (doğrulandı):**

| Alan | Değer |
|---|---|
| Dosya | `dist/Blueforce-Field-OS-1.0.0-amd64.iso` |
| Boyut | 6 481 917 952 byte (6.04 GiB) |
| ISO SHA256 | `cb0cc56f0442fbd1418e0d0f35521522f4ec9aa3f203779a67e96d587d431296` |
| Base ISO | `ubuntu-26.04.1-desktop-amd64.iso`, SHA256 `601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f` (Canonical `SHA256SUMS` ile birebir) |
| Base flavour | `desktop` (bkz. §8 baseline sapması) |
| Boot | El Torito **BIOS + UEFI** korundu |
| Build | 2026-09-16T08:00:29Z |

**Çözülen kök nedenler** (hepsi ölçülmüş hata mesajlarıyla, kalıcı referans: `ubuntu-iso-remaster` skill):

1. `-boot_image any replay` Ubuntu ISO'larında çalışmaz — GRUB2 MBR kodu kaynak imajın ilk 16 sektöründe, EFI sistemi ise ISO dosya sistemi *dışında* appended partition olarak durur. Çözüm: boot düzenini `xorriso -report_el_torito as_mkisofs` çıktısından okuyup `-as mkisofs` ile yeniden kurmak.
2. `-as mkisofs` xorriso-native `-volume_date` opsiyonunu tanımaz → `--modification-date` kullanılır.
3. `as_mkisofs` kendi `--modification-date` satırını verir; xorriso bunu `-volume_date uuid`'ye çevirip reddeder → filtrelenir.
4. Opsiyon satırları tek argümana çöküyordu → tırnak-honor eden tokenizer (30 argüman).
5. `sed` ile yol değişimi tırnakları bozuyor ve `--interval` alanlarını kaydırıyordu → yol yeniden yazılmaz.

### 2.2 Offline kurulum sözleşmesi

- `provisioning/offline-repo/manifests/{base-packages,remote-access,docker}.txt` artık hangi paketlerin gerektiğini **somut** listeliyor (pin formatı `package=version`), paket sürümleri LAB'da doldurulacak.
- `build-offline-repo.sh`: `apt-ftparchive` + `dpkg-deb` zorunlu; pin semantiği doğrulanır; placeholder/eksik pin net hatayla reddedilir.
- ISO içine gömülü repo olmadığında medium `offline_repo_status: not-included` yazar ve hedef cihaz `OFFLINE BLOCKED` ile kapalı kalır — sessizce "kurulmuş gibi" yapmaz.

### 2.3 Cihaz kimliği ve durum modeli

- `bf-firstboot`: bayi numarası terminal wizard'ı (`^[0-9]{8}$`), hatalı girişi kabul etmez, 3 denemede net hata; non-interactive modda dosya/argüman yolu. Kimlik değişimi ayrı admin/recovery prosedürüne bağlı.
- Üç aşamalı model: **`PROVISIONED_OFFLINE` → `ENROLLED` → `READY`**. İleri yönlü, atlama ve geri dönüş yok; her geçiş atomik ve 0600.
- `bf-status` artık `Provisioning / Enrollment / Fleet State` satırlarını gösteriyor.
- **Kritik davranış:** internet/WireGuard yokluğu kurulumu FAIL etmez. `bf-check-local` internetsiz PASS verebilir; `bf-check-enrollment` ve `bf-check-ready` merkez kanıtı olmadan **fail-closed** kalır.

### 2.4 Enrollment (tasarım + istemci)

- Tek kullanımlık token akışı seçildi; imzalı bootstrap bundle / kalıcı ortak secret / manuel kayıt karşılaştırılıp elendi.
- **700 cihaza aynı kalıcı secret konmaz.** WireGuard **private key cihazdan çıkmaz**; yalnız public key + non-secret metadata gönderilir.
- `blueforce-enroll.service` sınırlı yeniden deneme (`RestartSec`, `StartLimitBurst`), reboot loop yok; internet gelince kendiliğinden katılır, yoksa `PENDING` kalır.
- **Merkezi endpoint bilinçli olarak yazılmadı** (prompt §18: önce tasarım). Sözleşme JSON şemalarıyla sabitlendi.

### 2.5 Filo otomasyonu

- Mevcut 16 playbook korundu; **5 read-only** playbook eklendi: `bf-fieldos-version` (hangi cihazda hangi sürüm), `bf-provisioning-status`, `bf-enrollment-status`, `bf-remote-channels-check`, `bf-offline-ready-check`.
- Her playbook dalga kapsam kapısı taşıyor; production ayrıca `production_override` ister. Kapı matrisi canlı test edildi (boş/hatalı dalga, onaysız koşu, dalga dışı `--limit` → rc=2).

### 2.6 Windows geçişi ve canlı donanım kontrolü

- Read-only PowerShell envanter/veri dışa aktarma araçları prompt kapsamına (ağ, yazılım, servisler, COM/USB, VPN varlığı, MEG izleri) çıkarıldı; credential toplama yasak.
- `bf-live-hw-check`: Windows silinmeden önce NIC/disk/CPU/RAM/serial/USB kontrolü, `SUPPORTED / WARNING / BLOCKED` sonucu, mutasyonsuz.

### 2.7 Güvenlik ve dokümantasyon

- Depo çapında secret taraması; ISO'ya cihaz kimliği/private key/parola gömülmediği builder tarafından **reddedilir**.
- `.gitignore`: ISO, offline repo çıktısı, build scratch ve tüm anahtar/kimlik desenleri repo dışında.
- Doküman seti 33 dosyaya çıktı; medya stratejisi, RDP modeli, durum modeli, GNOME/XFCE ölçümü ve Field OS sürüm takibi kararları tek sesli hale getirildi.

---

## 3. Hangi yeni sistemler eklendi?

| Sistem | Ne yapar |
|---|---|
| **Field OS ISO build** | Doğrulanmış base ISO'dan tek USB'lik bootable medya üretir; boot düzenini base ISO'dan okuyup yeniden kurar |
| **Assisted autoinstall** | Kurulum otomatik, **disk seçimi operatörde** (`interactive-sections: [storage]`); otomatik wipe yok |
| **Offline APT repo** | Yerel, sürüm pinli `.deb` havuzundan checksum'lı repo üretir |
| **Firstboot wizard** | Bayi numarasını konsoldan toplar, kimliği üretir, offline kurucuyu çağırır |
| **3 aşamalı durum makinesi** | `PROVISIONED_OFFLINE` / `ENROLLED` / `READY`, fail-closed kapılar |
| **Enrollment istemcisi** | Tek kullanımlık token, replay engeli, private key dışarı çıkmaz |
| **Field OS sürüm takibi** | `/etc/blueforce-release`, `bf-release`, filo çapında sürüm raporlama |
| **Windows öncesi keşif** | Salt-okunur envanter + geri dönüş için veri dışa aktarma |
| **Canlı donanım uygunluğu** | Kurulumdan önce SUPPORTED/WARNING/BLOCKED kararı |
| **Dalga kapılı filo otomasyonu** | 21 playbook, dalga + production override zorunluluğu |

---

## 4. Neden eklendi?

- **Saha interneti yokken kurulum yapılabilmeli** ama cihaz merkez kanıtı olmadan yanlışlıkla READY sayılmamalı.
- **Disk silme güvenliği:** bu ISO, üzerinde başka bir işletim sistemi bulunan gerçek saha PC'lerinde kullanılacak. Bu nedenle V1 bilinçli olarak *assisted*: teknisyen hedef diski onaylar.
- **İzlenebilirlik:** Field OS sürümü, base ISO hash'i, offline snapshot ve kurucu sürümü ayrı ayrı kayıt altında; rollback mümkün.
- **Tek medya kolaylığı:** autoinstall ile Field OS ISO rakip değil, tamamlayıcıdır — biri motor, diğeri paketleme.
- **700 cihazda serbest değişiklik yok:** dalga, onay ve rollback kapıları korunur.

---

## 5. Hangi dosyalar değişti?

| Alan | İçerik |
|---|---|
| **Provisioning** | `provisioning/{iso,autoinstall,offline-repo,firstboot,enrollment,release}/` |
| **Tanı ve durum** | `scripts/diagnostics/` — `bf-status`, `bf-check-local`, `bf-check-enrollment`, `bf-check-ready`, `bf-enroll`, `bf-enroll-now`, `bf-enrollment-status`, `bf-release`, `bf-remote-status`, `bf-live-hw-check`, `bf-support-bundle`, `bf-hardware-inventory.sh` |
| **Kurulum** | `scripts/install/` (18 modül), `scripts/install/optional/anydesk/` |
| **Geçiş** | `scripts/migration/windows/` + kökte `migration/` işaret dosyası |
| **Filo** | `ansible/{inventory,playbooks,roles}/` (21 playbook, 4 rol) |
| **Yapılandırma** | `config/` (ssh, wireguard, firewall, docker, systemd) |
| **İzleme / uzak erişim** | `monitoring/`, `rustdesk/` |
| **Testler** | `tests/` — 8 test scripti + `run-all.sh` + QEMU planı |
| **Doküman** | `docs/00`–`docs/32` (33 dosya), `README.md`, `SUMMARY.md` |
| **Site** | `docs-site/` (Docusaurus) |

`dist/`, `.build-lab/`, `*.iso` ve anahtar/secret desenleri `.gitignore` ile repo dışında tutulur.

---

## 6. Hangi testler geçti?

`bash tests/run-all.sh` → **8/8 PASS, exit 0** (2026-09-16):

| Test | Kapsam |
|---|---|
| `check-specs.sh` | 33 doküman gapless, §1–§13 sıralı, her dokümanda diyagram, 21 playbook sözleşmesi, secret/moving-tag yasağı |
| `check-configs.sh` | Bash sözdizimi, YAML/JSON parse, inventory dalga grupları |
| `check-provisioning-static.sh` | Autoinstall kimliksiz, otomatik disk silme yok, interaktif depolama kapısı, secret taraması |
| `check-offline-repo-static.sh` | Pin semantiği, placeholder yasağı |
| `check-migration-static.sh` | Windows araçları read-only, credential toplamaz |
| `check-ansible-static.sh` | Kapı deseni, report-only security check, moving tag/Watchtower yasağı |
| `test-firstboot-static.sh` | Bayi no doğrulaması, hatalı giriş reddi, idempotentlik |
| `test-field-os-lifecycle.sh` | Durum geçişleri, offline local gate, ENROLLED fail-closed, replay engeli |

**ISO doğrulaması (bağımsız, iki araç):**

| Kontrol | Sonuç |
|---|---|
| El Torito BIOS + UEFI | ikisi de korunmuş |
| Blueforce payload (6 yol) | tümü medyada |
| `interactive-sections: [storage]` | korunmuş |
| Kimlik/secret gömülü mü | **hayır** |
| `apt.fallback: offline-install` | tanımlı |
| GRUB autoinstall satırları | 2 kernel satırı |
| `casper/minimal.squashfs` (3.43 GB) bütünlüğü | **birebir aynı** (xorriso `cmp` + `7z` sha256: `b5ec27b9570e77abb62831a8b652b50eaf089d537e62046189a52231a4fa9bec`) |

---

## 7. Hangi testler LAB gerektiriyor?

`tests/qemu-field-os-test-plan.md` T1–T18 henüz **çalıştırılmadı**:

- **Boot kabulü:** UEFI, Legacy BIOS ve **Secure Boot** altında gerçek boot. Remaster edilen medyanın boot zinciri yalnızca metadata düzeyinde doğrulandı.
- **Autoinstall:** Desktop flavour'da Subiquity'nin `/autoinstall.yaml`'ı gerçekten uyguladığı ve depolama ekranını interaktif bıraktığı.
- **Air-gapped kurulum:** gerçek offline `.deb` seti ile bağımlılık çözümü.
- **Firstboot:** gerçek konsolda wizard davranışı; systemd unit'inin boot'u kilitlememesi.
- **GNOME vs XFCE A/B ölçümü** (RAM/CPU/boot süresi/RDP/RustDesk headless/24h-72h stabilite).
- **xRDP + RustDesk headless:** fiziksel monitörsüz cihazda login ekranı ve dummy display davranışı.
- **Power-loss / otomatik kurtarma**, güç dönüşünde servis zinciri.
- **Enrollment:** gerçek merkez endpoint'i, token TTL/iptal, merkezi doğrulama kanıtları.
- **Windows geri dönüş provası:** image restore ve iş akışının geri gelmesi.

---

## 8. Hangi kararlar açık?

1. **Baseline sapması (LAB kararı gerekli):** kanonik baseline *Ubuntu Server 26.04.1+*; build host'ta doğrulanmış mevcut medya **Desktop** flavour olduğu için ISO bu tabanla üretildi. Sapma manifest'te `baseline_deviation` bloğuyla kayıtlı. Karar: LAB için Desktop kabul edilsin mi, yoksa Server ISO ile mi yeniden üretilsin? (Server yolu tek parametre uzakta.)
2. **Offline paket pinleri:** manifestler hangi paketlerin gerektiğini söylüyor, ancak **somut sürümler ve `.deb` dosyaları yok** — offline repo henüz üretilmedi. Ubuntu 26.04 build makinesi gerekir.
3. **Secure Boot:** remaster edilen medyanın Secure Boot davranışı test edilmedi.
4. **Enrollment kontrol düzlemi:** endpoint, kimlik doğrulama, imzalama, token TTL/iptal politikası ve audit saklama.
5. **Release artefakt saklama:** ISO/seed/offline snapshot retention, imza anahtarı sahibi, release kadansı, EOL.
6. **Windows imaj saklama:** süre, erişim yetkisi, imha ve geri dönüş RTO.
7. **MEG `.deb`:** paket gelmedi; acceptance checklist hazırlıklı bekliyor, hiçbir servis adı/config yolu varsayılmadı.
8. **ISO boyutu:** Desktop tabanı 6.04 GiB; Server tabanına göre (~2.9 GB) USB dağıtımını etkiler.

---

## 9. İlk gerçek LAB PC'sinde sırayla ne yapacağız?

1. Temsilci Windows PC'yi seç; bayi no ve seri no'yu iki bağımsız kayıtla doğrula. İş sahibi onayı ve kesinti penceresi al.
2. Windows üzerinde `BF-WindowsPreMigrationInventory.ps1` ve `BF-WindowsDataExport.ps1` çalıştır (salt-okunur). Hash doğrulamalı Windows geri dönüş imajı al; nerede tutulduğunu ve restore sahibini kaydet.
3. ISO SHA256'sını doğrula: `sha256sum -c dist/Blueforce-Field-OS-1.0.0-amd64.iso.sha256` → `cb0cc56f...`.
4. Medyayı USB'ye yaz ve **kurulumdan önce canlı oturumda** `bf-live-hw-check` çalıştır. `BLOCKED` çıkarsa dur.
5. Kurulumu başlat. Autoinstall çalışır ama **depolama ekranında hedef diski teknisyen onaylar** — otomatik wipe yok.
6. İlk açılışta wizard'da bayi numarasını gir (ör. `12010193` → `BF-12010193` / `bf-12010193`). `bf-status` ile **yalnız `PROVISIONED_OFFLINE`** görüldüğünü doğrula; cihazı READY olarak teslim etme.
7. Ağ olmadan dış indirme olmadığını ve local servis/boot loglarını kaydet.
8. Kontrollü ağ erişimi sağlandığında ve merkez kontrol düzlemi hazır olduğunda tek kullanımlık token ile enrollment yap (token'ı USB'ye/loga/rapora yazma).
9. `ENROLLED` sonrası WireGuard handshake, xRDP, RustDesk, MeshCentral, monitoring kanıtlarını ayrı ayrı doğrula. Tümü geçmeden READY yazma.
10. Gözlem pencereleri: **24 saat** boot/servis/ağ/uzak erişim · **72 saat** kesinti ve log/disk kararlılığı · **7 gün** saha iş akışı, güç dönüşü ve Windows restore provası. Kanıtlar release kaydına bağlanmadan pilot dalgaya geçme.

---

## 10. Production'a geçmeden önce yapılacaklar

- **Boot kabulü:** UEFI, Legacy BIOS ve Secure Boot matrisini gerçek donanımda kanıtla.
- **Gerçek offline paket seti:** Ubuntu 26.04 build makinesinde pinli `.deb` havuzunu üret, checksum/lock kaydı al, air-gapped kurulumda dene, ISO'ya gömüp yeniden build et.
- **Baseline kararı:** Desktop tabanını kabul et veya Server ISO ile yeniden üret (manifest `baseline_deviation` kaydı buna göre güncellenir).
- **Enrollment kontrol düzlemi:** endpoint + kimlik doğrulama + imzalama + token TTL/iptal + audit retention.
- **Merkez izleme/uzak erişim kanallarını** gerçek VDS üzerinde doğrula (RustDesk self-hosted hbbs/hbbr, Prometheus/Grafana/Uptime Kuma).
- **Release yönetimi:** artefakt deposu, imza anahtarı, retention/EOL, rollback prosedürü.
- **Windows veri/imaj saklama** ve geri dönüş RTO'sunu resmileştir.
- **Pilot hazırlığı:** envanter, alarm/on-call, eğitim, change approval ve dalga kapıları. Sıra: LAB(2) → P1(5) → P2(20) → W1(50) → W2(100) → production; her adım öncekinin kanıtı olmadan ilerlemez.
- **Zayıflatılmayacak kurallar:** onaysız update yasağı (apt, release upgrade, Docker image, MEG, Field OS), dalga onay kapıları, disk silme güvenliği, secret yasağı.

---

## 11. Build ortamı notu

ISO build'i bu makinede (CachyOS/Arch) **konteyner içinde** çalıştırıldı (`xorriso 1.5.6`), host'a paket kurulmadı. `apt-ftparchive`/`dpkg-deb` bu host'ta bulunmadığı için **offline `.deb` repo üretimi Ubuntu 26.04 build makinesi gerektirir** (§10).

---

## 12. Delil özeti (git diff ve repo ağacı)

- Commit edilmemiş çalışma ağacı: değiştirilmiş dokümanlar + yeni provisioning/ansible/config/monitoring/scripts/tests dosyaları.
- Üretilen artefakt: `dist/Blueforce-Field-OS-1.0.0-amd64.iso` (+ `.sha256`, `1.0.0-manifest.yaml`).
- Test sonucu: 8/8 PASS, exit 0.
- Repo ağacının tam çıktısı commit sonrası `git status` / `git diff --stat` ile alınır.
