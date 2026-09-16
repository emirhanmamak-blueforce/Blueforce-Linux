# Blueforce Field OS — Ubuntu LTS-based offline-installable centrally managed, no unapproved updates, multi remote-channel industrial field OS standard

> 700 saha cihazı için Ubuntu LTS tabanlı, çevrimdışı kurulabilen, merkezi yönetilen ve onaysız güncelleme yapmayan endüstriyel Field OS standardı.
> 700 saha cihazlık filonun kesin kararları, en büyük 10 operasyonel riski ve ücretsiz-bileşen listesi.
> Ayrıntı `docs/` dosyalarındadır; her cevap ilgili dokümana linklenir. Kararların kilit kaynağı
> [`docs/24-DECISION-LOG.md`](docs/24-DECISION-LOG.md) (K-01…K-24), izlenebilirlik tablosu Ek B + Ek B-2'dedir (S-01…S-37).
> Mimari tek bakış: [`docs/01-ARCHITECTURE.md`](docs/01-ARCHITECTURE.md). Faz sırası: [`docs/25`](docs/25-IMPLEMENTATION-ROADMAP.md) (F0…F6). Commit yok, FREE sürümler baz.

---

## 1. Field OS için Kısa Soru-Cevap (2026-09-16 turu)

- **Blueforce Field OS nedir?** — Ubuntu Server 26.04.1+ LTS üzerinde maintain edilen GNOME katmanı bulunan, çevrimdışı kurulabilen, merkezden yönetilen; onaysız güncelleme yapmayan ve 4 uzak erişim kanalı kullanan **endüstriyel saha işletim sistemi standardıdır**. Üç parçası vardır: zemin (Ubuntu LTS + GNOME + terminale boot), provisioning (tek kurucu + autoinstall/offline APT/firstboot + tek USB Field OS ISO) ve işletme (WireGuard + 4 kanal + Docker/MEG + monitoring + Ansible/Semaphore). **Medya tabanı sapması:** kanonik baseline Ubuntu **Server**'dır; build host'ta checksum'ı doğrulanmış tek medya Ubuntu **Desktop** ISO olduğu için üretilen ilk ISO Desktop tabanlıdır (manifest `baseline_deviation` bloğu). Hedef işletim sistemi yine Server paket setidir (`ubuntu-server` + `ubuntu-desktop-minimal` + GNOME, terminale boot); sapma yalnız medya tabanındadır ve LAB kararı bekler. → [`00`](docs/00-MASTER-PLAN.md), [`01`](docs/01-ARCHITECTURE.md), [`26`](docs/26-BLUEFORCE-FIELD-OS-ISO.md), [`31`](docs/31-LEARNING-GUIDE.md) (K-01, K-02, K-20)
- **Nasıl kurulur?** — Kurulumun birincil yolu **git deposudur**: `git clone https://github.com/emirhanmamak-blueforce/Blueforce-Linux.git` → `cd Blueforce-Linux` → `sudo admin/bf-bootstrap.sh` (depoyu klonlamadan tek satır alternatifi: `curl -fsSL https://raw.githubusercontent.com/emirhanmamak-blueforce/Blueforce-Linux/main/admin/bf-bootstrap.sh | sudo bash`) → `sudo bf-menu`. Bootstrap yalnız operatör araçlarını ve `bf-*` komutlarını kurar; **cihaz kimliği (bayi no) İSTEMEZ**, disk bölmez, veri silmez, onaysız güncelleme yapmaz (idempotent). Kimlik ilk `bf-menu` seansında girilir. ISO/firstboot yolu ([`26`](docs/26-BLUEFORCE-FIELD-OS-ISO.md)/[`27`](docs/27-OFFLINE-PROVISIONING.md)) **ikincil/opsiyoneldir** ve silinmez. Ayrıntılı adım adım rehber: [`33`](docs/33-OPERATOR-CONSOLE.md). → [`05`](docs/05-ONE-CLICK-INSTALLER.md), [`33`](docs/33-OPERATOR-CONSOLE.md) (K-09, K-12, K-20)
- **Menü nasıl kullanılır?** — Sahadaki tek giriş noktası `sudo bf-menu` **operatör konsoludur**: 5 kategori numarayla seçilir, komut ezberlenmez (**1** Installation, **2** Device operations, **3** Central (preparation), **4** Tools, **5** Device information; ana ekranda `q` = çıkış, alt menülerde `0` = geri). Her komut çalıştırılmadan önce ekranda gösterilir ve onay istenir; yıkıcı işlemler iki kez sorar. Kurulumda "**Dealer number (8 digits)**" sorulur (ör. `12010193` → `BF-12010193` / `bf-12010193`); geçersiz format kurulumu başlatmaz (K-12). Filo işlemleri (kategori 2) hedefi **tek cihaz (bayi no) / grup-dalga (lab, pilot_1, pilot_2, wave_1, wave_2, production) / tüm filo** olarak seçtirir; wave-scoped playbook'ta "tüm filo" dalga dalga ilerler ve her dalga ayrı onaylanır, production için `production` yazmak zorunludur (K-11). Onaysız güncelleme seçeneği **yoktur**; `bf-gui-*` yalnız **yerel fiziksel** ekranı açar/kapatır, RDP (xrdp/xrdp-sesman) her zaman hazırdır (K-22). Şifre üretimi opsiyoneldir ve **varsayılan kapalıdır** (`bf-creds --generate`; parola ekrana/loga gitmez). Denetim log'u `/var/log/blueforce-console.log` (mod `600`). → [`33`](docs/33-OPERATOR-CONSOLE.md), [`09`](docs/09-FLEET-MANAGEMENT.md), [`10`](docs/10-UPDATE-AND-ROLLBACK-POLICY.md) (K-11, K-13, K-22)
- **ISO nasıl build edilir?** — Autoinstall kurulum **motorudur**, Blueforce Field OS ISO ise **paketleme/dağıtım** yöntemidir; ikisi rakip değil, birlikte kullanılır. `provisioning/iso/build-blueforce-iso.sh --upstream-iso <BASE> --checksum-file <SHA256SUMS>` çalıştırılır; builder base ISO'yu doğrular, ağacı çıkarır, autoinstall + firstboot + offline-repo araçlarını ekler, GRUB satırlarına autoinstall yazar ve boot düzenini base ISO'nun kendi `as_mkisofs` reçetesinden yeniden kurar. **ISO üretilmiştir:** `dist/Blueforce-Field-OS-1.0.0-amd64.iso` (6 481 917 952 byte, SHA256 `cb0cc56f…d431296`), El Torito BIOS+UEFI korunmuş, `/autoinstall.yaml` medya kökünde. Boot kabulü (UEFI/Legacy/Secure Boot) ve air-gapped kurulum hâlâ LAB işidir; resmi Ubuntu ISO + NoCloud seed USB yedek/geri dönüş yoludur. → [`26`](docs/26-BLUEFORCE-FIELD-OS-ISO.md), [`32`](docs/32-REPOSITORY-AUDIT-AND-CONFLICTS.md) (K-15, K-20)
- **Offline kurulum nasıl çalışır?** — Sürümlü medya + offline APT snapshot kullanılır; `blueforce-install.sh --offline` yalnız yerel `file:` APT kaynağından paket kurar (uzak indirme, key download, `apt download` yok) ve kurulum `PROVISIONED_OFFLINE` durumuna gelir. Subiquity'nin `apt.fallback` varsayılanı zaten `offline-install`'dır. Medya manifestlerinde somut `package=version` pinleri yoksa kurucu `OFFLINE BLOCKED` ile durur — "offline olur" demek için paket seti gerçekten dolu olmalıdır. → [`27`](docs/27-OFFLINE-PROVISIONING.md), [`31`](docs/31-LEARNING-GUIDE.md) (K-16, K-20, K-21)
- **Device state'leri nedir?** — Üç durum, tek sıra: `PROVISIONED_OFFLINE` → `ENROLLED` → `READY`. Tek kaynak `/var/lib/blueforce/state.json`, okuma komutu `bf-enrollment-status`. `READY` **tek durum değildir**: "kuruldu" READY değildir, "token alındı" READY değildir; yalnız WireGuard + merkezi remote + monitoring kanıtı doğrulanınca READY yazılır ve `bf-check-ready` bu kanıtı her seferinde yeniden denetler. → [`27`](docs/27-OFFLINE-PROVISIONING.md), [`29`](docs/29-DEVICE-ENROLLMENT.md) (K-16, K-17, K-21)
- **Internet olmadan ne olur?** — Yerel kurulum tamamlanır: paketler offline snapshot'tan gelir, cihaz `PROVISIONED_OFFLINE` olur. Cihaz çalışır ama merkezce doğrulanmamıştır: uzaktan erişim/izleme kanalları ve READY kapısı kapalı kalır. Yerel GUI kapalıyken bile xRDP servisi ayaktadır; ancak WireGuard tüneli olmadığı için merkezden erişilemez. → [`27`](docs/27-OFFLINE-PROVISIONING.md) (K-16, K-21, K-22)
- **Internet gelince ne olur?** — Merkezi admin, `BF-<no>`'ya bağlı kısa ömürlü ve tek kullanımlık token üretir; teknisyen tokenı yalnız cihaz ekranına girer (`bf-enroll --token-stdin`). Token tüketilince WireGuard yapılandırması atomik kurulur ve durum `ENROLLED` olur. Ardından güncel WG handshake, xRDP/RustDesk yapılandırması ve merkezi `monitoring`/`remote`/`management` kanıtı doğrulanınca `READY` yazılır; kanıt `pending` ya da eksikse cihaz ENROLLED'da kalır (fail-closed). → [`29`](docs/29-DEVICE-ENROLLMENT.md) (K-17, K-21)
- **Enrollment nasıl olur?** — Tek kullanımlık, TTL'li ve `BF-<no>`'ya bağlı token ile; token medyada/logda/support bundle'da tutulmaz, ikinci kullanım reddedilir ve audit kaydı üretilir. Enrollment bir "bağlantı kanıtı" değil, **kimlik bağlama** adımıdır; bu yüzden READY ayrı bir kapıdır. → [`29`](docs/29-DEVICE-ENROLLMENT.md) (K-17)
- **Windows'tan geçmeden önce ne yedeklenir?** — Üç kayıt: (1) donanım/bayi/seri no + çevre birimi + kritik iş akışı envanteri, (2) PowerShell araçlarıyla (`BF-WindowsPreMigrationInventory.ps1`, `BF-WindowsDataExport.ps1`) veri/uygulama dışa aktarımı, (3) hash'i doğrulanmış **Windows geri dönüş imajı** (restore sahibi ve saklama kaydıyla). Field OS temiz kurulumu bu imajı otomatik silmez; kabul başarısızsa imaj geri yüklenir. → [`28`](docs/28-WINDOWS-TO-LINUX-MIGRATION.md) (K-19)
- **Rollback nasıl olur?** — Üç seviye: (1) paket/config seviyesinde önceki **onaylı release manifestine** dönüş (`bf-release` ile sürüm kimliği doğrulanır), (2) imaj seviyesinde sorun varsa resmi Ubuntu ISO + önceki onaylı seed ile yeniden kurulum, (3) kabul başarısızsa Windows geri dönüş imajının restore edilmesi. Dalga içi başarısızlıkta yayılım durur ve etkilenen dalga geri alınır. → [`30`](docs/30-FIELD-OS-RELEASE-MANAGEMENT.md), [`10`](docs/10-UPDATE-AND-ROLLBACK-POLICY.md), [`26`](docs/26-BLUEFORCE-FIELD-OS-ISO.md) (K-18, K-20)
- **Field OS version nasıl takip edilir?** — Cihazda `bf-release` komutu okunur; kaynak sırası `BF_RELEASE_MANIFEST` → `/etc/blueforce/release-manifest.yaml` → legacy `/etc/blueforce-release` → repo manifesti. Manifest `status: skeleton` ise komut `UNAPPROVED_SKELETON` yazar ve **exit≠0** verir: iskelet medya dağıtılabilir release sayılmaz. Gerçek sürüm kimliği immutable release manifestiyle (ISO/seed/offline APT snapshot/installer/Ansible commit + checksum) eşleşir. → [`30`](docs/30-FIELD-OS-RELEASE-MANAGEMENT.md) (K-18, K-24)
- **Operatör hangi rehberden öğrenir?** — Linux, ağ, otomasyon, ISO, enrollment ve rollback pratikleri yalnız LAB'da [`31`](docs/31-LEARNING-GUIDE.md) ile çalışılır; komutlar örnektir ve LAB doğrulaması gerektirir.

