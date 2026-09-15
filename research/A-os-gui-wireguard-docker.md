# Faz 1A Araştırma — OS / GUI / RDP + WireGuard + Docker

> Durum: KAYNAK DOĞRULAMA NOTU (karar taslağı değil). Her bulgu `iddia + resmi URL + sürüm/tarih + Blueforce etkisi` formatındadır.
> Doğrulama yöntemi: resmi sayfalar 2026-09-15 tarihinde doğrudan çekilerek (HTTP 200) okundu. Web arama servisi (Nous gateway) kapalıydı; bu dosyadaki hiçbir bulgu arama özetine dayanmaz, hepsi doğrudan sayfa içeriğidir.
> Kural: tüm bileşenlerde FREE sürüm baz alınır (Ubuntu LTS, WireGuard, Docker CE, XFCE, xRDP). Ücretli varyantlar (Ubuntu Pro, Docker Business vb.) zorunlu mimariye konulmaz; free limitleri ilgili maddede kısaca not edilir.

---

## A1. Ubuntu 26.04 LTS var mı? Saha için uygun mu?

- **BULGU A1.1 — Ubuntu 26.04.1 LTS mevcut ve resmi indirme sayfasında yayında.**
  - İddia: `releases.ubuntu.com` ana sayfası "Ubuntu 26.04.1 LTS (Resolute Raccoon)" başlığını, `26.04/` ve `26.04.1/` dizinlerini listeler.
  - Resmi URL: https://releases.ubuntu.com/ (HTTP 200, çekilme: 2026-09-15)
  - Sürüm/tarih: 26.04.1 LTS, kod adı Resolute Raccoon
  - Blueforce etkisi: Şartnamedeki "Ubuntu LTS (26.04 doğrulanacak)" maddesi DOĞRULANDI — 26.04 gerçek, güncel LTS serisidir. Ancak `.1` sürümünün yayında olması, golden image için **26.04.1+ noktasürümü** baz almayı önerir (ilk .0 dalgasındaki kurulumcu hataları genelde .1'de toplanır — bu kısım genel mühendislik kanaati, LAB'da imaj testiyle kesinleşir).

- **BULGU A1.2 — 26.04 Server ISO'su varsayılan olarak GUI kurmaz.**
  - İddia: `26.04/` dizin sayfası Server imajını "It will not install a graphical user interface" cümlesiyle tanımlar; Desktop ve live-server ISO'ları ayrıdır.
  - Resmi URL: https://releases.ubuntu.com/26.04/ (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: "Server + sonradan XFCE" saha mimarisi temiz bir zemine oturur — minimal kurulum + ihtiyaca göre GUI, desteklenen standart yoldur.

- **BULGU A1.3 — Ubuntu Desktop 26.04 sistem gereksinimi saha PC'leri için ağırdır.**
  - İddia: Resmi indirme sayfası Desktop için "2 GHz dual-core, 6 GB RAM, 25 GB disk" ister.
  - Resmi URL: https://ubuntu.com/download/desktop (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: 700 saha PC'sinde tam GNOME/Ubuntu Desktop standardı RAM/disk bütçesini zorlar. Bu, XFCE tercihinin en somut dayanağıdır (bkz. A2).

