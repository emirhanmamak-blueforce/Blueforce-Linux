# Blueforce Linux — Yönetici Özeti (SUMMARY)

> 700 saha cihazlık filonun kesin kararları, en büyük 10 operasyonel riski ve ücretsiz-bileşen listesi.
> Ayrıntı `docs/` dosyalarındadır; her cevap ilgili dokümana linklenir. Kararların kilit kaynağı
> [`docs/24-DECISION-LOG.md`](docs/24-DECISION-LOG.md) (K-01…K-14), izlenebilirlik tablosu Ek B'dedir (S-01…S-27).
> Mimari tek bakış: [`docs/01-ARCHITECTURE.md`](docs/01-ARCHITECTURE.md). Commit yok, FREE sürümler baz.

---

## 1. Şartnamedeki 27 Sorunun Kesin Cevabı

1. **Hangi Ubuntu? Server mı Desktop mı?** — Ubuntu **Server 26.04.1+ LTS**, GUI'siz minimal kurulum.
   Desktop ISO'sunun 6 GB RAM şartı saha bütçesini zorlar; GUI sonradan eklenir. → [`03`](docs/03-UBUNTU-BASELINE.md) (K-01)
2. **GNOME mu XFCE mi?** — Cevap **GNOME** (Ubuntu Desktop standardı, kullanıcı kararı); XFCE elendi.
   → [`03`](docs/03-UBUNTU-BASELINE.md) (K-02)
3. **Normal boot GUI mi terminal mi?** — Cihazlar **terminale** (`multi-user.target`) boot eder;
   kapalı GUI = düşük RAM, düşük saldırı yüzeyi, öngörülebilir boot. → [`03`](docs/03-UBUNTU-BASELINE.md), [`16`](docs/16-POWER-LOSS-AND-AUTO-RECOVERY.md) (K-03)
4. **GUI nasıl açılıp kapatılacak?** — `sudo bf-gui-on` / `sudo bf-gui-off` ile systemd üzerinden
   (display-manager + `xrdp`/`xrdp-sesman`); varsayılan kapalıdır. → [`03`](docs/03-UBUNTU-BASELINE.md), [`07`](docs/07-REMOTE-ACCESS.md) (K-03)
5. **Cihaz isimlendirme standardı?** — 8 haneli bayi no → insan arayüzünde `BF-<no>` (büyük),
   makine adında `bf-<no>` (küçük); 9 sistemde (hostname, WireGuard peer, RustDesk, MeshCentral,
   Ansible, Prometheus, log, envanter, runbook) join anahtarıdır. Örn. `BF-12010193` / `bf-12010193`. → [`02`](docs/02-DEVICE-NAMING-AND-INVENTORY.md) (K-12)
6. **İlk PC hazırlığı nasıl?** — İmaj dondurulmadan **önce** `bf-hardware-inventory.sh` ile donanım
   taraması (CPU/RAM/disk/NIC/GPU profilleri); profilsiz imaj sahada rastgele kırılır. → [`18`](docs/18-PILOT-AND-700-DEVICE-ROLLOUT.md), [`02`](docs/02-DEVICE-NAMING-AND-INVENTORY.md) (K-09)
7. **Yeni PC kurulumu kaç adım?** — Teknisyen için **4 adım**: USB tak → Ubuntu kur →
   `blueforce-install.sh` + 8 haneli bayi no → `bf-status` ile READY gör, çık (<15 dk aktif iş). → [`20`](docs/20-FIELD-TECHNICIAN-RUNBOOK.md), [`04`](docs/04-GOLDEN-IMAGE-AND-PROVISIONING.md) (K-09)
8. **Installer nasıl çalışacak?** — Tek giriş `blueforce-install.sh --dealer-id <8hane>`; **18 idempotent
   modül** (precheck → dealer-id → paketler → GNOME → xRDP → SSH → WireGuard → Docker → MEG → RustDesk →
   MeshCentral → monitoring → firewall → envanter → logging → boot → bootstrap → final-check),
   çıkış kodu 0 = READY, format kapısı + onay ekranlı. → [`05`](docs/05-ONE-CLICK-INSTALLER.md) (K-09)
9. **WireGuard mimarisi?** — **Hub-spoke**: merkez hub (`10.8.0.1`), her cihaz spoke (peer adı `bf-<no>`,
   sabit `/32`); istemcide `PersistentKeepalive = 25` + `wg-quick@wg0` enable; SSH/RDP yalnızca tünel
   içinden, dış dünyaya kapalı. → [`08`](docs/08-WIREGUARD-AND-NETWORK.md) (K-05)
10. **SSH güvenliği nasıl?** — `blueforce` bakım kullanıcısı + **anahtar zorunlu**, password auth kapalı,
    root SSH kapalı; 700 cihaza tek private key **yayılmaz** — admin başına anahtar, Ansible ile merkezi
    `authorized_keys` dağıtımı, uzun vadede SSH CA hedefi. → [`06`](docs/06-USERS-SSH-AND-PERMISSIONS.md) (K-13)