Bu 12 soru + öğrenme rehberi sorusu, karar günlüğünde S-28…S-37 olarak izlenir ([Ek B-2](docs/24-DECISION-LOG.md)); bu tura `docs/33` ile **"Nasıl kurulur?"** ve **"Menü nasıl kullanılır?"** soruları eklendi (yukarıdaki ilk bloğun devamı).

---

## 2. Şartnamedeki 27 Sorunun Kesin Cevabı

1. **Hangi Ubuntu? Server mı Desktop mı?** — Ubuntu **Server 26.04.1+ LTS**, GUI'siz minimal kurulum.
   Desktop ISO'sunun 6 GB RAM şartı saha bütçesini zorlar; GUI sonradan eklenir. → [`03`](docs/03-UBUNTU-BASELINE.md) (K-01)
2. **GNOME mu XFCE mi?** — Saha standardı **GNOME** (Ubuntu Desktop standardı, kullanıcı kararı); XFCE saha standardı değildir.
   Ancak K-23 gereği LAB'da GNOME vs XFCE **A/B ölçümü** yapılır (RAM, CPU, boot süresi, RDP güvenilirliği, RustDesk reboot sonrası,
   login screen, dummy display, 24/72 saat stabilite) ve karar ölçüm verisine göre revize edilebilir; RustDesk headless ZORUNLU
   şartı her iki kolda da korunur. → [`03`](docs/03-UBUNTU-BASELINE.md) (K-02, K-23)
