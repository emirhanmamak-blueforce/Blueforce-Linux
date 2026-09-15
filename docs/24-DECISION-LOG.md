# 24 — Karar Günlüğü (Decision Log)

> Kısa özet: Blueforce 700 cihaz Linux filosunun tüm nihai mimari kararları tek tabloda; her karar KARAR/GEREKÇE/ALTERNATİF/RİSK/MALİYET/LİSANS bloğu + resmi kaynak URL ile. Diğer 25 dokümanın başvurduğu kilit dosyadır.
>
> - Dosya: `docs/24-DECISION-LOG.md`
> - İlgili kararlar: bu dosyanın kendisi kilit kaynaktır; `01-ARCHITECTURE.md` bu kararları diyagramlaştırır.
> - Durum: [x] Onaylı (Faz 2 kilidi; değişiklik bu dosyadan PR ile yapılır)
> - Kural: tüm kararlarda FREE sürümler baz alınır; Pro/Enterprise zorunlu mimariye girmez.
> - Doğrulama günü: 2026-09-15 (tüm URL'ler bu tarihte HTTP 200 ile çekildi; ayrıntı `research/` dosyalarında).

---

## 1. Amaç

27 izlenebilirlik sorusunun (bkz. §13 ve Ek B) her birinin hangi karara dayandığını tek yerden göstermek; kararsız veya varsayıma dayalı seçim bırakmamak.

## 2. Kapsam

- Kapsam içi: OS/GUI/boot, 4 erişim kanalı, WireGuard, fleet, monitoring, docs, golden image, Docker, cihaz kimliği, update dalgaları — aşağıdaki K-01…K-14 kararları.
- Kapsam dışı: script kodları, VDS kurulum komutları, gerçek cihaz test sonuçları (Faz 3+ işi; ilgili dokümanlara havale edilir).

## 3. Kararlar

### K-01 — Baz işletim sistemi ve sürüm

```text
KARAR:    Saha standardı Ubuntu Server 26.04.1+ LTS'tir (GUI'siz minimal kurulum; GNOME sonradan eklenir).
GEREKÇE:  26.04.1 LTS resmi indirme sayfasında yayında (kod adı Resolute Raccoon); Server ISO'su varsayılan olarak GUI kurmaz, minimal zemin + ihtiyaca göre GUI standart yoldur. Noktasürüm (.1+) baz alınır çünkü ilk .0 dalgasındaki kurulumcu hataları genelde .1'de toplanır (LAB imaj testiyle kesinleşir).
ALTERNATİF: Ubuntu 24.04 LTS — 26.04 doğrulanamasaydı yedekti; doğrulandığı için yedekte bekler. Ubuntu Desktop 26.04 (6 GB RAM şartı) saha bütçesini zorladığı için elendi.
RİSK:     26.04.x noktasürümlerinde donanım sürücü farkı; azaltma: golden image LAB(2)'de her saha donanım profilinde test edilir.
MALİYET:  Ücretsiz.
LİSANS:   Ubuntu LTS ücretsiz (açık kaynak bileşenler; ESM kapsamına bel bağlanmaz) — https://releases.ubuntu.com/ (26.04.1, doğrulanma: 2026-09-15) + https://ubuntu.com/download/desktop (sistem gereksinimi, doğrulanma: 2026-09-15).
```

### K-02 — Masaüstü ortamı (GNOME)

```text
KARAR:    Saha masaüstü ortamı GNOME'dur (Ubuntu Desktop standardı); XFCE elendi.
GEREKÇE:  Kullanıcı kararı + Ubuntu Desktop standardı: tanıdık modern masaüstü, teknisyen akışıyla birebir uyum.
ALTERNATİF: XFCE — hafif ve düşük kaynak tüketimine rağmen kullanıcı kararıyla elendi; yedekte tutulmaz.
RİSK:     xRDP+GNOME kombinasyonu ek ayar isteyebilir (uyarı: GNOME oturumu RDP'de ek yapılandırma gerektirebilir); azaltma: 13-MEG-LINUX-ACCEPTANCE testi GNOME üzerinde koşar, `bf-gui-*` LAB'da 26.04.1 imajında doğrulanmadan dondurulmaz.
MALİYET:  Ücretsiz.
LİSANS:   GNOME (GPL/LGPL bileşenler), ücretsiz — https://www.gnome.org/ (doğrulanma: 2026-09-15).
```

### K-03 — Boot davranışı ve GUI aç/kapa

```text
KARAR:    Cihazlar terminale (multi-user) boot eder; grafik katman `bf-gui-on` / `bf-gui-off` ile systemd üzerinden açılıp kapatılır.
GEREKÇE:  xRDP mimarisi oturum yöneticisi (sesman) + systemd servis birimleri (`xrdp`, `xrdp-sesman`) üzerine kuruludur; GUI, display-manager + xRDP servisleri üzerinden yönetilebilir bir katman olarak modellenir. Varsayılan kapalı GUI = düşük RAM, düşük saldırı yüzeyi, öngörülebilir boot.
ALTERNATİF: Her zaman grafik boot — kaynak israfı ve 700 cihazda gereksiz hata yüzeyi nedeniyle elendi.
RİSK:     Kesin birim adları ve GNOME oturum başlatma satırı 26.04.1'e göre değişebilir; azaltma: LAB'da 26.04.1 imajında doğrulanmadan `bf-gui-*` dondurulmaz.
MALİYET:  Ücretsiz.
LİSANS:   xRDP Apache-2.0, ücretsiz — https://github.com/neutrinolabs/xrdp (v0.10.6.1, 2026-07-07; doğrulanma: 2026-09-15).
```

### K-04 — Uzaktan erişim kanalları (4 kanal)

```text
KARAR:    Dört erişim kanalı: (1) SSH-over-WireGuard (yönetim/otomasyon), (2) xRDP + GNOME (grafik bakım), (3) RustDesk OSS self-hosted hbbs/hbbr (birincil grafik uzak erişim, WireGuard-bağımsız), (4) MeshCentral self-hosted (ikincil yönetim: terminal/dosya/envanter, WireGuard-bağımsız). AnyDesk mimariden ÇIKARILDI.
GEREKÇE:  RustDesk OSS sınırsız istemci, kendi ID+röle altyapısı, E2E şifreli oturum, dosya transferi ve katılımsız erişimi ücretsiz verir; istemcide VDS genel adresi kullanıldığında WireGuard çökse bile kanal ayakta kalır. MeshCentral Apache-2.0 ile ikinci bağımsız düzlemi sağlar. AnyDesk ücretsiz sürümü yalnızca kişisel kullanımı kapsar; 700 kurumsal cihaz ticari kullanımdır ve lisanssız kullanım ihlal olur (en az Advanced planı gerekirdi).
ALTERNATİF: AnyDesk (lisans maliyeti + kapalı kaynak + self-hosted yalnızca en üst planda → elendi; yalnızca müşteri sahasında zaten lisanslıysa opsiyonel installer modülü). Tailscale/ZeroTier (freemium, merkezi kimlik → elendi).
RİSK:     İki VDS-bağımlı kanalın tek ortak noktası VDS + genel internet; azaltma: hbbs/hbbr `--net=host` + health monitörü (Uptime Kuma) + yedek VDS planı 17-RECOVERY'de.
MALİYET:  Ücretsiz (kendi VDS'i üzerinde; VDS kira bedeli hariç — altyapı maliyeti, lisans değil).
LİSANS:   RustDesk istemci+sunucu AGPL-3.0 (1.4.9 / 1.1.16) — https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/ + https://rustdesk.com/docs/en/self-host/client-deployment/ (doğrulanma: 2026-09-15); MeshCentral Apache-2.0 (1.2.5) — https://github.com/Ylianst/MeshCentral (doğrulanma: 2026-09-15); AnyDesk hükmü — https://support.anydesk.com/docs/anydesk-licenses.md (doğrulanma: 2026-09-15) + https://anydesk.com/en/pricing.
```

### K-05 — WireGuard modeli

```text
KARAR:    Hub-spoke WireGuard: merkez sunucu hub, her saha cihazı spoke (peer adı = `bf-<8hane>`); istemcide `PersistentKeepalive = 25` + `wg-quick@wg0` systemd enable; RDP/SSH dış dünyaya kapalı, yalnızca WireGuard arkasında.
GEREKÇE:  Resmi QuickStart NAT arkasındaki eş için 25 sn keepalive'i "geniş güvenlik-duvarı yelpazesiyle çalışan makul aralık" olarak verir; `wg-quick@.service` Ubuntu paketinden gelir, enable = açılışta otomatik VPN. Elektrik kesintisi sonrası cihaz açılınca VPN kendiliğinden gelir.
ALTERNATİF: Keepalive kapalı / agresif 10 sn — kapalı NAT eşlemesini düşürür, agresif değer saha verisi olmadan yazılmaz; PİLOT-1 kopma sayacına göre ayarlanır.
RİSK:     Turkcell CGNAT davranışı resmi kaynaktan doğrulanamaz (operatör bilgisi); azaltma: PİLOT-1'de 7/24 kopma sayacı, aralık saha verisiyle ayarlanır.
MALİYET:  Ücretsiz.
LİSANS:   WireGuard OSS (Ubuntu paketi `wireguard-tools 1.0.20250521-1ubuntu1`) — https://www.wireguard.com/quickstart/ + https://packages.ubuntu.com/resolute/wireguard-tools (doğrulanma: 2026-09-15).
```

### K-06 — Filo yönetimi

```text
KARAR:    Birincil filo otomasyonu Ansible CLI (SSH, agent'sız); operatör arayüzü Semaphore UI Community (self-hosted, MIT). Hiçbir playbook Pro/Enterprise özelliğine bağlanmaz.
GEREKÇE:  En düşük hareketli parça (SSH + YAML + tek Go binary); 700 cihazda ek agent/master/K8s maliyeti yok. Community ücretsizliği resmi fiyat sayfasıyla kanıtlı ("$0, free forever"); Pro en fazla 500 managed node desteklediği için 700 cihazda ücretli yol zaten kapalı.
ALTERNATİF: AWX (K8s yükü + release'ler refactoring nedeniyle duraklatıldı → elendi); Salt (minion agent + master PKI → elendi); Rudder Community (relay/Enterprise modülleri + öğrenme eğrisi → elendi); MeshCentral (erişim aracı, filo otomasyonu değil → bu rolde elendi).
RİSK:     Semaphore tek nokta arızası → Ansible CLI bağımsız çalışır (UI çökse filo durmaz). Community'de OIDC/2FA/Vault yok → Semaphore yalnızca WireGuard arkasında, erişim VPN + SSH anahtarı ile; gizliler yerleşik şifreli Key Store'da.
MALİYET:  Ücretsiz (kendi VDS'i üzerinde).
LİSANS:   Ansible GPL-3.0 — https://github.com/ansible/ansible; Semaphore Community MIT — https://github.com/semaphoreui/semaphore + https://semaphoreui.com/pricing (doğrulanma: 2026-09-15).
```

### K-07 — Monitoring

```text
KARAR:    Birincil Prometheus + Node Exporter + Grafana OSS (17 metriğin tamamı); tamamlayıcı Uptime Kuma (saha-teknisyeni dostu UP/DOWN panosu + Push "last seen" + bildirimler). Netdata elendi.
GEREKÇE:  17 metriğin tamamı yalnızca Prometheus yığınında ücretsiz ve kotasız toplanır (WireGuard handshake, Docker, MEG sağlığı textfile collector ile). Netdata Cloud Free 5 node kotası 700 cihazda ücrete düşer. Uptime Kuma metrik vermez ama en basit çevrimdışı alarmını verir (20 sn aralık, 90+ bildirim servisi, tek konteyner).
ALTERNATİF: Yalnızca Uptime Kuma (metrik körlüğü → elendi); Netdata self-hosted Parent (merkezi tasarım yükü + kota riski → elendi).
RİSK:     700 node'da saklama/kardinalite; azaltma: scrape 60 sn, retention 30–90 gün, etiket şeması `BF-<no>` standardında, federasyon/fazlı rollout.
MALİYET:  Ücretsiz.
LİSANS:   Prometheus/Node Exporter Apache-2.0 — https://github.com/prometheus/prometheus + https://prometheus.io/docs/guides/node-exporter/; Grafana OSS AGPL-3.0 (değişikliksiz self-host) — https://grafana.com/oss/; Uptime Kuma MIT — https://github.com/louislam/uptime-kuma (doğrulanma: 2026-09-15).
```

### K-08 — Doküman platformu

```text
KARAR:    Docusaurus (`docs-site/` iskeleti; `docs/*.md` tek kaynak, site derlemesi CI'da).
GEREKÇE:  "AI-güncelleme" kriterini yalnızca Git-yerleşik Markdown çözer (ajan `.md`'yi doğrudan yazar, review PR'dan geçer). Wiki.js'nin DB+servis yükü sadelik kuralını bozar; TriliumNext tek-kullanıcı bilgi tabanıdır. MkDocs'a karşı Docusaurus: yerleşik sürümleme + yerleşik i18n + MDX; derleme maliyeti eşdeğerdir.
ALTERNATİF: MkDocs + Material (eşdeğer sadelikte güçlü ikinci; Docusaurus derleme hattı sorun çıkarırsa geçiş maliyeti düşük çünkü kaynak yine düz Markdown — yedekte tutulur). Wiki.js (DB yükü → elendi). TriliumNext (ekip akışı yok → elendi).
RİSK:     Node derleme hattı bozulabilir; azaltma: kilitli bağımlılıklar + CI derleme testi; derleme bozulsa bile `docs/*.md` ham haliyle okunur.
MALİYET:  Ücretsiz.
LİSANS:   Docusaurus MIT — https://github.com/facebook/docusaurus + https://docusaurus.io/docs/markdown-features/diagrams (doğrulanma: 2026-09-15).
```

### K-09 — Golden image yöntemi

```text
KARAR:    Golden image = Ubuntu Server 26.04.1+ minimal + `unattended-upgrades` kapalı + `blueforce-install.sh` tek kurucu (bayi no → READY); imaj, preseed/autoinstall dosyasıyla üretilir, cihaz-spesifik kimlik (`bf-<no>`) imajda DEĞİL ilk açılışta verilir.
GEREKÇE:  Donanım heterojenliği bilinmediği için bit-kopya klon (Clonezilla) tek imajda kırılgandır; autoinstall + idempotent kurulum scripti her donanım profilinde aynı zemini kurar, kimlik ilk boot'ta enjekte edilir. Hedef akış: USB → Ubuntu → tek script → bayi no → READY.
ALTERNATİF: Clonezilla bit-kopya (hızlı ama donanım-fragil → yedek yöntem olarak tutulur); Packer/custom ISO (ek derleme hattı yükü → elendi); cloud-init (autoinstall'a göre saha-USB akışına daha az uygun → elendi).
RİSK:     İlk imaj heterojen donanımda sürücü eksiltebilir; azaltma: önce `bf-hardware-inventory.sh` taraması (18-ROLLOUT), LAB'da her profilde test.
MALİYET:  Ücretsiz.
LİSANS:   Ubuntu autoinstall/subiquity (ücretsiz, Ubuntu lisans seti içinde) — https://releases.ubuntu.com/26.04/ (doğrulanma: 2026-09-15). NOT: Faz 1'de resmi autoinstall sözdizimi ayrıca doğrulanmadı; kesin direktifler 04-GOLDEN-IMAGE'da LAB çıktısıyla yazılır.
```

### K-10 — Docker restart politikası ve imaj disiplini

```text
KARAR:    Tüm saha konteynerlerinde restart politikası `unless-stopped`; `latest` etiketi yasak (sabit tag zorunlu); Watchtower yok; log rotasyonu (`max-size`/`max-file`) daemon.json'da zorunlu; yayımlanan portlar `127.0.0.1`'e bağlanır (UFW bypass'a karşı).
GEREKÇE:  `unless-stopped`, `always`'in aksine teknisyenin bakım için durdurduğu konteyneri reboot sonrası sürpriz kalkıştan korur; elektrik kesintisi kurtarması aynen çalışır (kesinti "manuel stop" sayılmaz). Hareketli `latest` etiketi 700 cihazda determinizmi bozar ("onaysız update yasak" politikası). Watchtower hem politikayı ihlal eder (otomatik updater) hem upstream'de arşivlenmiştir. Docker varsayılan `json-file` logu rotasyon yapmaz → dolan disk = kilitlenen cihaz. Docker yayımlanan portlarda UFW'yi baypas eder (resmi belgeli) → localhost-bind + WireGuard üzerinden erişim.
ALTERNATİF: `always` (öngörülemez bakım davranışı → elendi); `iptables:false` (resmi doküman "çoğu kullanıcı için uygun değil" diye uyarır → varsayılan çözüm değil); digest pinleme (`@sha256`) PİLOT-2'de değerlendirilecek ek sıkılık adımı.
RİSK:     `max-size/max-file` değerleri MEG log hacmine göre ayarlanmazsa ya disk dolar ya log kaybolur; azaltma: PİLOT'ta hacim ölçülür, 12-DOCKER'da sabitlenir.
MALİYET:  Ücretsiz (Docker CE).
LİSANS:   Docker CE ücretsiz (Business/Scout mimaride yok) — https://docs.docker.com/engine/containers/start-containers-automatically/ + https://docs.docker.com/engine/logging/configure/ + https://docs.docker.com/engine/network/packet-filtering-firewalls/ (doğrulanma: 2026-09-15); Watchtower arşiv durumu — https://github.com/containrrr/watchtower (doğrulanma: 2026-09-15).
```

### K-11 — Otomatik güncelleme yasağı

```text
KARAR:    Golden image'da `unattended-upgrades` kapatılır (`/etc/apt/apt.conf.d/20auto-upgrades` değerleri `0` + `apt-daily*.timer` maskeleme); tüm güncellemeler LAB→PİLOT→WAVE→PROD onay zincirinden geçer (dalgalar: LAB(2)/P1(5)/P2(20)/W1(50)/W2(100)/PROD).
GEREKÇE:  `unattended-upgrades` Ubuntu Server'da varsayılan kurulu ve etkindir, günde bir kez çalışır; kapatılmazsa 700 cihaz ilk açılışta güncellemeye kalkar ("onaysız update yasak" ilkesi delinir). Kaçan timer makine açılışında hemen tetiklenir (`Persistent=true` davranışı) — saha PC'leri sık kapanan makinelerdir.
ALTERNATİF: Otomatik security update'e izin verme — 700 cihazda eşzamanlı indirme + onaysız değişim riski nedeniyle elendi; security update'ler öncelik işaretli onaylı dalga ile çıkar.
RİSK:     Kapatma adımı imajda atlanırsa filo kendiliğinden güncellenir; azaltma: `blueforce-install.sh` final-check + monitoring'de `Unattended-Upgrade` durumu metriği.
MALİYET:  Ücretsiz.
LİSANS:   Yok (işletim sistemi yapılandırması) — https://ubuntu.com/server/docs/how-to/software/automatic-updates/ + https://manpages.ubuntu.com/manpages/resolute/en/man8/unattended-upgrade.8.html (doğrulanma: 2026-09-15).
```

### K-12 — Cihaz kimliği standardı

```text
KARAR:    8 haneli bayi no → Device ID `BF-<no>` (büyük), hostname `bf-<no>` (küçük); WireGuard peer adı, RustDesk etiketi, Ansible inventory adı, monitoring etiketi hepsi aynı ID'yi kullanır. Örnek: `BF-12010193` / `bf-12010193`.
GEREKÇE:  Tek kimlik = 9 sistemde (DNS/hostname, WireGuard, RustDesk, MeshCentral, Ansible, Prometheus, log, envanter, runbook) join anahtarı; büyük/küçük ayrımı insan-makine karışıklığını önler (insan `BF-`, makine `bf-`).
ALTERNATİF: Rastgele UUID / MAC-tabanlı ad — saha teknisyeni için okunamaz, bayi eşleşmesi manuel olur → elendi.
RİSK:     Bayi no değişirse kimlik çakışması; azaltma: 02-NAMING'de yeniden-no prosedürü + envanter benzersizlik kontrolü.
MALİYET:  Ücretsiz.
LİSANS:   Yok (isimlendirme standardı).
```

### K-13 — SSH kimlik doğrulama mimarisi

```text
KARAR:    `blueforce` bakım kullanıcısı + anahtar zorunlu (password SSH kapalı, root SSH kapalı); 700 cihaza tek private key YAYILMAZ — admin başına anahtar + cihazlarda `authorized_keys` merkezi dağıtımı (Ansible), uzun vadede SSH CA hedefi.
GEREKÇE:  Tek private key'in sızıntı blast-radius'u 700 cihazdır; per-admin anahtar + merkezi dağıtım sızıntıyı tek anahtarın iptaline indirger. Servisler ayrı system user ile çalışır, sudo kontrollüdür.
ALTERNATİF: Tek paylaşılan private key (basit ama 700 cihazlık blast-radius → elendi); password auth (kaba-kuvvet yüzeyi → elendi).
RİSK:     Anahtar dağıtım gecikmesi yeni cihazda erişimsizlik; azaltma: golden image'da bootstrap anahtarı + ilk Ansible run'ında rotasyon.
MALİYET:  Ücretsiz.
LİSANS:   OpenSSH (BSD-lisanslı), ücretsiz.
```

### K-14 — Log ve sağlık disiplini

```text
KARAR:    Birincil metrik/monitoring K-07; log tarafında journald + Docker `json-file` rotasyonlu + textfile `.prom` (WireGuard handshake, Docker, MEG) + `bf-status` / `bf-diagnostics` / `bf-support-bundle` (secret sızdırmaz) sözleşmeleri.
GEREKÇE:  700 dokunulmaz cihazda logsuz metrik kör, metriksiz log sağırdır; textfile collector özel metriklerin (WireGuard/MEG) standart Prometheus yoludur. Support-bundle secret dışlama kuralıyla güvenli uzaktan tanı sağlar.
ALTERNATİF: Harici log platformu (Loki/ELK) ilk fazda — ek servis yükü, sadelik kuralını bozar → Faz-sonrası hedef olarak 15-LOGGING'e not edilir.
RİSK:     Log hacmi retention'ı şişirir; azaltma: PİLOT'ta hacim ölçümü + limitler 15-LOGGING'de.
MALİYET:  Ücretsiz.
LİSANS:   systemd-journald / Node Exporter textfile (Apache-2.0) — https://github.com/prometheus/node_exporter (doğrulanma: 2026-09-15).
```

---

## 4. Neden Bu Karar?

Tüm kararlarda aynı üç filtre uygulandı: (1) %100 ücretsiz/self-hosted — resmi URL + sürüm + tarih olmadan lisans iddiası yazılmadı; (2) sadelik — Kubernetes, microservice, gereksiz agent/DB/cloud önerisi reddedildi (AWX'in K8s zorunluluğu, Salt master PKI, Wiki.js DB yükü, harici log platformu); (3) onaysız update yasağı — unattended-upgrades, `latest`, Watchtower aynı ilkeden elendi. 700 ölçeğinde her "küçük varsayılan" (günlük otomatik update, rotasyonsuz log, UFW bypass) filo-çapı arızaya dönüşür; kararlar bu çarpanı küçültür.

## 5. Alternatifler

| Alternatif | Artı | Eksi | Sonuç |
|---|---|---|---|
| Ubuntu 24.04 LTS | Olgun donanım desteği | 26.04 doğrulandı, daha kısa destek penceresi | Yedek |
| XFCE | Hafif, düşük kaynak | Kullanıcı kararıyla elendi (saha standardı GNOME) | Elendi |
| AnyDesk | Tanınmış, kolay | Ticari lisans zorunlu (700 cihaz), kapalı kaynak | Elendi |
| Tailscale/ZeroTier | Kolay mesh | Freemium, merkezi kimlik | Elendi |
| AWX | Güçlü UI | K8s zorunlu, release'ler duraklatıldı | Elendi |
| Salt / Rudder | Ölçeklenir | Agent+master/relay yükü, öğrenme eğrisi | Elendi |
| Netdata Cloud | Zengin agent | Free 5 node kotası, 700 cihaz ücretli | Elendi |
| Yalnızca Uptime Kuma | Çok kolay | Metrik körlüğü | Elendi |
| Wiki.js | Güçlü editör | DB+servis yükü, Git akışı dolaylı | Elendi |
| MkDocs + Material | Eşdeğer sade | Sürümleme/i18n eklentiyle | Yedek (güçlü ikinci) |
| TriliumNext | Hafif | Tek kullanıcı, ekip akışı yok | Elendi |
| Clonezilla bit-kopya | Hızlı klon | Donanım-fragil | Yedek yöntem |
| Docker `always` | Her koşulda ayakta | Bakım-stop'u reboot'ta deler | Elendi |
| Watchtower | Otomatik imaj | Politika ihlali + arşivlenmiş upstream | Elendi |
| Tek paylaşılan SSH key | Basit | 700 cihazlık blast-radius | Elendi |

## 6. Avantajlar

- 14 kararın tamamı ücretsiz katmanda kanıtlı; zorunlu mimaride lisans bedeli yok.
- Her kararın resmi kaynak URL'si + sürümü + doğrulama tarihi var; varsayıma dayalı karar yok (belirsizler LAB/PİLOT'a havale edildi).
- 4 erişim kanalından ikisi WireGuard-bağımsız; tek tünel arızası filoyu kör etmez.

## 7. Dezavantajlar

- K-09 (golden image) Faz 1'de tam resmi-doğrulamalı değil; autoinstall sözdizimi LAB çıktısına bağımlı.
- Semaphore Community'de OIDC/2FA/Vault yokluğu operasyonel disiplinle (VPN-arkası + Key Store) kapatılıyor; bu disiplin bozulursa güvenlik açığı doğar.
- Prometheus 700 node işletme bilgisi ister; retention/kardinalite LAB'da ölçülmeden donanım siparişi verilmemeli.

## 8. Riskler

| Risk | Olasılık | Etki | Azaltma |
|---|---|---|---|
| `unattended-upgrades` imajda açık unutulur | Orta | Yüksek (filo kendiliğinden güncellenir) | install.sh final-check + monitoring metriği (K-11) |
| Docker UFW bypass ile MEG portu dışa açılır | Orta | Yüksek | localhost-bind standardı + 11-HARDENING denetimi (K-10) |
| Semaphore çöker, filo yönetimsiz kalır | Düşük | Orta | Ansible CLI bağımsız çalışır (K-06) |
| 26.04.x sürücü farkı heterojen donanımda | Orta | Orta | LAB'da profil başına imaj testi (K-01/K-09) |
| Tek VDS iki bağımsız kanalı da barındırırsa ortak arıza | Düşük | Yüksek | hbbs/hbbr + MeshCentral ayrı VDS veya yedek planı (K-04) |
| 700 node Prometheus kardinalite patlaması | Orta | Orta | 60 sn scrape, 30–90 gün retention, `BF-<no>` etiket şeması (K-07) |

## 9. Uygulama Planı

1. Golden image'a K-01/K-02/K-03/K-10/K-11 uygulanır (04-GOLDEN-IMAGE).
2. WireGuard hub + ilk peer'lar K-05'e göre kurulur (08-WIREGUARD).
3. hbbs/hbbr + MeshCentral VDS'leri K-04'e göre ayağa kaldırılır (07-REMOTE-ACCESS).
4. Ansible + Semaphore K-06'ya göre kurulur; ilk playbook LAB(2)'de koşar (09-FLEET).
5. Prometheus + Uptime Kuma K-07'ye göre kurulur; 17 metrik LAB'da doğrulanır (14-MONITORING).
6. Update zinciri K-11 dalgalarıyla işletilir (10-UPDATE).

```bash
# örnek: cihaz kimliği standardı (K-12)
hostnamectl set-hostname bf-12010193
```

## 10. Test Planı

| Test | Beklenen sonuç | Ortam |
|---|---|---|
| `20auto-upgrades` değerleri `0`, timer'lar maskeli | Otomatik apt çalışmaz | LAB(2) imaj denetimi |
| `bf-gui-on/off` sonrası RDP oturumu | GNOME oturumu açılır/kapanır | LAB(2) |
| WireGuard down iken RustDesk oturumu | Bağlantı kurulur (bağımsız kanal) | P1(5) |
| `docker inspect` restart politikası | `unless-stopped` tüm saha konteynerlerinde | LAB(2) |
| Semaphore kapalı iken Ansible CLI run | Playbook başarıyla koşar | LAB(2) |
| Scrape + 17 metrik + Uptime Push | Grafana + Kuma panoları dolu | P1(5) |

## 11. Rollback

1. Yanlış karar tespitinde bu dosya PR ile düzeltilir; bağımlı dokümanlar (01, 03, 07, 08, 09, 12, 14) aynı PR'da güncellenir.
2. İmaj-kritik karar (K-01/K-11) geri alınırsa golden image yeniden üretilir, sahaya sürülmüş dalga 10-UPDATE rollback zinciriyle geri alınır.
3. Son çare: karar öncesi imaj sürümüne dönüş (17-RECOVERY LEVEL 9).

## 12. Kontrol Listesi

- [ ] 14 kararın her birinde KARAR/GEREKÇE/ALTERNATİF/RİSK/MALİYET/LİSANS + kaynak URL var.
- [ ] Ücretli hiçbir araç zorunlu mimaride değil; AnyDesk hükmü resmi URL'li.
- [ ] `unattended-upgrades`, `latest`, Watchtower yasakları üç dosyada da tutarlı (03/10/12).
- [ ] Ek B'deki 27 sorunun her biri ≥1 karara bağlı (boş hücre yok).

## 13. Açık Sorular

- [ ] GNOME oturum başlatma satırı + `bf-gui-*` kesin birim listesi — LAB 26.04.1 imajında (sahibi: Faz 3, 03/04 yazarları).
- [ ] MEG log hacmine göre `max-size/max-file` kesin değerleri — PİLOT ölçümü (sahibi: 12-DOCKER yazarı).
- [ ] Turkcell NAT kopma sayacı + keepalive ayarı — P1 7/24 sayaç (sahibi: 08-WIREGUARD yazarı).
- [ ] Digest pinleme (`@sha256`) kararı — PİLOT-2 değerlendirmesi (sahibi: 12-DOCKER yazarı).
- [ ] Prometheus retention/kardinalite hesabı (700 × 60 sn) — LAB ölçümü (sahibi: 14-MONITORING yazarı).
- [ ] Semaphore Global Runner sayısı + eşzamanlılık — 700 node yük testi (sahibi: 09-FLEET yazarı).

---

## Ek A: Kaynak Tablosu (URL + sürüm + tarih)

| # | Kaynak | Sürüm/tarih |
|---|---|---|
| 1 | https://releases.ubuntu.com/ | 26.04.1 LTS Resolute Raccoon, 2026-09-15 |
| 2 | https://releases.ubuntu.com/26.04/ | Server GUI kurmaz notu, 2026-09-15 |
| 3 | https://ubuntu.com/download/desktop | 2 GHz / 6 GB / 25 GB, 2026-09-15 |
| 4 | https://ubuntu.com/server/docs/how-to/software/automatic-updates/ | güncel Server docs, 2026-09-15 |
| 5 | https://manpages.ubuntu.com/manpages/resolute/en/man8/unattended-upgrade.8.html | 2.12ubuntu9, 2026-09-15 |
| 6 | https://www.gnome.org/ | Desktop standardı beyanı, 2026-09-15 |
| 7 | https://github.com/neutrinolabs/xrdp | v0.10.6.1 (2026-07-07), 2026-09-15 |
| 8 | https://www.wireguard.com/quickstart/ | keepalive 25 sn, 2026-09-15 |
| 9 | https://packages.ubuntu.com/resolute/wireguard-tools | 1.0.20250521-1ubuntu1, 2026-09-15 |
| 10 | https://docs.docker.com/engine/network/packet-filtering-firewalls/ | UFW bypass, 2026-09-15 |
| 11 | https://docs.docker.com/engine/logging/configure/ | log rotasyon, 2026-09-15 |
| 12 | https://docs.docker.com/engine/containers/start-containers-automatically/ | unless-stopped, 2026-09-15 |
| 13 | https://github.com/containrrr/watchtower | arşivli, 2026-09-15 |
| 14 | https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/ | mimari hbbs/hbbr, 2026-09-15 |
| 15 | https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/ | compose + portlar, 2026-09-15 |
| 16 | https://rustdesk.com/docs/en/self-host/client-deployment/ | OSS toplu dağıtım, 2026-09-15 |
| 17 | https://rustdesk.com/pricing/ | Individual ~11,88 / Basic ~23,88 USD/ay, 2026-09-15 |
| 18 | https://support.anydesk.com/docs/anydesk-licenses.md | ticari lisans şartı (güncelleme 2025-10-30), 2026-09-15 |
| 19 | https://anydesk.com/en/pricing | Solo/Standard/Advanced/Ultimate, 2026-09-15 |
| 20 | https://github.com/Ylianst/MeshCentral | 1.2.5 (2026-08-12), Apache-2.0, 2026-09-15 |
| 21 | https://github.com/ansible/ansible | GPL-3.0, 2026-09-15 |
| 22 | https://github.com/semaphoreui/semaphore + https://semaphoreui.com/pricing | MIT, Community $0, 2026-09-15 |
| 23 | https://github.com/prometheus/prometheus + https://prometheus.io/docs/guides/node-exporter/ | Apache-2.0, 2026-09-15 |
| 24 | https://grafana.com/oss/ | AGPL-3.0 OSS, 2026-09-15 |
| 25 | https://github.com/louislam/uptime-kuma | MIT, 2026-09-15 |
| 26 | https://github.com/facebook/docusaurus + https://docusaurus.io/docs/markdown-features/diagrams | MIT, 2026-09-15 |
| 27 | https://github.com/prometheus/node_exporter | textfile collector, 2026-09-15 |

---

## Ek B: 27 Soru → Karar İzlenebilirliği

> NOT: `SUMMARY.md` Faz 4'te üretilecek; aşağıdaki S-01…S-27 listesi şartname + plandaki 27 kritik sorunun Faz 2 karşılığıdır. SUMMARY yazıldığında her cevap buradaki karara linklenecek.

| # | Soru | Karar | Doküman |
|---|---|---|---|
| S-01 | Hangi Ubuntu sürümü? | K-01 (Server 26.04.1+ LTS) | 03-UBUNTU-BASELINE |
| S-02 | Server mı Desktop mı? | K-01 (Server, GUI'siz kurulum) | 03 |
| S-03 | GNOME mu XFCE mi? | K-02 (GNOME; XFCE elendi) | 03, 07 |
| S-04 | Boot terminale mi grafiğe mi? | K-03 (terminal + bf-gui-on/off) | 03, 16 |
| S-05 | SSH nasıl (kullanıcı, auth, root)? | K-13 (key zorunlu, root kapalı) | 06 |
| S-06 | 700 cihazda tek key riski nasıl çözülür? | K-13 (per-admin key + CA hedefi) | 06 |
| S-07 | RDP hangi sunucu/masaüstü ile? | K-03 (xRDP + GNOME) | 07 |
| S-08 | RustDesk OSS neyi kapsar, Pro gerekir mi? | K-04 (OSS yeterli, Pro yok) | 07 |
| S-09 | WireGuard çökerse uzak erişim sürer mi? | K-04 (RustDesk/MeshCentral bağımsız) | 07, 08 |
| S-10 | 4. erişim kanalı hangisi? | K-04 (MeshCentral) | 07 |
| S-11 | AnyDesk ücretsiz kullanılabilir mi? | K-04 (HAYIR — mimariden çıkarıldı) | 07, 23 |
| S-12 | WireGuard modeli + keepalive + otomatik reconnect? | K-05 (hub-spoke, 25 sn, wg-quick enable) | 08 |
| S-13 | RDP/SSH dış dünyaya açık mı? | K-05 (hayır — WireGuard arkası) | 08, 11 |
| S-14 | Filo yönetimi hangi araç? | K-06 (Ansible + Semaphore Community) | 09 |
| S-15 | Semaphore Pro gerekir mi? | K-06 (hayır — kanıtlı) | 09, 23 |
| S-16 | Monitoring hangi yığın, 17 metrik nasıl? | K-07 (Prometheus + Kuma) | 14 |
| S-17 | Çevrimdışı/last-seen nasıl izlenir? | K-07 (`up` + Push monitör) | 14 |
| S-18 | Onaysız update politikası nedir? | K-11 (yasak + dalgalı onay zinciri) | 10 |
| S-19 | `unattended-upgrades` ne olacak? | K-11 (imajda kapalı) | 03, 10 |
| S-20 | Update dalgaları neler? | K-11 (LAB(2)/P1(5)/P2(20)/W1(50)/W2(100)/PROD) | 10, 18 |
| S-21 | Docker restart politikası ne? | K-10 (`unless-stopped`) | 12 |
| S-22 | `latest` / Watchtower serbest mi? | K-10 (ikisi de yasak) | 12 |
| S-23 | Docker + UFW çakışması nasıl çözülür? | K-10 (localhost-bind) | 11, 12 |
| S-24 | Log disiplini nedir? | K-10 + K-14 (rotasyon + textfile + bundle) | 12, 15 |
| S-25 | Golden image yöntemi ne? | K-09 (autoinstall + install.sh) | 04, 05 |
| S-26 | Cihaz kimliği standardı ne? | K-12 (`BF-<no>` / `bf-<no>`) | 02 |
| S-27 | Doküman platformu hangisi? | K-08 (Docusaurus) | 22 |

---

## Ek: Karar Haritası (hangi soru hangi karara?)

```mermaid
flowchart LR
    SORU["27 soru (Ek B)<br/>S-01…S-27"] --> ZEMIN["Zemin: K-01/K-02/K-03<br/>K-09/K-10/K-11/K-12"]
    SORU --> AG["Ağ + erişim: K-04/K-05/K-13"]
    SORU --> OPS["Operasyon: K-06/K-07/K-14"]
    SORU --> DOC["Docs: K-08"]
    ZEMIN --> D1["03/04/05/10/12/02"]
    AG --> D2["07/08/06/11"]
    OPS --> D3["09/14/15"]
    DOC --> D4["22"]
```
