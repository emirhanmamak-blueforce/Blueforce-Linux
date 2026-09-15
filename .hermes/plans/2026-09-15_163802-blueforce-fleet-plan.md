# Blueforce 700 Cihaz Linux Filo Mimari + Dokümantasyon Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 700 AdBlue saha PC'si için %100 ücretsiz/self-hosted Linux filo mimarisini araştırıp karar vererek, başka bir DevOps mühendisinin sıfırdan kurabileceği 26 Türkçe Markdown dokümanını üretmek.

**Architecture:** Markdown-first Git repo (`blueforce-industrial-linux/`): `docs/` (26 dosya) + `SUMMARY.md` + iskelet `scripts/`, `ansible/`, `config/`, `monitoring/`, `rustdesk/`, `docs-site/`, `tests/`. Önce kaynak doğrulama (resmi docs/GitHub), sonra kararlar, sonra dokümanlar parti parti yazılır.

**Tech Stack:** Ubuntu LTS (26.04 doğrulanacak), WireGuard, RustDesk OSS self-hosted (hbbs/hbbr), xRDP + XFCE/GNOME (karar verilecek), Ansible + Semaphore UI Community, Docker, Prometheus/Node Exporter/Grafana OSS/Uptime Kuma (karşılaştırılacak), Docusaurus (aday docs platformu).

---

## Current Context / Assumptions

- Çalışma dizini: `/home/emirhanmamak/_Work/AMC/Blueforce-Linux` — **boş repo** (sadece `.gitignore` + `.git`). Plan sonunda önerilen repo yapısı sıfırdan kurulacak.
- Şartname kaynağı: kullanıcının yapıştırdığı 28 bölümlük Türkçe şartname (pasted_content_2026-09-15). Implementasyon YOK — sadece araştırma + karar + plan + `.md` üretimi.
- Cihaz kimliği standardı sabit: 8 haneli bayi no → `BF-<no>` (Device ID), `bf-<no>` (hostname). Tüm sistemlerde aynı ID.
- Maliyet kuralı: %100 ücretsiz/self-hosted hedef. Ücretli her araç açıkça işaretlenip alternatifi önerilecek. AnyDesk varsayım yapılmadan resmi kaynaktan doğrulanacak.
- Update politikası: onaysız update yasak (apt, release, Docker, MEG dahil). LAB(2) → PILOT-1(5) → PILOT-2(20) → WAVE-1(50) → WAVE-2(100) → PRODUCTION rollout.
- Basitlik: Kubernetes/microservice/gereksiz agent/DB/cloud yok. Öncelik: kesintisiz çalışma > veri kaybı yok > erişim > bakım kolaylığı.
- Her dokümanda yapı: Amaç, Kapsam, Kararlar, Neden, Alternatifler, Avantaj/Dezavantaj, Riskler, Uygulama Planı, Test Planı, Rollback, Kontrol Listesi, Açık Sorular + uygun yerde Mermaid. Her teknik karar için KARAR/GEREKÇE/ALTERNATİF/RİSK/MALİYET/LİSANS bloğu.
- Çıktı dili Türkçe; komut/dosya/service/terimler İngilizce kalabilir.

## Proposed Approach

1. **Faz 0 — Repo iskeleti:** README + docs/ + önerilen klasör yapısı + docs-site iskeleti. Boş dosya değil, şablonlu başlıklarla.
2. **Faz 1 — Kaynak doğrulama (tahmin yok):** Resmi docs + GitHub üzerinden 10 kritik konuda (Ubuntu 26.04, xRDP/GNOME/XFCE, WireGuard, RustDesk OSS, AnyDesk lisansı, Docker, Ansible, Semaphore Community, Docusaurus/Wiki.js/TriliumNext) doğrulama notları. Her bulgu URL + sürüm + tarih ile kaydedilir.
3. **Faz 2 — Mimari kararlar:** OS/GUI, 4. erişim yöntemi, fleet mgmt, monitoring, docs platformu, golden image yöntemi için karar matrisleri. Sadelik kuralı uygulanır.
4. **Faz 3 — Doküman üretimi (4 parti):** Her parti bağımsız yazılabilir ama karar tutarlılığı için sırayla. Her dosya yukarıdaki şablona uyar.
5. **Faz 4 — QA + eleştiri:** Tutarlılık denetimi (isimlendirme, karar çelişkisi, ücretli sızıntı), SUMMARY.md'deki 27 sorunun cevabı var mı kontrolü, "5 yılda en büyük 10 operasyonel risk" analizi.
6. Paralelleştirme: Faz 1 araştırmaları `delegate_task` ile bağımsız doğrulanabilir; Faz 3 partileri tek yazarda tutulmalı (tutarlılık için) veya sıkı karar günlüğüyle paralel.

