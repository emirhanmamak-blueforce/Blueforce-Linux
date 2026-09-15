# 23 — Güvenlik ve Lisans Denetimi (Security & License Audit)

> Kısa özet: Mimariye giren her ücretli-aday aracın lisans hükmü + ücretsiz karşılığı tek tabloda; AnyDesk'in neden mimariden çıkarıldığı resmi URL'leriyle. Yeni araç öneren önce bu dosyaya bakar.

- Dosya: `docs/23-SECURITY-AND-LICENSE-AUDIT.md`
- İlgili kararlar: `24-DECISION-LOG.md#K-04` (AnyDesk HAYIR + RustDesk/MeshCentral), `#K-06` (Semaphore Community), `#K-07` (Netdata elendi), `#K-10` (Watchtower)
- Durum: [ ] Taslak

---

## 1. Amaç

"Şu aracı da kursak mı?" sorusunun lisans cevabını tek yerde vermek ve 700 cihazda lisanssız ticari kullanımı baştan engellemek. Her satırda resmi kaynak URL'si vardır; kulaktan-dolma lisans bilgisi yasaktır.

## 2. Kapsam

- Kapsam içi: ücretli-aday araçların hükmü, seçilen ücretsiz karşılıklar, AnyDesk HAYIR hükmü, periyodik denetim rutini.
- Kapsam dışı: teknik kurulum (ilgili dokümanlar), firewall/SSH sertleştirme detayı (11-HARDENING).

## 3. Kararlar

```text
KARAR:    AnyDesk ücretsiz sürümü Blueforce filosunda KULLANILAMAZ; AnyDesk mimariden çıkarılmıştır.
GEREKÇE:  AnyDesk ücretsiz sürümü yalnızca kişisel kullanımı kapsar; 700 kurumsal saha cihazı ticari kullanımdır ve lisanssız kullanım sözleşme ihlali olur. Kurumsal kullanım en az ücretli plan gerektirir; ayrıca kapalı kaynak + self-hosted yalnızca en üst planda sunulur.
ALTERNATİF: Müşteri sahasında zaten lisanslı AnyDesk varsa opsiyonel installer modülü olarak kalabilir (merkezi mimarinin parçası değil) — bunun dışında alternatif yoktur; birincil/ikincil erişim RustDesk OSS + MeshCentral'dır (K-04).
RİSK:     Sahada "alışkanlıkla" AnyDesk Free kurulur; azaltma: golden image'da AnyDesk yoktur + periyodik denetimde kurulu yazılım taraması yapılır.
MALİYET:  Kullanılmadığı için lisans bedeli yoktur (kullanılsaydı: ücretli plan zorunlu).
LİSANS:   AnyDesk lisans şartı — https://support.anydesk.com/docs/anydesk-licenses.md (güncelleme 2025-10-30; doğrulanma: 2026-09-15) + plan listesi https://anydesk.com/en/pricing (doğrulanma: 2026-09-15).
```

```text
KARAR:    Zorunlu mimarideki tüm bileşenler FREE katmandadır; ücretli-aday her araç için ücretsiz karşılık aşağıdaki tabloda sabitlenmiştir. Hiçbir playbook, compose veya imaj ücretli özelliğe bağlanamaz.
GEREKÇE:  700 cihazda "küçük" lisans bedeli bile çarpanla büyür; ücretsiz-tabana bağlılık hem maliyeti hem denetim yükünü sıfırlar. Karşılık tablosu, gelecekteki "Pro'ya geçelim" baskısına hazır cevap verir.
ALTERNATİF: İhtiyaç oldukça ücretli plana geçme — maliyet takibi + sözleşme yükü + kilitlenme; elendi.
RİSK:     Ücretsiz sürümün kapsamı değişir (upstream fiyat politikası); azaltma: yıllık lisans gözden geçirme (§9 rutin).
MALİYET:  Ücretsiz (VDS kira bedeli hariç — altyapı maliyeti, lisans değil).
LİSANS:   Bileşen lisansları 24-DECISION-LOG Ek A'da (doğrulama: 2026-09-15).
```