3. **Normal boot GUI mi terminal mi?** — Cihazlar **terminale** (`multi-user.target`) boot eder;
   kapalı GUI = düşük RAM, düşük saldırı yüzeyi, öngörülebilir boot. → [`03`](docs/03-UBUNTU-BASELINE.md), [`16`](docs/16-POWER-LOSS-AND-AUTO-RECOVERY.md) (K-03)
4. **GUI nasıl açılıp kapatılacak?** — `sudo bf-gui-on` / `sudo bf-gui-off`, yalnız **yerel fiziksel** grafik katmanını
   (display-manager: gdm3/gdm/sddm/lightdm + default target) systemd üzerinden yönetir; varsayılan kapalıdır. `bf-gui-off`
   xRDP servislerini **asla** durdurmaz: `xrdp`/`xrdp-sesman` her zaman enable+active kalır, yani **GUI kapalı ≠ RDP kapalı**.
   → [`03`](docs/03-UBUNTU-BASELINE.md), [`07`](docs/07-REMOTE-ACCESS.md) (K-03, K-22)
5. **Cihaz isimlendirme standardı?** — 8 haneli bayi no → insan arayüzünde `BF-<no>` (büyük),
   makine adında `bf-<no>` (küçük); 9 sistemde (hostname, WireGuard peer, RustDesk, MeshCentral,
   Ansible, Prometheus, log, envanter, runbook) join anahtarıdır. Örn. `BF-12010193` / `bf-12010193`. → [`02`](docs/02-DEVICE-NAMING-AND-INVENTORY.md) (K-12)