## Files Likely to Change (hedef repo yapısı)

```
blueforce-industrial-linux/
├── README.md
├── SUMMARY.md
├── docs/
│   ├── 00-MASTER-PLAN.md
│   ├── 01-ARCHITECTURE.md
│   ├── 02-DEVICE-NAMING-AND-INVENTORY.md
│   ├── 03-UBUNTU-BASELINE.md
│   ├── 04-GOLDEN-IMAGE-AND-PROVISIONING.md
│   ├── 05-ONE-CLICK-INSTALLER.md
│   ├── 06-USERS-SSH-AND-PERMISSIONS.md
│   ├── 07-REMOTE-ACCESS.md
│   ├── 08-WIREGUARD-AND-NETWORK.md
│   ├── 09-FLEET-MANAGEMENT.md
│   ├── 10-UPDATE-AND-ROLLBACK-POLICY.md
│   ├── 11-SECURITY-HARDENING.md
│   ├── 12-DOCKER-OPERATIONS.md
│   ├── 13-MEG-LINUX-ACCEPTANCE.md
│   ├── 14-MONITORING-AND-HEALTH.md
│   ├── 15-LOGGING.md
│   ├── 16-POWER-LOSS-AND-AUTO-RECOVERY.md
│   ├── 17-BACKUP-RECOVERY-AND-REINSTALL.md
│   ├── 18-PILOT-AND-700-DEVICE-ROLLOUT.md
│   ├── 19-TROUBLESHOOTING.md
│   ├── 20-FIELD-TECHNICIAN-RUNBOOK.md
│   ├── 21-CENTRAL-ADMIN-RUNBOOK.md
│   ├── 22-DOCUMENTATION-PLATFORM.md
│   ├── 23-SECURITY-AND-LICENSE-AUDIT.md
│   ├── 24-DECISION-LOG.md
│   └── 25-IMPLEMENTATION-ROADMAP.md
├── scripts/ (install/, maintenance/, diagnostics/, recovery/ — Faz 3'te sadece sözleşme/imza, kod Faz-sonrası)
├── ansible/ (inventory/, playbooks/, roles/)
├── config/ (ssh/, wireguard/, firewall/, docker/, systemd/)
├── monitoring/ | rustdesk/ | docs-site/ | tests/
```

## Step-by-Step Plan

### Task 1: Repo iskeleti + doküman şablonu + karar bloğu standardı

**Objective:** Boş repoya hedef klasör yapısı ve her doc'un uyacağı şablon konur.

**Files:**
- Create: `README.md`, `docs/_TEMPLATE.md`, klasörler `docs/ scripts/{install,maintenance,diagnostics,recovery} ansible/{inventory,playbooks,roles} config/{ssh,wireguard,firewall,docker,systemd} monitoring/ rustdesk/ docs-site/ tests/`

**Step 1:** `README.md` yaz — amaç, 700 cihaz özeti, docs haritası, maliyet kuralı, isimlendirme örneği (BF-12010193).
**Step 2:** `docs/_TEMPLATE.md` yaz — 12 başlık (Amaç…Açık Sorular) + KARAR/GEREKÇE/ALTERNATİF/RİSK/MALİYET/LİSANS bloğu + Mermaid örneği.
**Step 3:** Klasörleri oluştur, `git status` ile doğrula.
**Step 4:** Commit: `docs: repo skeleton and doc template`.

