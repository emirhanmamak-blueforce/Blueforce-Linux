# Faz 1C Araştırma — Fleet Yönetimi + Monitoring + Docs Platformu

- Tarih: 2026-09-15 (doğrulama günü güncel resmi kaynaklar)
- Kapsam: 700 saha cihazı, %100 ücretsiz/self-hosted, sadelik öncelikli
- Kural: Her bulgunun resmi URL'si vardır. Sürüm/plan bilgisi değişebilir; karar öncesi URL'den teyit edilir.

---

## 1. Fleet Yönetimi Karşılaştırması

### 1.1. Adaylar ve lisans (resmi kaynak)

| Araç | Lisans (OSS çekirdek) | Kaynak |
|---|---|---|
| Ansible (CLI / core) | GPL-3.0 | https://github.com/ansible/ansible |
| Semaphore UI Community | MIT, "$0, free forever, open source" | https://github.com/semaphoreui/semaphore — https://semaphoreui.com/pricing |
| AWX | Apache-2.0 | https://github.com/ansible/awx (README rozeti → https://github.com/ansible/awx/blob/devel/LICENSE.md) |
| Salt (Salt Project) | Apache-2.0 | https://github.com/saltstack/salt — https://docs.saltproject.io/ |
| Rudder (Core) | GPL-3.0, Core açık kaynak; Enterprise abonelik node başına/yıl ücretli | https://github.com/Normation/rudder — https://www.rudder.io/en/pricing/ |
| MeshCentral | Apache-2.0 | https://github.com/Ylianst/MeshCentral — https://meshcentral.com/ |

### 1.2. Semaphore UI Community — ücretsiz/OSS özellikler ve Pro bağımlılığı yoktur kanıtı

Resmi plan karşılaştırmasına göre (https://semaphoreui.com/pricing):

**Community ($0) içinde VAR (ücretsiz, MIT, self-hosted):**
Ansible/Terraform/OpenTofu/Shell/Python/PowerShell çalıştırma; статиk/dosya/dinamik envanter yönetimi;
yeniden kullanılabilir Task Template; Cron zamanlama; Variable Groups; merkezi Key Store (şifreli, runtime enjeksiyon);
Global Runner ile dağıtık çalıştırma; proje-seviyesi erişim kontrolü + RBAC; Task/Activity/Server log geçmişi;
REST API; Webhook tetikleyiciler; Git depoları (GitHub/GitLab/Bitbucket); bildirimler (e-posta, Slack, Teams vb.);
AI iş akışları için MCP sunucusu; docs + topluluk desteği.

**Yalnızca Pro/Enterprise'da VAR (Community'de YOK, ama 09-FLEET kapsamı için gerekli DEĞİL):**
izole Project Runner'lar; task özetleri; HashiCorp Vault/AWS/Azure/Devolutions gizli yönetimi;
2FA (TOTP); LDAP/AD; OIDC SSO; IdP grup eşleme; özel roller; dosya-tabanlı log dışa aktarma;
HA kurulum; air-gapped lisans; SLA destek.