- **BULGU A1.4 — `unattended-upgrades` Ubuntu Server'da VARSAYILAN OLARAK KURULU ve ETKİNDİR; günde bir kez çalışır.**
  - İddia: Resmi Server dokümantasyonu: "This is done via the `unattended-upgrades` package, which is installed by default" + "Right after installation, automatic installation of security updates will be enabled" + "By default, `unattended-upgrades` runs once per day". Kapatma yolu: `/etc/apt/apt.conf.d/20auto-upgrades` içinde `Update-Package-Lists` / `Unattended-Upgrade` değerlerini `0` yapmak; tetikleyici systemd timer'ları `apt-daily.timer` / `apt-daily-upgrade.timer`.
  - Resmi URL: https://ubuntu.com/server/docs/how-to/software/automatic-updates/ (HTTP 200, render; kaynak: https://raw.githubusercontent.com/canonical/ubuntu-server-documentation/main/docs/how-to/software/automatic-updates.md, HTTP 200, çekilme: 2026-09-15)
  - Sürüm/tarih: güncel Server dokümantasyonu (resolute dahil); man sayfası resolute'ta `unattended-upgrades 2.12ubuntu9` paketini doğrular — https://manpages.ubuntu.com/manpages/resolute/en/man8/unattended-upgrade.8.html (HTTP 200, 2026-09-15); noble paketi https://packages.ubuntu.com/noble/unattended-upgrades (HTTP 200)
  - Blueforce etkisi: KRİTİK — "onaysız update yasak" politikası için golden image'da `20auto-upgrades`'ın `0`'lanması ve timer'ların maskelenmesi ŞART; aksi halde 700 cihaz ilk açılışta güncellemeye kalkar (doküman ayrıca makine kapalıyken kaçan timer'ın açılışta hemen tetiklendiğini — `Persistent=true` davranışı — yazar; saha PC'leri sık kapanan makineler olduğu için bu not runbook'a girer). Free notu: ESM kapsamı Pro'ya girer — mimaride ESM'e bel bağlanmaz, standart `security` cebi yeterlidir (ücretsiz).

---

## A2. Masaüstü: XFCE vs GNOME + xRDP (700 ölçek)

- **BULGU A2.1 — Xfce resmi olarak "hafif, hızlı, düşük sistem kaynağı" hedefler.**
  - İddia: Proje ana sayfası: "Xfce is a lightweight desktop environment… It aims to be fast and low on system resources."
  - Resmi URL: https://www.xfce.org/about (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: GNOME (6 GB RAM şartı, A1.3) karşısında XFCE'nin saha standardı olması yönünde karar verilir. RDP üzerinden 700 cihaza bakımda düşük RAM/CPU ayak izi = daha az donma, daha ucuz saha donanımı.

- **BULGU A2.2 — xRDP aktif, güncel, ücretsiz (Apache-2.0) RDP sunucusudur; Temmuz 2026 sürümü var.**
  - İddia: GitHub `neutrinolabs/xrdp`: açıklama "xrdp: an open source RDP server", son push 2026-09-09, son sürüm v0.10.6.1 (2026-07-07), ~6728 yıldız, varsayılan dal `devel`.
  - Resmi URL'ler: https://github.com/neutrinolabs/xrdp + https://api.github.com/repos/neutrinolabs/xrdp (+ `/releases/latest`) (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: xRDP "ölü proje" riski YOK — 4. erişim yöntemi adayı olarak mimaride kalır. Lisans ücretsiz, 700 ölçekte lisans maliyeti doğmaz.

- **BULGU A2.3 — xRDP mimarisi oturum yöneticisi (sesman) + servis birimleri üzerine kuruludur; GUI aç/kapa buradan türetilir.**
  - İddia: Upstream README kaynak ağacı `sesman` (session manager), `xrdp-sesman.service.in` ve `xrdp.service.in` systemd birimlerini içerir (devel dalı `instfiles/` listesi ve README'den doğrulandı).
  - Resmi URL: https://github.com/neutrinolabs/xrdp (README + `instfiles/`, `sesman/` dizinleri; GitHub API HTTP 200, 2026-09-15)
  - Blueforce etkisi: `bf-gui-on/off` tasarımının dayanağı: GUI, display-manager servisi + xRDP servisleri (`xrdp`, `xrdp-sesman`) üzerinden systemd ile açılıp kapatılabilir bir katman olarak modellenir (kesin birim adları ve XFCE oturum başlatma satırı LAB'da 26.04.1 imajında doğrulanacak — bu dosyada komut uydurulmaz).

- **DOĞRULANAMAYAN / LAB'A BIRAKILAN:** xRDP GitHub wiki'si JS ile yükleniyor, statik çekmede oturum-masaüstü uyumluluk tablosu okunamadı (https://github.com/neutrinolabs/xrdp/wiki, 2026-09-15). GNOME-üzerinde-xRDP'nin bilinen ek ayar ihtiyacı bu kaynaktan teyit EDİLEMEDİ → "XFCE birincil, GNOME denenmeyecek" kararı A1.3+A2.1'e dayanır; GNOME+xRDP kombinasyonu LAB gündemine "test edilmeyecek alternatif" olarak değil, "XFCE yetersiz kalırsa" yedeği olarak yazılır.

---

## A3. WireGuard otomatik reconnect (Turkcell NAT arkası saha)

- **BULGU A3.1 — NAT arkasındaki eşin erişilebilir kalmasının resmi mekanizması PersistentKeepalive'dır; önerilen değer 25 sn.**
  - İddia: Resmi QuickStart "NAT and Firewall Traversal Persistence" bölümü: NAT/güvenlik duvarı arkasındaki eşin bağlantı eşlemesini canlı tutmak için periyodik keepalive göndermesi gerekir; "A sensible interval that works with a wide variety of firewalls is 25 seconds"; `0` = kapalı (varsayılan); ayar `PersistentKeepalive =` alanı veya `persistent-keepalive` komut satırı ile yapılır; çoğu kullanıcının ihtiyacı yoktur, protokolü biraz daha geveze yapar.
  - Resmi URL: https://www.wireguard.com/quickstart/ (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: Saha PC'leri (mobil NAT arkası) için istemci konfigürasyonunda `PersistentKeepalive = 25` STANDART olur. Sunucu tarafında keepalive gerekmez (simetrik değil — istemci canlı tutar).

- **BULGU A3.2 — `wg-quick@.service` systemd birimi Ubuntu paketinin içinden gelir; enable = açılışta otomatik VPN.**
  - İddia: `wireguard-tools` (noble/amd64) dosya listesi `/lib/systemd/system/wg-quick@.service` ve `wg-quick.target` içerir → `systemctl enable wg-quick@wg0` kalıcı açılır; resolute (26.04) paket sürümü `1.0.20250521-1ubuntu1`.
  - Resmi URL'ler: https://packages.ubuntu.com/noble/amd64/wireguard-tools/filelist ve https://packages.ubuntu.com/resolute/wireguard-tools (HTTP 200, 2026-09-15)
  - Blueforce etkisi: "Otomatik reconnect" iki katmandan kurulur: (1) WireGuard keepalive (A3.1) + (2) systemd `wg-quick@wg0` enable + restart. Elektrik kesintisi sonrası cihaz açılınca VPN kendiliğinden gelir — 16-POWER-LOSS dokümanının ağı ayağı hazır.

- **DOĞRULANAMAYAN / SAHADA ÖLÇÜLECEK:** "Turkcell CGNAT" özelliği resmi dokümandan doğrulanamaz (operatör bilgisi). Tasarım, operatörden bağımsız NAT-traversal'a (A3.1) dayanır; PİLOT-1'de her cihazda `PersistentKeepalive=25` ile 7/24 kopma sayacı tutulur, keepalive aralığı saha verisine göre ayarlanır. Tahminle 10 sn gibi agresif değer yazılmaz.

---

## A4. Docker (CE, ücretsiz): UFW bypass + log + restart + latest + Watchtower

- **BULGU A4.1 — Docker, yayımlanan portlarda UFW'yi BAYPAS eder; bu resmi olarak belgelenmiştir.**
  - İddia: Resmi doküman "Docker and ufw": Docker ve UFW uyumsuz çalışır; konteyner portu yayımlanınca trafik `nat` tablosunda yönlendirilir, UFW'nin kullandığı INPUT/OUTPUT zincirlerine uğramadan geçer — "effectively ignoring your firewall configuration".
  - Resmi URL: https://docs.docker.com/engine/network/packet-filtering-firewalls/ (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: KRİTİK — MEG ve yardımcı servisler `ports:` ile yayımlanırsa UFW kuralları delinir. Güvenli çözüm seçenekleri (dokümanın aynı sayfasından): (a) port yayımlamayı 127.0.0.1'e bağlamak, (b) `iptables:false` (doküman "çoğu kullanıcı için uygun değil, konteyner ağını bozabilir" diye uyarır — bu yüzden varsayılan çözüm DEĞİL), (c) Docker'ın `DOCKER-USER`/nftables belgeli zincirleri. Saha standardı: (a) + WireGuard üzerinden erişim; detay `12-DOCKER-OPERATIONS` ve `11-SECURITY-HARDENING`'de.

- **BULGU A4.2 — Varsayılan `json-file` log sürücüsü ROTASYON YAPMAZ; disk dolmasına yol açar. Çözüm `max-size`/`max-file` daemon ayarıdır.**
  - İddia: Resmi doküman: "By default, no log-rotation is performed… which can lead to disk space exhaustion"; örnek daemon ayarı `{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }`; `max-file` gibi sayısal değerler string yazılır; ayar değişikliği sonrası Docker restart gerekir ve sadece yeni konteynerlere uygulanır.
  - Resmi URL: https://docs.docker.com/engine/logging/configure/ (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: Golden image'daki `/etc/docker/daemon.json`'da log rotasyonu ZORUNLU standart olur (saha PC'leri aylarca dokunulmaz; dolan disk = kilitlenen cihaz). Değerler (10m/3) başlangıç önerisi; MEG log hacmi PİLOT'ta ölçülüp ayarlanır.

- **BULGU A4.3 — Saha standardı restart politikası `unless-stopped`'tur.**
  - İddia: Resmi doküman: `unless-stopped` "`always`'e benzer, ancak konteyner durdurulmuşsa (manuel ya da başka şekilde) Docker daemon yeniden başlasa bile yeniden başlatılmaz". Politika ancak konteyner en az bir kez başarıyla başladıktan sonra devreye girer.
  - Resmi URL: https://docs.docker.com/engine/containers/start-containers-automatically/ (HTTP 200, çekilme: 2026-09-15)
  - Blueforce etkisi: `always` yerine `unless-stopped` seçilir — saha teknisyeni bakım için durdurduğu konteynerin reboot sonrası sürpriz şekilde kalkmaması gerekir (öngörülebilirlik > her koşulda ayakta tutma). Elektrik kesintisi kurtarması `unless-stopped` ile aynen çalışır (kesinti "manuel stop" sayılmaz).

- **BULGU A4.4 — `latest` etiketi yasaklanır (determinizm gerekçesi).**
  - İddia: Docker Hub etiket-semantiği sayfası taşınmış, resmi cümle bu turda yakalanamadı (https://docs.docker.com/docker-hub/repos/manage/hub-images/ HTTP 200 ama `latest` geçmiyor, 2026-09-15). Bu yüzden yasak, resmi alıntıya değil Blueforce "onaysız update yasak" politikasına dayandırılır: hareketli etiket, hangi imajın koştuğunu belirsizleştirir; 700 cihazda aynı imajı garanti etmenin yolu sabit sürüm etiketi (+ mümkünse digest) ve merkezi rollout'tur.
  - Blueforce etkisi: Compose dosyalarında `image: …:latest` YASAK; sabit tag zorunlu. Digest pinleme (`@sha256:…`) PİLOT-2'de değerlendirilecek ek sıkılık adımı olarak açık soruya yazılır (komut/sözdizimi uydurulmadı, doküman yazımında Compose spec'ten ayrıca doğrulanacak).

- **BULGU A4.5 — Watchtower kullanılmaz; iki bağımsız gerekçe.**
  - İddia 1 (politika): Watchtower "otomatik imaj güncelleyici"dir — Blueforce "onaysız update yasak" kuralını doğrudan ihlal eder (LAB→PİLOT→WAVE rollout zincirini bypass eder).
  - İddia 2 (upstream): `containrrr/watchtower` deposu ARŞİVLENMİŞTİR (`archived: true`, son push 2025-12-17, ~24.6k yıldız, 219 açık issue).
  - Resmi URL: https://github.com/containrrr/watchtower + https://api.github.com/repos/containrrr/watchtower (HTTP 200, 2026-09-15)
  - Blueforce etkisi: Watchtower mimariye GİRMEZ; güncellemeler Ansible/Semaphore zincirinden, onaylı ve dalgalı yapılır. Alternatif "unattended imaj çekme" fikri de aynı gerekçeyle reddedilir.
  - Free notu: Docker CE ücretsizdir; Docker Business/Scout gibi ücretli özellikler mimaride yoktur ve gerekmez.

---

## Karar etkisi özeti (Faz 2'ye girdi)

| # | Karar yönü | Dayanak bulgu |
|---|-----------|---------------|
| 1 | Baz OS: Ubuntu Server 26.04.1+ LTS (GUI'siz kurulum, XFCE sonradan) | A1.1, A1.2 |
| 2 | Masaüstü: XFCE birincil; tam GNOME saha standardı değil | A1.3, A2.1 |
| 3 | Uzaktan bakım katmanı: xRDP (aktif upstream, ücretsiz) + systemd ile GUI aç/kapa | A2.2, A2.3 |
| 4 | `unattended-upgrades` imajda kapatılır (timer dahil), update zinciri LAB→…→PROD | A1.4 |
| 5 | WireGuard istemci: `PersistentKeepalive=25` + `wg-quick@wg0` enable | A3.1, A3.2 |
| 6 | Docker: UFW-bypass'a karşı localhost-bind standardı; log rotasyonu zorunlu; `unless-stopped`; `latest` yasak; Watchtower yok | A4.1–A4.5 |

Açık sorular (tahmin yazılmaz, LAB/PİLOT'ta ölçülür): XFCE oturum başlatma satırı ve `bf-gui-on/off` kesin birim listesi (26.04.1 imajında); MEG log hacmine göre `max-size/max-file` ayarı; Turkcell NAT kopma sayacı ve keepalive ayarı; digest pinleme kararı.