**Verify:** `ls docs/ scripts ansible config` beklenen ağacı verir; şablon 12 başlığı içerir.

### Task 2: Kaynak doğrulama paketi A — OS/GUI/RDP + WireGuard + Docker

**Objective:** Tahmine dayalı kararları engellemek için resmi kaynak bulguları toplanır.

**Files:**
- Create: `docs/24-DECISION-LOG.md` (taslak, sadece Faz-1 bulguları bölümü) — veya geçici `research/A.md` sonra taşınır. Öneri: doğrudan 24'e işle, kaynak URL + sürüm + tarih ile.

**Doğrulanacaklar (resmi docs/GitHub, web_search + web_extract):**
1. Ubuntu 26.04 LTS var mı / saha için uygun mu; minimal+GUI vs Server+XFCE/GNOME davranışları; `unattended-upgrades` varsayılanı (update yasağı için kritik).
2. xRDP + GNOME vs XFCE: RAM/CPU, RDP uyumluluğu, 700 ölçeği. `bf-gui-on/off` için dayanak (target/DM servisi).
3. WireGuard: otomatik reconnect davranışı (PersistentKeepalive, systemd restart), Turkcell NAT arkası notları.
4. Docker: UFW bypass senaryosu + güvenli çözüm; log rotation; `unless-stopped` vs `always`; `latest` yasağı dayanağı; Watchtower kullanılmaması gerekçesi.

**Verify:** Her bulguda en az 1 resmi URL; "ücretsiz" iddiası lisans metniyle destekli. Çıktı 24-DECISION-LOG'a işlenir.

### Task 3: Kaynak doğrulama paketi B — RustDesk OSS + AnyDesk lisansı + 4. erişim

**Objective:** 4-kanallı erişim mimarisinin lisans ve teknik dayanağı netleşir.

**Files:**
- Modify: `docs/24-DECISION-LOG.md` (B bulguları ekle)

**Doğrulanacaklar:**
1. RustDesk OSS self-hosted: hbbs/hbbr VDS kurulumu, Pro gerektirmeyen özellikler, WireGuard çökerse çalışmaya devam eder mi (bağımsız kanal analizi).
2. AnyDesk ticari lisans şartları (resmi fiyat/lisans sayfası): 700 kurumsal cihazda ücretsiz kullanım yasal mı? Sonuç EVET/HAYIR + URL. HAYIR ise mimariden çıkar, sadece opsiyonel installer modülü olarak kalır.
3. 4. bağımsız ücretsiz erişim adayı: MeshCentral / SSH-over-WireGuard / Tailscale-freesiz? — Tailscale gibi freemium tuzaklarına düşmeden gerçek OSS/self-hosted seç (şartname: SSH, RDP, RustDesk + 1 daha).

**Verify:** AnyDesk kararı tek cümle + resmi URL ile 07-REMOTE-ACCESS ve 23'e taşınmaya hazır.

### Task 4: Kaynak doğrulama paketi C — Fleet (Ansible/Semaphore/AWX/Salt/Rudder/MeshCentral) + Monitoring + Docs platformu

**Objective:** Fleet, monitoring ve docs platformu kararlarının dayanağı toplanır.

**Files:**
- Modify: `docs/24-DECISION-LOG.md` (C bulguları ekle)

**Doğrulanacaklar:**
1. Semaphore UI Community: yalnız free/OSS özellikleri listele, Pro/Enterprise bağımlılığı yok. Ansible CLI, AWX, Salt, Rudder Community, MeshCentral ile karşılaştırma (700 cihaz sadeliği).
2. Monitoring: Prometheus+Node Exporter+Grafana OSS vs Netdata Community vs Uptime Kuma — 700 cihazda karmaşıklık/maliyet. Minimum metrik listesi (online/offline … last seen) hangi çözümde nasıl toplanır.
3. Docs: Docusaurus vs MkDocs vs Wiki.js vs TriliumNext — ücretsiz/OSS/self-hosted/Git/Markdown/AI-güncellenebilirlik/search/sidebar/kod/Mermaid/koyu tema/intranet kriterlerine göre tek öneri.