## 4. Neden Bu Karar?

Lisans denetimi "hukuk işi" değil, mimari iştir: ücretli bir bileşen mimariye girerse 700 cihazın tamamı o sözleşmeye kilitlenir. Bu dosya, her ücretli adayı daha teklif aşamasında ücretsiz karşılığıyla eşleştirir; AnyDesk maddesi bunun en sert örneğidir (kişisel-kullanım tuzağı). Güvenlik boyutu da aynı tablodadır: kapalı kaynak + dış kimlik (Tailscale/ZeroTier tipi) hem lisans hem veri-egemenliği riski taşır.

## 5. Alternatifler

| Alternatif | Artı | Eksi | Sonuç |
|---|---|---|---|
| İhtiyaç oldukça lisans satın alma | Esnek | 700 çarpanı, sözleşme takibi, kilitlenme | Elendi |
| Karma (bazı cihazlar ücretli) | Hedefli harcama | İki sınıf filo, denetim karmaşası | Elendi |
| Yıllık lisanssız "görmezden gelme" | Kısa vadeli kolay | Sözleşme ihlali + denetimde ceza | Yasak |

## 6. Avantajlar

- Denetimde (müşteri/üst yönetim) her satırın resmi URL'si hazırdır.
- Yeni araç teklifi 5 dakikada elenebilir veya kabul edilebilir (tabloya uyar mı?).

## 7. Dezavantajlar