11. **RDP nasıl?** — **xRDP + GNOME**, yalnızca WireGuard üzerinden; internete açık RDP portu yoktur.
    Grafik katman kapalıyken RDP açılmaz (`bf-gui-on` gerekir). → [`07`](docs/07-REMOTE-ACCESS.md) (K-03/K-05)
12. **RustDesk self-host neyi kapsar?** — **RustDesk OSS** istemci + `hbbs`/`hbbr` kendi VDS'imizde;
    sınırsız istemci, E2E şifreli oturum, dosya transferi, katılımsız erişim — hepsi ücretsiz. İstemci VDS
    genel adresine doğrudan çıktığı için **WireGuard çökse bile** kanal ayaktadır. → [`07`](docs/07-REMOTE-ACCESS.md) (K-04)
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
    ile her katman kendiliğinden toparlanır, ek kurtarma servisi yoktur. → [`16`](docs/16-POWER-LOSS-AND-AUTO-RECOVERY.md) (K-03/K-10)
23. **İnternet paketi bitimi ve dönüşü?** — Kota bitince tünel sessizce ölür (arıza değil, "çevrimdışı"
    görünür; Kuma "last seen" alarmı + bayiye bildirim); kota dönüşünde `wg-quick` + keepalive **kendiliğinden**
    yeniden handshake eder, ek işlem gerekmez. Kota-dostu keepalive (25 sn, PİLOT verisiyle ayarlanır). → [`08`](docs/08-WIREGUARD-AND-NETWORK.md) (K-05)
24. **PC bozulunca teknisyen ne yapar?** — **9 seviyeli kurtarma merdiveni** (L1 servis restart → … →
    L8 USB ile sıfırdan imaj → L9 merkez inşası); cihaz "değiştirilebilir" sayılır, kimlik + config merkezden
    yeniden basılır, cihaz-başı veri yedeği yoktur. Çoğu arıza 4 kanaldan biriyle uzaktan çözülür, sahaya
    gidilmez. → [`17`](docs/17-BACKUP-RECOVERY-AND-REINSTALL.md), [`20`](docs/20-FIELD-TECHNICIAN-RUNBOOK.md)
25. **Golden image yöntemi ne?** — Kimliksiz zemin (Server 26.04.1+ minimal + update kapalı + kurucu) USB/autoinstall
    ile kurulur; cihaz-spesifik kimlik (`bf-<no>`) imajda **değil ilk açılışta** enjekte edilir. Clonezilla
    bit-kopya yalnızca yedek yöntemdir (donanım-fragil). → [`04`](docs/04-GOLDEN-IMAGE-AND-PROVISIONING.md), [`05`](docs/05-ONE-CLICK-INSTALLER.md) (K-09)
26. **700 cihaz rollout nasıl?** — Üstel dalgalar: LAB(2) → P1(5) → P2(20) → W1(50) → W2(100) → PROD(~523);
    hiçbir dalga önceki çıkış kriterini sağlamadan başlamaz; halt kuralları (≥2 kritik arıza / >%10 çevrimdışı /
    2× kurulum süresi) yayılımı durdurur. → [`18`](docs/18-PILOT-AND-700-DEVICE-ROLLOUT.md) (K-11)
27. **Docs platformu ne?** — **Docusaurus**; kaynak `docs/*.md` tek-kaynaktır, site CI'da derlenir, siteye
    elle yazma yasaktır. Yedek: MkDocs + Material. → [`22`](docs/22-DOCUMENTATION-PLATFORM.md) (K-08)

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
| GNOME | saha standardı (Ubuntu Desktop) | GPL/LGPL bileşenler | [`03`](docs/03-UBUNTU-BASELINE.md) |
| xRDP | v0.10.6.1 | Apache-2.0 | [`03`](docs/03-UBUNTU-BASELINE.md) |
| WireGuard + wg-quick | wireguard-tools 1.0.20250521-1ubuntu1 | OSS | [`08`](docs/08-WIREGUARD-AND-NETWORK.md) |
| OpenSSH / UFW | sistem paketleri | BSD / GPL bileşenler | [`06`](docs/06-USERS-SSH-AND-PERMISSIONS.md), [`11`](docs/11-SECURITY-HARDENING.md) |
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

## Ek: QA Doğrulama (2026-09-15)

- **26 dosya mevcut:** `docs/00` … `docs/25` tamamı var (+ `_TEMPLATE.md`).
- **13 başlık:** 26 dosyanın tamamında §1–§13 sıralı ve eksiksiz.
- **Mermaid:** 26/26 dosyada ≥1 diyagram (03/19/21/23/24'e bu özetle birlikte eklendi).
- **BF-/bf- tutarlılığı:** insan arayüzü `BF-<no>`, makine adı `bf-<no>`; aykırı kullanım yok.
- **Ücretli sızıntı:** yok — ücretli geçen her satır elendi/hüküm/denetim bağlamında.
- **Onaysız-update kapısı:** yok — `unattended-upgrades`/`latest`/Watchtower yasakları 03/10/12'de ve
  K-11'de kilitli; acil yama bile onay + rollback testinden geçer.