6. **İlk PC hazırlığı nasıl?** — İmaj dondurulmadan **önce** `bf-hardware-inventory.sh` ile donanım
   taraması (CPU/RAM/disk/NIC/GPU profilleri) ve Windows keşfi (F0); profilsiz imaj sahada rastgele kırılır. → [`18`](docs/18-PILOT-AND-700-DEVICE-ROLLOUT.md), [`28`](docs/28-WINDOWS-TO-LINUX-MIGRATION.md) (K-09, K-19)
7. **Yeni PC kurulumu kaç adım?** — Teknisyen için akış: USB medyasıyla Ubuntu kur →
   `blueforce-install.sh --offline` + 8 haneli bayi no → `bf-status` ile `PROVISIONED_OFFLINE` gör →
   internet geldiğinde enrollment ve merkezi kontrolleri tamamla; yalnız sonra `READY` teslim edilir. →
   [`27`](docs/27-OFFLINE-PROVISIONING.md), [`29`](docs/29-DEVICE-ENROLLMENT.md), [`20`](docs/20-FIELD-TECHNICIAN-RUNBOOK.md) (K-16, K-17, K-21)
8. **Installer nasıl çalışacak?** — Tek giriş `blueforce-install.sh --dealer-id <8hane>`; çevrimdışı yol
   `--offline` ile yerel medya/snapshot kullanır ve yalnız `PROVISIONED_OFFLINE` yazar. `READY`, installer
   çıkış kodu değil enrollment sonrası merkezi WireGuard, erişim ve monitoring doğrulamasının sonucudur. →
   [`05`](docs/05-ONE-CLICK-INSTALLER.md), [`27`](docs/27-OFFLINE-PROVISIONING.md), [`29`](docs/29-DEVICE-ENROLLMENT.md) (K-21)
9. **WireGuard mimarisi?** — **Hub-spoke**: merkez hub (`10.8.0.1`), her cihaz spoke (peer adı `bf-<no>`,
   sabit `/32`); istemcide `PersistentKeepalive = 25` + `wg-quick@wg0` enable; SSH/RDP yalnızca tünel
   içinden, dış dünyaya kapalı. → [`08`](docs/08-WIREGUARD-AND-NETWORK.md) (K-05)
10. **SSH güvenliği nasıl?** — `blueforce` bakım kullanıcısı + **anahtar zorunlu**, password auth kapalı,
    root SSH kapalı; 700 cihaza tek private key **yayılmaz** — admin başına anahtar, Ansible ile merkezi
    `authorized_keys` dağıtımı, uzun vadede SSH CA hedefi. → [`06`](docs/06-USERS-SSH-AND-PERMISSIONS.md) (K-13)
11. **RDP nasıl?** — **xRDP + GNOME**, yalnızca WireGuard üzerinden; internete açık RDP portu yoktur.
    xRDP ve xrdp-sesman multi-user seviyesinde **her zaman enable+active** olduğu için RDP `bf-gui-on`
    beklemez; `bf-gui-*` yalnız yerel fiziksel GUI'yi açar/kapatır. → [`07`](docs/07-REMOTE-ACCESS.md), [`16`](docs/16-POWER-LOSS-AND-AUTO-RECOVERY.md) (K-05, K-22)
12. **RustDesk self-host neyi kapsar?** — **RustDesk OSS** istemci + `hbbs`/`hbbr` kendi VDS'imizde;
    sınırsız istemci, E2E şifreli oturum, dosya transferi, katılımsız erişim — hepsi ücretsiz. İstemci VDS
    genel adresine doğrudan çıktığı için **WireGuard çökse bile** kanal ayaktadır. Ubuntu 26.04.1 üzerinde
    headless/katılımsız davranış LAB'da doğrulanmadan dondurulmaz (zorunlu şart: reboot sonrası katılımsız çalışma).
    → [`07`](docs/07-REMOTE-ACCESS.md) (K-04, K-23)