- Upstream fiyat/lisans değişiklikleri takip ister (yıllık rutin).
- Bazı ücretsiz sürümler özelliksizdir (örn. Semaphore Community'de OIDC/2FA/Vault yok) — bu eksikler operasyonel disiplinle kapatılır (K-06).

## 8. Riskler

| Risk | Olasılık | Etki | Azaltma |
|---|---|---|---|
| Sahaya lisanssız ticari yazılım kurulur | Orta | Yüksek | İmajda yok + periyodik kurulu-yazılım taraması |
| Upstream free kapsamı daralır | Düşük | Orta | Yıllık gözden geçirme + yedek alternatifler (§9 tablo) |
| AGPL yükümlülüğü ihlali (değişiklik dağıtırsak) | Düşük | Orta | Değişikliksiz self-host politikası (RustDesk/Grafana notu) |

## 9. Uygulama Planı

### Ücretli-aday → ücretsiz-karşılık tablosu (FREE sürümler baz)

| Ücretli aday | Neden girmedi | Ücretsiz karşılık (mimaride) | Lisans / kaynak |
|---|---|---|---|
| AnyDesk (ücretli plan) | Free yalnızca kişisel kullanım; 700 cihaz ticari → ihlal | RustDesk OSS hbbs/hbbr + MeshCentral | AGPL-3.0 / Apache-2.0 — https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/ ; https://github.com/Ylianst/MeshCentral ; hüküm https://support.anydesk.com/docs/anydesk-licenses.md |
| RustDesk Pro | Gerekmez — OSS sınırsız istemci + self-host verir | RustDesk OSS 1.4.9 / sunucu 1.1.16 | AGPL-3.0 — https://rustdesk.com/pricing/ (doğrulanma: 2026-09-15) |
| Semaphore Pro/Enterprise | 700 cihaz > Pro 500 node sınırı; Community yeterli | Semaphore UI Community | MIT, Community $0 — https://semaphoreui.com/pricing + https://github.com/semaphoreui/semaphore |
| Netdata Cloud (ücretli) | Free 5 node kotası 700'de ücrete düşer | Prometheus + Node Exporter + Grafana OSS + Uptime Kuma | Apache-2.0 / AGPL-3.0 / MIT (24 Ek A 23–25) |
| Tailscale / ZeroTier (ücretli kademeler) | Freemium + merkezi kimlik | WireGuard (self-hosted hub-spoke) | OSS — https://www.wireguard.com/quickstart/ |
| Ubuntu Pro / ESM | Mimari ESM'e bel bağlamaz | Ubuntu LTS ücretsiz + onaylı update dalgaları | https://releases.ubuntu.com/ |
| Docker Business / Scout | Mimaride yok | Docker CE + sabit tag disiplini | https://docs.docker.com/ |
| Wiki.js Cloud / Confluence | DB yükü + ücret | Docusaurus (MIT) | https://github.com/facebook/docusaurus |
| AWX (operatör maliyeti) / Salt / Rudder Enterprise | K8s/agent/relay yükü | Ansible CLI + Semaphore Community | GPL-3.0 / MIT — https://github.com/ansible/ansible |

```bash
# örnek: sahada lisanssız/izinsiz yazılım taraması (merkezden)
ansible all -m shell -a "dpkg -l | grep -i -E 'anydesk|teamviewer' || echo TEMIZ"
# örnek: Watchtower kalıntısı taraması (politika ihlali, K-10)
ansible all -m shell -a "docker ps --format '{{.Names}} {{.Image}}' | grep -i watchtower || echo TEMIZ"
```

### Periyodik rutin

1. Üç ayda bir: yukarıdaki taramalar + `latest` etiketi denetimi + `unattended-upgrades` kapalılık kontrolü (K-11).
2. Yılda bir: tablo satırlarındaki resmi URL'ler yeniden çekilir, fiyat/lisans değişikliği varsa bu dosya PR ile güncellenir.
3. Yeni araç teklifi: tabloya satır eklenmeden kuruluma girmez (21'deki onay yetkilisi denetler).

## 10. Test Planı

| Test | Beklenen sonuç | Ortam |
|---|---|---|
| İmajda AnyDesk/TeamViewer paketi yok | `dpkg -l` temiz | LAB(2) imaj denetimi |
| İmajda Watchtower yok, `latest` yok | `docker images` sabit tag | LAB(2) |
| `unattended-upgrades` kapalı | Timer'lar maskeli, değerler `0` | LAB(2) |

## 11. Rollback

Lisans değişikliği (upstream free kapsamı daralırsa): yedek alternatife (tablodaki "Yedek" satırları, örn. MkDocs) geçilir; değişiklik 24-DECISION-LOG PR'ı ile yapılır, bu dosya aynı PR'da güncellenir.

## 12. Kontrol Listesi

- [ ] AnyDesk HAYIR hükmü resmi URL'li (§3 birinci blok).
- [ ] Her ücretli-adayın ücretsiz karşılığı tabloda + URL'li.
- [ ] Üç aylık tarama job'ları Semaphore'da tanımlı.
- [ ] Yıllık URL tazeleme takvime işlendi.

## 13. Açık Sorular

- [ ] Üç aylık tarama sonuçlarının raporlanacağı merci (sahibi: merkezi admin, 21).
- [ ] AGPL değişiklik-dağıtım politikasının hukukça gözden geçirilmesi gerekli mi (sahibi: yönetim).
- [ ] Müşteri-lisanslı AnyDesk modülünün şartları (sahibi: 07-REMOTE-ACCESS yazarı).

---

## Ek: Lisans Karar Akışı (yeni araç teklifi)

```mermaid
flowchart TB
    TEKLIF["Yeni araç teklifi"] --> UCRET{"Ücretli katman / lisans gerektirir mi?"}
    UCRET -->|Hayır (OSS, kotasız)| KABUL["Mimariye alınabilir<br/>(karşılık tablosuna işlenir)"]
    UCRET -->|Evet| KARSILIK{"Ücretsiz karşılığı tabloda var mı?"}
    KARSILIK -->|Var| RED["Teklif elenir<br/>karşılık kullanılır"]
    KARSILIK -->|Yok| PR["24-DECISION-LOG PR'ı açılır<br/>Ek A'ya URL + sürüm + tarih"]
```