**Pro bağımlılığı yok — üç kanıt:**
1. Community "free forever and open source ... start automating without a paid subscription" — https://semaphoreui.com/pricing
2. Community kodu MIT lisanslı public repo — https://github.com/semaphoreui/semaphore
3. Kritik eşik: **Pro en fazla 500 managed node** destekler ("Up to 500 managed nodes ... For larger environments,
choose Enterprise"). 700 cihaz zaten Pro kapsamını aşıyor; ücretli yola girilse bile Pro yetmez, Enterprise gerekir.
Community'de lisansla dayatılan node kotası yoktur (self-hosted, kota lisans anahtarına bağlıdır; Community anahtarsız çalışır).
Sonuç: filo yönetimi Community + Ansible CLI ile kurulur; hiçbir iş akışı Pro/Enterprise özelliğine bağlanmaz
(Vault yerine Key Store, SSO yerine WireGuard arkası + SSH anahtarı, izole runner yerine Global Runner).

**Community free limitleri (bilinerek kabul edilenler, Pro'ya taşınmadan çözümüyle):**
- OIDC/SSO, LDAP/AD, 2FA yok → çözüm: Semaphore yalnızca WireGuard arkasında, erişim VPN + SSH anahtarı ile.
- HashiCorp Vault/AWS/Azure gizli yönetimi yok → çözüm: yerleşik şifreli Key Store.
- İzole Project Runner yok → çözüm: Global Runner + proje-seviyesi erişim kontrolü.
- Dosya-tabanlı log dışa aktarma ve task özeti yok → çözüm: Task/Activity geçmişi UI + API'den çekilir, merkezi loga taşınır.
- HA yok → çözüm: Ansible CLI bağımsız çalışır; Semaphore çökse filo durmaz (günlük yedek + hızlı yeniden kurulum).

### 1.3. Karşılaştırma — 700 cihaz sadeliği

| Kriter | Ansible CLI | Semaphore Community | AWX | Salt | Rudder Community | MeshCentral |
|---|---|---|---|---|---|---|
| 700 cihaza ek yük | Yok (agent'sız, SSH) | Tek Go binary + DB, hafif | **Ağır: Kubernetes + AWX Operator zorunlu** | Minion agent + master PKI | Server + relay + agent (ağır) | Server + agent (uzaktan erişim ağırlıklı) |
| Öğrenme/işletme sadeliği | YAML playbook, en basit | Playbook'u UI'dan çalıştırma, basit | K8s bilgisi ister, karmaşık | State/pillar/grain modeli, orta-zor | Politika/direktif modeli, orta-zor | Filo otomasyonu değil, erişim aracı |
| Ücretsiz kapsam riski | Yok (GPL-3.0) | Yok (yukarıdaki kanıt) | **Sürüm riski: son release 2 Tem 2024, "releases paused during refactoring"** — https://github.com/ansible/awx | SaltStack Config (Broadcom) ücretli; OSS taraf güvenli ama master ölçekleme ister | Enterprise modülleri (relay, patch kampanyası, CVE yönetimi) ücretli — https://www.rudder.io/en/pricing/ | Yok (Apache-2.0), ama konfigürasyon yönetimi değil |
| 700 cihaz kanıtı | Binlerce node pratiği yaygın | Global Runner + dinamik envanter | Ölçeklenir ama K8s maliyetiyle | Ölçeklenir (master yatırımı) | Ölçeklenir (relay yatırımı) | 700 cihaza filo-komut modeli zayıf |

- AWX kurulumu: https://docs.ansible.com/projects/awx/en/latest/ (Operator tabanlı) ve refactoring duyuruları:
  https://www.ansible.com/blog/upcoming-changes-to-the-awx-project/
- Salt docs: https://docs.saltproject.io/ — minion/master mimarisi 700 cihazda ek PKI ve master kapasite planı ister.
- MeshCentral kapsamı "remote monitoring and management" (erişim + envanter), Ansible-filo karşılığı değildir:
  https://github.com/Ylianst/MeshCentral

### 1.4. KARAR

- **KARAR:** Birincil filo otomasyonu **Ansible CLI (SSH, agent'sız)**; operatör arayüzü **Semaphore UI Community
  (self-hosted, MIT)**. Hiçbir playbook/iş akışı Pro/Enterprise özelliği kullanmaz.
- **GEREKÇE:** En düşük hareketli parça (SSH + YAML + tek Go binary); 700 cihazda ek agent/master/K8s/DB maliyeti yok;
  Community ücretsizliği resmi fiyat sayfasıyla kanıtlı; 500-node Pro kotası 700 cihazda ücretli yolu zaten kapatıyor.
- **ALTERNATİF:** AWX (K8s yükü + release'ler duraklatıldı → elendi); Salt (agent + master PKI yükü → elendi);
  Rudder Community (politika modeli güçlü ama relay/Enterprise modülleri ve öğrenme eğrisi → elendi);
  MeshCentral (4. erişim kanalı adayı olarak değerlendirilir, filo otomasyonu olarak değil).
- **RİSK:** Semaphore tek nokta arızası → Ansible CLI her zaman bağımsız çalışır (UI çökse filo durmaz).
  Community'de OIDC/2FA yok → Semaphore yalnızca WireGuard arkasında yayınlanır, admin erişimi VPN + SSH anahtarı ile.
- **MALİYET:** $0 (kendi VDS'i üzerinde).
- **LİSANS:** Ansible GPL-3.0, Semaphore MIT — ticari kullanımda lisans bedeli yok.

---

## 2. Monitoring Karşılaştırması

### 2.1. Adaylar ve lisans

| Çözüm | Lisans | Kaynak |
|---|---|---|
| Prometheus + Node Exporter | Apache-2.0 / Apache-2.0 | https://github.com/prometheus/prometheus — https://github.com/prometheus/node_exporter — https://prometheus.io/docs/guides/node-exporter/ |
| Grafana OSS | AGPL-3.0 (self-hosted ücretsiz) | https://github.com/grafana/grafana — https://grafana.com/oss/ |
| Netdata (Agent OSS + Cloud) | Agent GPL-3.0; **Cloud Free yalnızca 5 node'a kadar, sonrası node başına ~$4.50/ay'dan başlar** | https://github.com/netdata/netdata — https://www.netdata.cloud/pricing/ |
| Uptime Kuma | MIT | https://github.com/louislam/uptime-kuma |

### 2.2. Karşılaştırma — 700 cihaz

| Kriter | Prometheus + Node Exporter + Grafana OSS | Netdata | Uptime Kuma |
|---|---|---|---|
| Merkezi metrik (700 node) | Sınırsız, ücretsiz (kendi Prometheus'u) | Merkezi görünüm Cloud'da; **ücretsiz kota 5 node** → 700 cihaz ücretli | Metrik yok; sadece uptime/nabız |
| Cihaz başı yük | node_exporter tek binary (~hafif, :9100) | Agent zengin ama 700'de Parent/Cloud planı gerekir | Yok (ajan gerektirmez; push/ping) |
| Kurulum sadeliği | Orta (prometheus.yml + systemd) | Kolay (agent), ama 700'de merkezi tasarım gerekir | Çok kolay (tek Docker konteyneri) |
| Alarm | Alertmanager / Grafana alerting (ücretsiz) | Cloud bildirimleri kotaya bağlı | 90+ bildirim servisi, ücretsiz, 20 sn aralık — https://github.com/louislam/uptime-kuma |
| Last-seen/çevrimdışı takibi | `up` metriği + `time() - timestamp` | Agent kalp atışı (kotalı merkez) | Push monitörü + ping grafik + sertifika bilgisi |

### 2.3. 17 minimum metrik — nerede, nasıl toplanır

Önerilen mimaride (Prometheus birincil + Uptime Kuma tamamlayıcı) her metriğin kaynağı:

| # | Metrik | Prometheus + Node Exporter | Uptime Kuma | Netdata Community |
|---|---|---|---|---|
| 1 | online/offline | `up{job="node"}` (scrape başarısı) | HTTP/TCP/Ping monitörü UP/DOWN | agent kalp atışı |
| 2 | last seen (son görülme) | `time() - timestamp(up)` veya Pushgateway/nodeli `node_time_seconds` farkı | Push monitör zaman damgası | — (kotalı) |
| 3 | CPU % | `node_cpu_seconds_total` → rate | — | agent |
| 4 | RAM % | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` | — | agent |
| 5 | Disk % (her mount) | `node_filesystem_avail_bytes / node_filesystem_size_bytes` | — | agent |
| 6 | Disk inode % | `node_filesystem_files_free / node_filesystem_files` | — | agent |
| 7 | Disk IO (read/write) | `node_disk_read_bytes_total`, `node_disk_written_bytes_total` | — | agent |
| 8 | Ağ up/down (B/sn) | `node_network_receive_bytes_total`, `node_network_transmit_bytes_total` | ping gecikme grafiği (kısmi) | agent |
| 9 | Load average (1/5/15) | `node_load1/5/15` | — | agent |
| 10 | Uptime / boot zamanı | `node_boot_time_seconds`, `node_time_seconds - node_boot_time_seconds` | — | agent |
| 11 | Swap kullanımı | `node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes` | — | agent |
| 12 | systemd failed üniteler | `node_systemd_unit_state{state="failed"}` (systemd collector) | — | agent |
| 13 | Sıcaklık (CPU/disk) | `node_hwmon_temp_celsius` / `node_thermal_zone_temp` (textfile ile de beslenebilir) | — | agent/eBPF |
| 14 | WireGuard handshake yaşı | textfile collector (`wg show all latest-handshakes` → `.prom`) | Ping monitörü (dolaylı: VPN çökerse DOWN) | — |
| 15 | Docker konteyner durumu (MEG dahil) | cAdvisor veya textfile (`docker ps` özeti → `.prom`) | Docker konteyner monitörü (var/yok) | agent |
| 16 | MEG süreç sağlığı | textfile (`pgrep`/health endpoint → `.prom`) + blackbox HTTP probu | HTTP(s) Keyword monitörü (MEG arayüzü kelime kontrolü) | — |
| 17 | Ping gecikmesi / paket kaybı | blackbox_exporter `probe_duration_seconds`, `probe_success` | Ping grafiği (yerleşik) | — |

- Node Exporter collector'ları ve `:9100/metrics` davranışı: https://prometheus.io/docs/guides/node-exporter/
- textfile collector (özel metrikler: WireGuard, Docker, MEG için standart yol): Node Exporter `--collector.textfile.directory`
  (https://github.com/prometheus/node_exporter).
- Uptime Kuma yetenekleri (Docker konteyner, Push, HTTP Keyword, ping grafiği, 20 sn aralık, 90+ bildirim):
  https://github.com/louislam/uptime-kuma
- Netdata ücretsiz kotası nedeniyle 3–17'nin merkezi takibi 700 cihazda ücrete takılır:
  https://www.netdata.cloud/pricing/

**Free sürüm limit notları (monitoring):**
- Prometheus + Node Exporter: limitsiz ve kotasız (Apache-2.0); limit, donanım kapasitesidir (retention/kardinalite LAB'da ölçülür).
- Grafana OSS (AGPL-3.0, self-hosted ücretsiz): dashboard, alerting, LDAP/OAuth dahil; Enterprise'a özgü
  (SAML, audit log, datasource izinleri, scaling desteği) özellikler kapsam dışı bırakıldı — 14-MONITORING yalnızca OSS
  özelliği kullanır (https://grafana.com/oss/).
- Netdata: Agent OSS (GPL-3.0) tek başına kotasızdır, ancak 700 cihazın **merkezi** görünümü Cloud üzerinden
  kotaya takılır (Free: 5 node; sonrası node başına ücret). Self-hosted Parent ile merkezileştirme mümkün olsa da
  ek tasarım/işletme yükü getirir → elenme gerekçesi budur.
- Uptime Kuma (MIT): tüm özellikler ücretsiz, yerleşik limit yok; tek sınır, metrik toplamamasıdır (uptime nabzı verir).

### 2.4. KARAR

- **KARAR:** Birincil **Prometheus + Node Exporter + Grafana OSS** (tüm 17 metrik); tamamlayıcı **Uptime Kuma**
  (saha-teknisyeni dostu UP/DOWN panosu + Push "last seen" + bildirimler). Netdata elendi.
- **GEREKÇE:** 17 metriğin tamamı yalnızca Prometheus yığınında ücretsiz ve kotasız toplanır (14/15/16 textfile ile);
  Netdata Cloud Free 5 node kotası 700 cihazda ücrete düşer; Uptime Kuma metrik vermez ama en basit
  çevrimdışı alarmını ve durum sayfasını verir — ikisi birbirini tamamlar, karmaşıklık artmaz (Uptime Kuma tek konteyner).
- **ALTERNATİF:** Yalnızca Uptime Kuma (metrik körlüğü → elendi); Netdata self-hosted Parent (merkezi tasarım + kota riski → elendi).
- **RİSK:** 700 node'lu Prometheus'ta saklama/kardinalite → kayıt aralığı 60 sn, retention 30–90 gün, etiket şeması
  `BF-<no>` standardında sabitlenir; federasyon/fazlı rollout ile büyütülür.
- **MALİYET:** $0 (kendi VDS'i üzerinde).
- **LİSANS:** Prometheus/Node Exporter Apache-2.0; Grafana OSS AGPL-3.0 (değişiklik yapılmadan self-host kullanılır);
  Uptime Kuma MIT.

---

## 3. Docs Platformu Karşılaştırması

### 3.1. Adaylar ve lisans

| Platform | Lisans | Kaynak |
|---|---|---|
| Docusaurus | MIT | https://github.com/facebook/docusaurus — https://docusaurus.io/ |
| MkDocs (+ Material) | BSD-2-Clause (MkDocs); Material for MkDocs MIT/Insiders ayrı | https://github.com/mkdocs/mkdocs — https://www.mkdocs.org/ — https://squidfunk.github.io/mkdocs-material/ |
| Wiki.js | AGPL-3.0 | https://github.com/requarks/wiki — https://js.wiki/ — https://docs.requarks.io/ |
| TriliumNext | AGPL-3.0, kişisel bilgi tabanı | https://github.com/TriliumNext/Trilium |

### 3.2. Kriter matrisi (şartname: ücretsiz/OSS, self-hosted, Git, Markdown, AI-güncelleme, search, sidebar, kod, Mermaid, koyu tema, intranet)

| Kriter | Docusaurus | MkDocs (+Material) | Wiki.js | TriliumNext |
|---|---|---|---|---|
| Ücretsiz/OSS | Evet (MIT) | Evet (BSD) | Evet (AGPL-3.0) | Evet (AGPL-3.0) |
| Self-hosted intranet | Evet (statik dosya, Nginx) | Evet (statik dosya, Nginx) | Evet (Node.js + PostgreSQL/SQLite) | Kısmi (tek kullanıcılı sunucu modu; ekip intraneti için uygun değil) |
| Git (sürümleme/diff/PR) | **Yerleşik: docs zaten Git'te** | **Yerleşik: docs zaten Git'te** | Harici: Git storage hedefi senkronu (ek yapılandırma) — https://docs.requarks.io/storage/git | Yerleşik değil (kendi sync formatı) |
| Markdown | Evet (MDX dahil) | Evet | Evet (+WYSIWYG/HTML editör) — https://js.wiki/ | Evet (zengin not, wiki değil) |
| AI ile güncelleme | **En kolay: düz `.md` dosyalar, ajan doğrudan düzenler** | **En kolay: düz `.md` dosyalar** | API/DB üzerinden (dolaylı) | API üzerinden (dolaylı) |
| Arama | Yerleşik (lokal search eklentisi, offline çalışır) | Yerleşik (Material search, offline) | Yerleşik (DB tabanlı) | Yerleşik (kişisel) |
| Sidebar/sürüm/i18n | Yerleşik (sidebar, versioning, i18n) | Eklenti/tema ile | Yerleşik navigasyon | Ağaç not yapısı |
| Kod blokları | Prism, sekmeli kod, başlıklı blok | Highlight + ek eklentiler | Evet | Evet |
| Mermaid | Resmi destek — https://docusaurus.io/docs/markdown-features/diagrams | Material ile destek — https://squidfunk.github.io/mkdocs-material/reference/diagrams/ | Modül ile (ek yapılandırma) | Sınırlı/eklenti |
| Koyu tema | Yerleşik (kullanıcı değiştirebilir) | Yerleşik (Material toggle) | Yerleşik (light/dark) — https://js.wiki/ | Tema var |
| Operasyonel yük | Derleme hattı (Node), DB yok | Derleme hattı (Python), DB yok | **Çalışan servis + DB (yedekleme/izleme ister)** | Düşük ama ekip akışına uygun değil |

- Wiki.js özellik/editör/karanlık mod/DB seçenekleri: https://js.wiki/
- Docusaurus diyagram/search/versioning/i18n: https://docusaurus.io/docs/markdown-features/diagrams
- MkDocs statik üretim: https://www.mkdocs.org/

**Free sürüm limit notları (docs):** Dört adayın da önerilen sürümü tam ücretsizdir — gizli kota yok:
Docusaurus MIT (tüm özellikler açık), MkDocs BSD + Material Community (ücretli "Insider" eklentileri kapsam dışı,
gerekli değil), Wiki.js AGPL-3.0 (tüm modüller dahil, Enterprise sürümü yok), TriliumNext AGPL-3.0.
Elendikleri için değil, free-limitleri olmadığı için not düşüldü; seçim ölçütü Git-yerleşiklik + AI-güncelleme + sıfır servis yüküdür.

### 3.3. KARAR

- **KARAR:** **Docusaurus** (repo'da `docs-site/` iskeleti; `docs/*.md` tek kaynak, site derlemesi CI'da).
- **GEREKÇE:** Şartnamedeki "AI-güncelleme" kriterini yalnızca Git-yerleşik Markdown çözer (ajan `.md`'yi doğrudan yazar,
  review PR'dan geçer); Wiki.js'nin DB+servis yükü "basitlik" kuralını bozar ve Git akışını dolaylı hale getirir;
  TriliumNext tek-kullanıcı bilgi tabanıdır, 26 dosyalık ekip dokümantasyonu için yayın akışı yoktur;
  MkDocs'a karşı Docusaurus'u seçme nedeni: yerleşik sürümleme (LAB→PROD evrelerinde doküman sürümü),
  yerleşik i18n (TR öncelikli, EN yolu açık), MDX ile runbook içi parametreli bileşenler ve React ekosisteminde
  hazır intranet temaları — derleme maliyeti MkDocs ile eşdeğerdir.
- **ALTERNATİF:** MkDocs + Material (eşdeğer sadelikte güçlü ikinci; Docusaurus derleme hattı sorun çıkarırsa geçiş
  maliyeti düşük çünkü kaynak yine düz Markdown). Wiki.js (DB yükü → elendi). TriliumNext (ekip akışı yok → elendi).
- **RİSK:** Node derleme hattı → `docs-site/` kilitli bağımlılıklar + CI'da derleme testi; derleme bozulsa bile
  `docs/*.md` ham haliyle okunur (tek kaynak kaybı yok).
- **MALİYET:** $0.
- **LİSANS:** Docusaurus MIT; üretilen içerik bize ait.

---

## 4. Özet — üç tek-öneri

1. **Fleet:** Ansible CLI + Semaphore UI Community (Pro bağımlılığı yok — kanıt §1.2).
2. **Monitoring:** Prometheus + Node Exporter + Grafana OSS (17 metrik) + Uptime Kuma (UP/DOWN + bildirim).
3. **Docs:** Docusaurus (`docs/*.md` tek kaynak).

## 5. Açık sorular (karar günlüğüne taşınacak)

- Semaphore Community'de lisansla dayatılan node kotası yoktur varsayımı `pricing` + repo davranışıyla doğrulandı;
  700 node'lu gerçek yük testi LAB evresinde yapılır (Global Runner sayısı, eşzamanlılık).
- Prometheus retention/kardinalite hesabı (700 × 60 sn scrape) LAB'da ölçülür, 14-MONITORING'e yazılır.
- Uptime Kuma Push monitörleri için cihaz başına heartbeat betiği sözleşmesi 14-MONITORING'e yazılır.