13. **AnyDesk ücretsiz kullanılabilir mi?** — **HAYIR.** Free sürüm yalnızca kişisel kullanımı kapsar;
    700 kurumsal cihaz ticari kullanımdır, lisanssız kullanım sözleşme ihlalidir. Mimari dışıdır; yalnızca
    müşteride zaten ticari lisans varsa opsiyonel `--with-anydesk` modülü. → [`07`](docs/07-REMOTE-ACCESS.md), [`23`](docs/23-SECURITY-AND-LICENSE-AUDIT.md) (K-04)
14. **4. erişim kanalı ne?** — **MeshCentral** (self-hosted, Apache-2.0): ikincil yönetim düzlemi
    (terminal/dosya/envanter), RustDesk gibi WireGuard-bağımsız. 4 kanal = SSH-over-WG, xRDP, RustDesk, MeshCentral. → [`07`](docs/07-REMOTE-ACCESS.md) (K-04)
15. **Fleet yönetimi ne?** — Birincil **Ansible CLI** (SSH, agent'sız); **15 standart işlem**
    (`bf-ping`, `bf-status`, `bf-gui-on/off`, `reboot`…) playbook + Semaphore task şablonu olarak tanımlı;
    serbest komut yalnızca acil prosedürle; hedefleme tek → grup → pilot → tüm-filo. → [`09`](docs/09-FLEET-MANAGEMENT.md) (K-06)
16. **Semaphore kullanmalı mıyız?** — Evet, **Semaphore UI Community** (self-hosted, MIT, $0) operatör
    arayüzü olarak; Semaphore çökse Ansible CLI bağımsız çalışır. **Pro gerekmez** (zaten 500 node
    sınırıyla 700 cihaza yetmez). Community'de OIDC/2FA/Vault yoktur → yalnızca WireGuard arkasından erişim. → [`09`](docs/09-FLEET-MANAGEMENT.md) (K-06)
17. **Monitoring ne?** — Birincil **Prometheus + Node Exporter + Grafana OSS** (17 metriğin tamamı,
    özel metrikler textfile `.prom` ile); tamamlayıcı **Uptime Kuma** (teknisyen dostu UP/DOWN + Push
    "last seen" + bildirim). Netdata Cloud Free 5 node kotasıyla elendi. → [`14`](docs/14-MONITORING-AND-HEALTH.md) (K-07)
18. **Update onayı nasıl, kim başlatır, başarısız olursa ne olur?** — **Onaysız update yasaktır.**
    Başlatma yetkisi yalnızca **merkezi yöneticide** (asıl + vekil); her dalga Semaphore onay kapısından
    geçer: LAB(2) → P1(5) → P2(20) → W1(50) → W2(100) → PROD(~523). Başarısız dalga bir sonrakine geçmez,
    yayılım durur, etkilenmiş dalga rollback zinciriyle geri alınır; acil yamalar da aynı zincirden
    (kısaltılmış bekleme, kapılar kalkmaz) geçer. → [`10`](docs/10-UPDATE-AND-ROLLBACK-POLICY.md), [`21`](docs/21-CENTRAL-ADMIN-RUNBOOK.md) (K-11)
19. **`unattended-upgrades` ne olacak?** — Golden image'da **kapalı** (`20auto-upgrades` değerleri `0` +
    `apt-daily*.timer` maskeleme); kapatılmazsa Ubuntu varsayılanı 700 cihazı ilk açılışta güncellemeye
    kalkar. Kilit, kurucu final-check + monitoring metriğiyle denetlenir. → [`03`](docs/03-UBUNTU-BASELINE.md), [`10`](docs/10-UPDATE-AND-ROLLBACK-POLICY.md) (K-11)
20. **Docker politikası ne?** — Restart `unless-stopped`; **`latest` yasak** (sabit tag, digest P2'de
    değerlendirilir); **Watchtower yasak**; log rotasyonu `daemon.json`'da zorunlu; yayımlanan portlar
    UFW bypass'a karşı **`127.0.0.1`**'e bağlanır. → [`12`](docs/12-DOCKER-OPERATIONS.md), [`11`](docs/11-SECURITY-HARDENING.md) (K-10)
21. **Log disiplini + disk dolması engeli?** — journald kalıcı + tavanlı (`SystemMaxUse`/`MaxFileSec`),
    Docker `json-file` rotasyonlu, 7 kaynak standardı + `bf-status`/`bf-diagnostics`/`bf-support-bundle`
    (secret sızdırmaz); merkezi Loki/ELK ilk fazda yok (Faz-sonrası hedef). Rotasyonsuz log = kilitlenen
    cihaz kuralıyla disk taşması mimari düzeyde engellenir. → [`15`](docs/15-LOGGING.md), [`12`](docs/12-DOCKER-OPERATIONS.md) (K-14/K-10)