**Verify:** Her kategoride "tek öneri + gerekçe + alternatif" cümlesi hazır.

### Task 5: Mimari kararları kilitle — 24-DECISION-LOG + 01-ARCHITECTURE

**Objective:** Tüm kritik kararlar tek dosyada kilitlenir, mimari diyagram çizilir.

**Files:**
- Modify: `docs/24-DECISION-LOG.md` (nihai karar tablosu), Create: `docs/01-ARCHITECTURE.md`

**Kararlar (her biri KARAR/GEREKÇE/ALTERNATİF/RİSK/MALİYET/LİSANS):**
Ubuntu sürümü/varyantı, GNOME/XFCE, boot=terminal + bf-gui-on/off, SSH/RDP/RustDesk/4.yöntem, WireGuard modeli, fleet çözümü, monitoring, docs platformu, golden image yöntemi, Docker restart politikası.

**Mermaid (01'e):** Internet → WireGuard → SSH/RDP/Mgmt akışı; power boot zinciri (Power→BIOS→Ubuntu→Network→WireGuard→Docker→MEG→Blueforce→Remote→Monitoring); update onay akışı (bulundu→rapor→onay→LAB→PILOT→WAVE→PROD).

**Verify:** SUMMARY.md'deki 27 sorunun her biri en az bir karara izlenebilir.

### Task 6: Parti 1 dokümanlar — isimlendirme, Ubuntu, golden image, installer

**Objective:** Saha kurulumunun çekirdek 4 dosyası yazılır.

**Files:**
- Create: `docs/00-MASTER-PLAN.md`, `docs/02-DEVICE-NAMING-AND-INVENTORY.md`, `docs/03-UBUNTU-BASELINE.md`, `docs/04-GOLDEN-IMAGE-AND-PROVISIONING.md`, `docs/05-ONE-CLICK-INSTALLER.md`

**Notlar:**
- 02: `BF-<8hane>` / `bf-<8hane>` standardı + kullanıldığı 9 sistem listesi + `bf-hardware-inventory.sh` sözleşmesi (JSON+Markdown çıktı alanları: Manufacturer…Temperatures).
- 03: BIOS `Restore on AC Power Loss = Power On`, boot servisleri, GUI on/off tasarımı, GNOME/XFCE kararı.
- 04: Clonezilla/autoinstall/cloud-init/custom ISO/Packer/Ansible karşılaştırması; hedef: USB→Ubuntu→tek script→bayi no→READY.
- 05: `sudo ./blueforce-install.sh` akışı, `^[0-9]{8}$` doğrulama, modül listesi (01-precheck…18-final-check) değerlendirilmiş/geliştirilmiş hali, idempotency kuralı.

**Verify:** Her dosya 12 başlıklı şablona uyar; 05'teki modül listesi 01-precheck…18-final-check ile birebir eşleşir veya sapma gerekçelendirilir.

### Task 7: Parti 2 — erişim, ağ, filo, update

**Objective:** Kritik operasyon 4 dosyası yazılır.

**Files:**
- Create: `docs/06-USERS-SSH-AND-PERMISSIONS.md`, `docs/07-REMOTE-ACCESS.md`, `docs/08-WIREGUARD-AND-NETWORK.md`, `docs/09-FLEET-MANAGEMENT.md`, `docs/10-UPDATE-AND-ROLLBACK-POLICY.md`

**Notlar:**
- 06: `blueforce` kullanıcısı, root SSH kapalı, password SSH kapalı, key zorunlu, sudo kontrollü, servisler ayrı system user; 700 cihazda tek private key riski + doğru auth mimarisi (host başına key / CA önerisi).
- 07: SSH+RDP+RustDesk+dördüncü yöntem; boot otostart; RDP/SSH dışa kapalı, WireGuard arkası; WireGuard çökerse RustDesk analizi.
- 08: peer isimlendirme = bayi ID, PersistentKeepalive, otomatik reconnect, Turkcell paket bitimi/dönüşü senaryosu.
- 09: tek/grup/pilot/tüm-filo işlemleri (ping…GUI OFF listedeki 15 komut), Semaphore Community sınırları içinde.
- 10: onaysız update yasağı + unattended-upgrades kapatma + LAB→…→PROD dalgaları + durdurma/rollback + security update öncelik işareti.

**Verify:** 09'daki 15 işlemin her biri Ansible/Semaphore karşılığına izlenir; 10'daki dalga sayıları LAB(2)/P1(5)/P2(20)/W1(50)/W2(100)/PROD ile eşleşir.

### Task 8: Parti 3 — güvenlik, Docker, MEG, monitoring, log, power

**Objective:** Dayanıklılık 6 dosyası yazılır.

**Files:**
- Create: `docs/11-SECURITY-HARDENING.md`, `docs/12-DOCKER-OPERATIONS.md`, `docs/13-MEG-LINUX-ACCEPTANCE.md`, `docs/14-MONITORING-AND-HEALTH.md`, `docs/15-LOGGING.md`, `docs/16-POWER-LOSS-AND-AUTO-RECOVERY.md`

**Notlar:**
- 11: UFW default DENY, WG arayüzü izinleri, Docker-UFW bypass çözümü, personel yetkisizliği.
- 12: otostart, restart policy, pinli image, `latest` yasağı, log rotation, Watchtower yok.
- 13: MEG ACCEPTANCE TEST checklist (Ubuntu sürümü…package update davranışı — 16 madde), paket detayı varsayılmadan.
- 14: minimum 17 metrik (online…last seen) + dashboard mimarisi + `bf-status` örnek çıktısı + `bf-diagnostics`/`bf-support-bundle` (secret sızdırmaz) sözleşmesi.
- 15: journald/Docker/RustDesk/WG/MEG/Blueforce/installer/update-history limitleri.
- 16: boot zinciri systemd bağımlılıkları, race condition önlemleri.

**Verify:** 14'teki örnek `bf-status` çıktısı şartnamedeki 16 satırlı formata uyar; support-bundle'da secret dışlama kuralı yazılı.

### Task 9: Parti 4 — recovery, rollout, runbook'lar, docs platformu, audit, roadmap

**Objective:** Son 8 dosya + tutarlılık kapanışı.

**Files:**
- Create: `docs/17-BACKUP-RECOVERY-AND-REINSTALL.md`, `docs/18-PILOT-AND-700-DEVICE-ROLLOUT.md`, `docs/19-TROUBLESHOOTING.md`, `docs/20-FIELD-TECHNICIAN-RUNBOOK.md`, `docs/21-CENTRAL-ADMIN-RUNBOOK.md`, `docs/22-DOCUMENTATION-PLATFORM.md`, `docs/23-SECURITY-AND-LICENSE-AUDIT.md`, `docs/25-IMPLEMENTATION-ROADMAP.md`

**Notlar:**
- 17: LEVEL 1…9 recovery (service→…→golden image reinstall), her seviyede merkezi+yerel prosedür.
- 18: donanım bilinmediği için önce `bf-hardware-inventory.sh` taraması, sonra dalgalı rollout.
- 20: teknisyen diliyle sade (USB→kur→bayi no→READY), 21: merkezi admin (onay yetkisi kimde, update'i kim başlatır).
- 23: her ücretli aday için ÜCRETLİ işareti + ücretsiz alternatif; AnyDesk hükmü.
- 25: FAZ'lı yol haritası; unattended provisioning ayrı FAZ.

**Verify:** LEVEL sayısı 9; 20 saha diliyle, 21 merkez diliyle ayrışır.

### Task 10: SUMMARY.md + 10 risk eleştirisi + final QA

**Objective:** Teslim kapanışı ve mimari öz-eleştirisi.

**Files:**
- Create: `SUMMARY.md` (repo kökü), Modify: gerekirse tutarlılık düzeltmeleri

**SUMMARY.md içeriği:** 27 sorunun kesin cevabı (hangi Ubuntu…hangi platform — her cevap ilgili doc'a linkli) + "Bu sistem 700 istasyonda 5 yıl çalışacak olsa en büyük 10 operasyonel risk" (her risk + önlem) + gerçekten tamamen ücretsiz olanların listesi.

**Final QA checklist:**
- [ ] 26 dosya var, hepsi Türkçe, şablonlu, Mermaid yerinde.
- [ ] Cihaz adı `BF-…`/hostname `bf-…` her doc'ta tutarlı.
- [ ] Ücretli hiçbir araç zorunlu mimaride değil; AnyDesk hükmü resmi URL'li.
- [ ] Onaysız update'e giden hiçbir varsayılan açık değil (unattended-upgrades dahil).
- [ ] 27 sorunun cevabı SUMMARY'den doc'lara izlenebilir.
- [ ] Commit: `docs: complete fleet documentation v1`.

## Tests / Validation

- `ls docs/ | wc -l` = 26 (+ `_TEMPLATE.md`).
- `grep -r "AnyDesk" docs/23-SECURITY-AND-LICENSE-AUDIT.md` lisans hükmü + resmi URL içerir.
- `grep -ri "unattended" docs/10-UPDATE-AND-ROLLBACK-POLICY.md docs/03-UBUNTU-BASELINE.md` kapatma adımı içerir.
- Her doc'ta 12 başlığın varlığı: `for f in docs/*.md; do grep -c "^## " $f; done` — eksik başlık yok.
- Mermaid blok sayısı: `grep -r '```mermaid' docs/ | wc -l` ≥ 4 (mimari, ağ, update, power).
- Tutarlılık: `grep -rho "BF-[0-9]\{8\}" docs/ | sort -u` örnekleri ve `bf-gui-on|bf-status|bf-diagnostics|bf-support-bundle|bf-hardware-inventory` adları tüm doc'larda aynı.

## Risks, Tradeoffs, Open Questions

- **Ubuntu 26.04 (2026 itibarıyla):** Şartname 26.04 diyor; doğrulamada mevcut değilse/uygun değilse 24.04 LTS'e düşme kararı + gerekçesi gerekir. [AÇIK]
- **Donanım bilinmiyor:** amd64/arm64, serial/RS232/USB, GPU karışık olabilir → golden image tek imajda çalışmayabilir; önce inventory taraması şart. [RİSK]
- **MEG .deb detayları yok:** Acceptance testi varsayımsız yazılacak; paket gelince 13 numaralı doc revize edilir. [AÇIK]
- **Turkcell NAT/kota:** WireGuard keepalive + kotasız yönetim trafiği minimizasyonu (monitoring aralığı) dengesi. [RİSK]
- **Tek private SSH key:** 700 cihaza yayılırsa sızıntı blast-radius'u büyük → ev sahibi CA / per-admin key önerisi. [RİSK]
- **Semaphore Community sınırları:** Pro özelliğine yaslanılırsa maliyet kuralı delinir; her playbook Community ile test edilmeli. [RİSK]
- **Tradeoff — sadelik vs gözetlenebilirlik:** 700 cihazda full Prometheus yerine hafif push + Uptime Kuma kombinasyonu seçilebilir; Faz 2'de kilitlenir.
- **Kapsam dışı (bu planda YOK):** Script kodlarının implementasyonu, VDS kurulumu, gerçek cihaz testi — bunlar 25-ROADMAP'in sonraki FAZ'ları.

---

**Kaynak:** Kullanıcı şartnamesi (28 bölüm, 1042 satır, pasted_content_2026-09-15). Maliyet/lisans/karar kuralları şartnameden birebir alınmıştır.