22. **Elektrik kesintisi ve dönüşü?** — BIOS `Restore on AC Power Loss = Power On` ile cihaz kendiliğinden
    açılır; systemd sıralı boot zinciri (network → `wg-quick` → docker → MEG → agent'lar) + `unless-stopped`
    ile her katman kendiliğinden toparlanır, ek kurtarma servisi yoktur. xRDP de bu zincirde her zaman hazır kalır. → [`16`](docs/16-POWER-LOSS-AND-AUTO-RECOVERY.md) (K-03/K-10/K-22)
23. **İnternet paketi bitimi ve dönüşü?** — Kota bitince tünel sessizce ölür (arıza değil, "çevrimdışı"
    görünür; Kuma "last seen" alarmı + bayiye bildirim); kota dönüşünde `wg-quick` + keepalive **kendiliğinden**
    yeniden handshake eder, ek işlem gerekmez. Kota-dostu keepalive (25 sn, PİLOT verisiyle ayarlanır). → [`08`](docs/08-WIREGUARD-AND-NETWORK.md) (K-05)
24. **PC bozulunca teknisyen ne yapar?** — **9 seviyeli kurtarma merdiveni** (L1 servis restart → … →
    L8 USB ile sıfırdan imaj → L9 merkez inşası); cihaz "değiştirilebilir" sayılır, kimlik + config merkezden
    yeniden basılır, cihaz-başı veri yedeği yoktur. Çoğu arıza 4 kanaldan biriyle uzaktan çözülür, sahaya
    gidilmez. → [`17`](docs/17-BACKUP-RECOVERY-AND-REINSTALL.md), [`20`](docs/20-FIELD-TECHNICIAN-RUNBOOK.md)
25. **Golden image yöntemi ne?** — Kimliksiz zemin (Server 26.04.1+ minimal + update kapalı + kurucu), tek USB
    Field OS ISO (autoinstall + offline APT + firstboot) ile kurulur; cihaz-spesifik kimlik (`bf-<no>`) imajda
    **değil ilk açılışta** enjekte edilir. Assisted kurulumda storage adımı operatör onayı bekler (otomatik disk
    silme yok). Clonezilla bit-kopya yalnızca yedek yöntemdir (donanım-fragil). → [`04`](docs/04-GOLDEN-IMAGE-AND-PROVISIONING.md), [`05`](docs/05-ONE-CLICK-INSTALLER.md), [`26`](docs/26-BLUEFORCE-FIELD-OS-ISO.md) (K-09, K-20)
26. **700 cihaz rollout nasıl?** — Üstel dalgalar: LAB(2) → P1(5) → P2(20) → W1(50) → W2(100) → PROD(~523);
    hiçbir dalga önceki çıkış kriterini sağlamadan başlamaz; halt kuralları (≥2 kritik arıza / >%10 çevrimdışı /
    2× kurulum süresi) yayılımı durdurur. Faz karşılığı: LAB = F3, P1-P2-W1-W2 = F4, PROD = F5. → [`18`](docs/18-PILOT-AND-700-DEVICE-ROLLOUT.md), [`25`](docs/25-IMPLEMENTATION-ROADMAP.md) (K-11)
27. **Docs platformu ne?** — **Docusaurus**; kaynak yalnız `docs/[0-9][0-9]-*.md` numaralı dosyalardır,
    site CI'da derlenir, `docs/_TEMPLATE.md` siteye alınmaz ve siteye elle yazma yasaktır. Yedek: MkDocs + Material. →
    [`22`](docs/22-DOCUMENTATION-PLATFORM.md)

---

## 2. 700 İstasyonda 5 Yıllık En Büyük 10 Operasyonel Risk

| # | Risk | Önlem |
|---|---|---|
| 1 | **Onaysız update kaçağı** — tek imajda `unattended-upgrades` açık unutulur, 700 cihaz kendiliğinden güncellenir. | Kurucu `18-final-check` kapısı + monitoring'de `unattended_upgrade_active` metriği (1 = ihlal alarmı); K-11 kilidi üç dosyada (03/10/12) denetlenir. |
| 2 | **Tek VDS ortak arıza noktası** — hub + hbbs/hbbr + MeshCentral aynı makinede; VDS giderse 2 bağımsız kanal da gider. | Yedek VDS planı + üç ayda bir "boş VDS'e sıfırdan kur" L9 tatbikatı; IaC Git'te, veriler günlük dosya yedeğinde ([`17`](docs/17-BACKUP-RECOVERY-AND-REINSTALL.md)). |
| 3 | **Heterojen/yeni-parti donanım imajı kırar** — 5 yılda donanım partileri değişir, sürücü eksiği sahada patlar. | Her yeni parti LAB profil matrisine girer; imaj, envanter taraması olmadan dondurulmaz ([`18`](docs/18-PILOT-AND-700-DEVICE-ROLLOUT.md), [`04`](docs/04-GOLDEN-IMAGE-AND-PROVISIONING.md)). |
| 4 | **Semaphore kapı bypass'ı** — acil bahanesiyle CLI'dan onaysız PROD run, dalga disiplini kağıtta kalır. | Semaphore dışı PROD run'ı yasak + denetim logu izlenir; onaysız run testi merkez test planında ([`21`](docs/21-CENTRAL-ADMIN-RUNBOOK.md)). |
| 5 | **Prometheus kardinalite/retention şişmesi** — 700 node × 5 yıl metrik ve log hacmi merkez diskini ve sorguları yorar. | 60 sn scrape, 30–90 gün retention, `BF-<no>` etiket disiplini; PİLOT hacim ölçümüyle donanım siparişi, federasyon hedefi ([`14`](docs/14-MONITORING-AND-HEALTH.md)). |
| 6 | **Teknisyen hatası ölçeklenir** — yanlış bayi no (kimlik çakışması), READY görülmeden çıkış, eski USB ile kurulum. | Kurucuda format kapısı + sesli onay ekranı; kontrol listesi imzalanmadan iş kapanmaz; USB sürüm etiketi ([`20`](docs/20-FIELD-TECHNICIAN-RUNBOOK.md), [`02`](docs/02-DEVICE-NAMING-AND-INVENTORY.md)). |
| 7 | **Turkcell hat/kota davranış değişimi** — CGNAT eşleme süresi veya kota politikası değişir, tüneller toplu düşer. | P1 7/24 kopma sayacıyla keepalive saha verisine bağlanır; Kuma "last seen" + paket-bitim bildirim akışı ([`08`](docs/08-WIREGUARD-AND-NETWORK.md)). |
| 8 | **Upstream lisans/kapsam daralması** — RustDesk/Grafana/Semaphore free kapsamı 5 yıl içinde değişebilir. | Yıllık lisans gözden geçirme + her ücretli-adayın ücretsiz karşılığı tabloda hazır; değişiklik 24-PR ile işletilir ([`23`](docs/23-SECURITY-AND-LICENSE-AUDIT.md)). |
| 9 | **SSH anahtar sızıntısı** — tek private key 700 cihazı açar; ayrılan personelin anahtarı unutulur. | Per-admin anahtar + Ansible merkezi dağıtım/iptal, paylaşılan key politikada yasak + denetim scripti; SSH CA Faz-sonrası hedef ([`06`](docs/06-USERS-SSH-AND-PERMISSIONS.md)). |
| 10 | **IaC drift + denenmemiş kurtarma** — Git'teki playbook gerçek merkezden sapar, L9 günü çalışmaz. | Üç aylık L9 tatbikatı + aylık yedek-doğrulama job'ı (açılabilirlik + hash); sonuç monitoring'e işlenir ([`17`](docs/17-BACKUP-RECOVERY-AND-REINSTALL.md)). |

---

## 3. Gerçekten Tamamen Ücretsiz Olanlar (FREE katman, lisans bedeli $0)

> Kapsam: yazılım lisansları. Merkezi VDS kirası altyapı maliyetidir, lisans değildir.

| Bileşen | Sürüm/katman | Lisans | Kaynak |
|---|---|---|---|
| Ubuntu Server LTS | 26.04.1+ (ESM'e bel bağlanmaz) | Açık kaynak | [`03`](docs/03-UBUNTU-BASELINE.md) |
| GNOME | saha standardı (Ubuntu Desktop); XFCE yalnız LAB A/B ölçüm adayı | GPL/LGPL bileşenler | [`03`](docs/03-UBUNTU-BASELINE.md) |
| xRDP | v0.10.6.1 | Apache-2.0 | [`03`](docs/03-UBUNTU-BASELINE.md), [`07`](docs/07-REMOTE-ACCESS.md) |
| WireGuard + wg-quick | wireguard-tools 1.0.20250521-1ubuntu1 | OSS | [`08`](docs/08-WIREGUARD-AND-NETWORK.md) |
| OpenSSH / UFW | sistem paketleri | BSD / GPL bileşenler | [`06`](docs/06-USERS-SSH-AND-PERMISSIONS.md), [`11`](docs/11-SECURITY-HARDENING.md) |
| Autoinstall / cloud-init NoCloud | Subiquity + cloud-init | Açık kaynak (Ubuntu lisans seti) | [`26`](docs/26-BLUEFORCE-FIELD-OS-ISO.md), [`27`](docs/27-OFFLINE-PROVISIONING.md) |
| Docker CE | (Business/Scout mimaride yok) | Ücretsiz | [`12`](docs/12-DOCKER-OPERATIONS.md) |
| RustDesk istemci + sunucu (hbbs/hbbr) | 1.4.9 / 1.1.16, OSS | AGPL-3.0 | [`07`](docs/07-REMOTE-ACCESS.md) |
| MeshCentral | 1.2.5 | Apache-2.0 | [`07`](docs/07-REMOTE-ACCESS.md) |
| Ansible | CLI, agent'sız | GPL-3.0 | [`09`](docs/09-FLEET-MANAGEMENT.md) |
| Semaphore UI | Community ($0, free forever) | MIT | [`09`](docs/09-FLEET-MANAGEMENT.md) |
| Prometheus + Node Exporter | kotasız self-host | Apache-2.0 | [`14`](docs/14-MONITORING-AND-HEALTH.md) |
| Grafana | OSS (değişikliksiz self-host) | AGPL-3.0 | [`14`](docs/14-MONITORING-AND-HEALTH.md) |
| Uptime Kuma | tek konteyner | MIT | [`14`](docs/14-MONITORING-AND-HEALTH.md) |
| Docusaurus | statik site | MIT | [`22`](docs/22-DOCUMENTATION-PLATFORM.md) |
| systemd / journald | log + servis zinciri | LGPL bileşenler | [`15`](docs/15-LOGGING.md), [`16`](docs/16-POWER-LOSS-AND-AUTO-RECOVERY.md) |

**Ücretsiz DEĞİL / mimaride YOK (kullanılırsa lisans gerekir):** AnyDesk Free (ticari kullanımda ihlal) → [`23`](docs/23-SECURITY-AND-LICENSE-AUDIT.md);
RustDesk Pro (gerekmez); Semaphore Pro/Enterprise (500 node sınırı + ücretli); Netdata Cloud Free (5 node kotası);
Tailscale/ZeroTier ücretli kademeler; Ubuntu Pro/ESM (bel bağlanmaz). Tam hüküm tablosu [`23 §9`](docs/23-SECURITY-AND-LICENSE-AUDIT.md),
kaynak URL'ler [`24 Ek A`](docs/24-DECISION-LOG.md).

---

## Ek: QA Doğrulama (2026-09-16 güncellemesi)

- **33 numaralı doküman mevcut:** `docs/00` … `docs/32` (+ `docs/_TEMPLATE.md`); kanonik set `00`–`31`, `32` denetim/çelişki raporudur.
  - **Ek (operatör konsolu):** `docs/33-OPERATOR-CONSOLE.md` eklendi (§1–§13 + Mermaid; git kurulumu + `bf-menu` menü rehberi). Numaralı set artık `docs/00` … `docs/33` (34 dosya).
- **13 başlık:** 33 dosyanın tamamında §1–§13 sıralı ve eksiksiz (bu turda `docs/32` §1–§13 yapısına getirildi).
- **Mermaid:** 33/33 dosyada ≥1 diyagram; toplam 35 blok (30 dosyada 1, birkaçında 2+).
- **BF-/bf- tutarlılığı:** insan arayüzü `BF-<no>`, makine adı `bf-<no>`; aykırı kullanım yok (kalan `BF-xxxx`/`BF-no` ifadeleri şablon yer tutucudur).
- **Ücretli sızıntı:** yok — ücretli geçen her satır elendi/hüküm/denetim bağlamında.
- **Onaysız-update kapısı:** yok — `unattended-upgrades`/`latest`/Watchtower yasakları 03/10/12'de ve
  K-11'de kilitli; acil yama bile onay + rollback testinden geçer.
- **Durum tutarlılığı (bu turun konusu):** README, SUMMARY, 24, 25 ve 32 aynı şeyi söyler: medya (autoinstall + Field OS ISO),
  3 durumlu model, RDP her zaman hazır / `bf-gui-*` yalnız yerel GUI, GNOME baseline + LAB A/B, offline-assisted F2B vs
  zero-touch F6. Giderilemeyen artıklar ve açık maddeler [`docs/32`](docs/32-REPOSITORY-AUDIT-AND-CONFLICTS.md) §"Giderim Durumu" içindedir.
- **Test durumu (2026-09-16 10:52 anlık görüntüsü):** `check-configs.sh`, `check-migration-static.sh`, `check-offline-repo-static.sh`,
  `check-provisioning-static.sh`, `test-firstboot-static.sh` **GEÇTİ**; `check-specs.sh` iki **bayat sabit** nedeniyle düşer
  (kanonik doküman sayısı `32`→`33`, Mermaid toplamı `34`→`35`); `test-field-os-lifecycle.sh` **kırmızı** (READY/durum sözleşmesi).
  Düzeltmeler `tests/` ve ilgili provisioning akışı kapsamındadır — ayrıntı [`docs/32 §10`](docs/32-REPOSITORY-AUDIT-AND-CONFLICTS.md).
- **Üretim artefaktı:** henüz `*.iso` yok, `*.deb` havuzu yok, offline pinler `UNPINNED` sentinel, `packages.lock.tsv` yok,
  merkezi enrollment endpoint'i yok. Yani "offline kurulum çalışıyor" bugün **kanıtlanmış değildir**; F2A/F2B kapıları açıktır.
