# 02 — Cihaz Adlandırma ve Envanter

> Kısa özet: 8 haneli bayi numarasından türetilen tek cihaz kimliği (`BF-<no>`/`bf-<no>`) standardı ve 9 sistemde kullanımı; donanım taraması yapan `bf-hardware-inventory.sh` sözleşmesi. Filoda join anahtarıdır.

- Dosya: `docs/02-DEVICE-NAMING-AND-INVENTORY.md`
- İlgili kararlar: `24-DECISION-LOG.md#K-12` (cihaz kimliği), `K-09` (envanter önce, imaj sonra)
- Durum: [ ] Taslak

---

## 1. Amaç

700 cihazda tek, okunabilir, çakışmasız kimlik standardı kurmak ve bu kimliğin 9 sistemde birebir aynı değeri taşımasını sağlamak. Bayi numarası değişirse ne yapılacağı da bu dosyanın prosedürüdür.

## 2. Kapsam

- Kapsam içi: `BF-<no>`/`bf-<no>` formatı, doğrulama kuralı, 9 sistemdeki kullanım tablosu, `bf-hardware-inventory.sh` JSON+Markdown sözleşmesi, yeniden-numaralandırma prosedürü.
- Kapsam dışı: hostname atama komut akışı detayı (05-ONE-CLICK-INSTALLER), Ansible inventory şeması detayı (09-FLEET), monitoring etiket şeması detayı (14-MONITORING).

## 3. Kararlar

```text
KARAR:    8 haneli bayi no → Device ID `BF-<no>` (büyük, insan arayüzü) + hostname `bf-<no>` (küçük, makine adı); WireGuard peer adı, RustDesk etiketi, Ansible inventory adı, monitoring etiketi hepsi aynı ID'yi kullanır.
GEREKÇE:  Tek kimlik 9 sistemde join anahtarıdır; büyük/küçük ayrımı insan-makine karışıklığını önler (insan `BF-`, makine `bf-`). Örnek: `BF-12010193` / `bf-12010193`.
ALTERNATİF: Rastgele UUID / MAC-tabanlı ad — saha teknisyeni için okunamaz, bayi eşleşmesi manuel olur → elendi.
RİSK:     Bayi no değişirse kimlik çakışması; azaltma: §9'daki yeniden-no prosedürü + envanter benzersizlik kontrolü.
MALİYET:  Ücretsiz.
LİSANS:   Yok (isimlendirme standardı).
```

```text
KARAR:    Donanım taraması `bf-hardware-inventory.sh` ile yapılır; çıktı hem JSON (makine) hem Markdown (insan) üretir; zorunlu alanlar §9'daki sözleşmededir.
GEREKÇE:  Heterojen saha donanımı bilinmeden golden image dondurulamaz (K-09); tarama LAB/PİLOT öncesi her profili belgeler, imaj test matrisine girer.
ALTERNATİF: Manuel envanter tablosu — 700 cihazda eksik/hatalı veri riski nedeniyle elendi.
RİSK:     Script farklı donanımda alan boş bırakır; azaltma: §10'daki şema doğrulama testi.
MALİYET:  Ücretsiz.
LİSANS:   Yok (şirket içi script).
```

## 4. Neden Bu Karar?

Bayi numarası sahada zaten bilinen tek anahtardır; yeni bir numara üretmek eşleşme maliyeti doğurur. 8 hane sabit uzunluk (`^[0-9]{8}$`) yazım hatasını format düzeyinde yakalar. 9 sistemde aynı adın kullanılması, arıza anında "hangi cihaz?" sorusunu tek cevaba indirir: `BF-12010193` denen cihaz her panelde aynı cihazdır.

## 5. Alternatifler

| Alternatif | Artı | Eksi | Sonuç |
|---|---|---|---|
| UUID | Çakışmasız | Okunamaz, bayi eşleşmesi manuel | Elendi |
| MAC-tabanlı ad | Donanıma bağlı benzersiz | Ağ kartı değişince ad değişir, okunamaz | Elendi |
| Seri-no tabanlı ad | Üretici garantili | Format üreticiye göre değişir, 9 sistemde normalize gerekir | Elendi |

## 6. Avantajlar

- Tek format kuralı (`^[0-9]{8}$`) tüm giriş noktalarında (kurucu, Ansible, envanter) aynı regex ile doğrulanır.
- Büyük/küçük ayrımı log aramalarında ve etiketlerde karışıklığı önler.
- Envanter JSON'u monitoring ve Ansible'a doğrudan beslenebilir.

## 7. Dezavantajlar

- Bayi no değişimi 9 sistemde atomik güncelleme gerektirir (prosedür §9).
- 8 hane dışı gerçek no'lar (kısa/uzun) sıfır-dolgu kuralına ihtiyaç duyar — kural: soldan sıfırla 8 haneye tamamlanır.

## 8. Riskler

| Risk | Olasılık | Etki | Azaltma |
|---|---|---|---|
| Yinelenen bayi no (çift kayıt) | Düşük | Yüksek | Merkezi envanterde benzersizlik kontrolü, kurucu kaydı reddeder |
| Bayi no değişiminde eski adın artıkları | Orta | Orta | Yeniden-no prosedürü (§9) + eski adın 30 gün alias tutulması |
| Envanter JSON şema kayması | Düşük | Orta | Şema sürümü (`schema_version`) + CI doğrulama |

## 9. Uygulama Planı

1. Bayi no doğrulama kuralı: `^[0-9]{8}$` — uymayan girdi reddedilir, kurucu devam etmez (05'teki akış).
2. 9 sistemde kimlik kullanımı:

| # | Sistem | Kullanılan değer | Örnek |
|---|---|---|---|
| 1 | DNS / hostname | `bf-<no>` | `bf-12010193` |
| 2 | WireGuard peer adı | `bf-<no>` | `bf-12010193` |
| 3 | RustDesk cihaz etiketi | `BF-<no>` | `BF-12010193` |
| 4 | MeshCentral cihaz adı | `BF-<no>` | `BF-12010193` |
| 5 | Ansible inventory adı | `bf-<no>` | `bf-12010193` |
| 6 | Prometheus/Grafana etiketi (`device_id`) | `BF-<no>` | `BF-12010193` |
| 7 | Log alanı (`device_id`) | `BF-<no>` | `BF-12010193` |
| 8 | Merkezi envanter kaydı (anahtar) | `BF-<no>` | `BF-12010193` |
| 9 | Runbook/arıza kaydı başlığı | `BF-<no>` | `BF-12010193` |

3. `bf-hardware-inventory.sh` sözleşmesi — çalıştırma ve çıktılar:

```bash
# saha PC'sinde (kurucu öncesi veya bağımsız tarama)
sudo ./bf-hardware-inventory.sh --dealer-id 12010193 --out-dir /var/lib/blueforce/inventory
# çıktılar:
#   /var/lib/blueforce/inventory/BF-12010193.json
#   /var/lib/blueforce/inventory/BF-12010193.md
```

JSON zorunlu alanları (`schema_version: 1`):

```json
{
  "schema_version": 1,
  "device_id": "BF-12010193",
  "hostname": "bf-12010193",
  "dealer_id": "12010193",
  "collected_at": "2026-09-15T10:00:00+03:00",
  "cpu": {"model": "...", "cores": 4, "arch": "x86_64"},
  "memory_mb": 8192,
  "disks": [{"name": "sda", "size_gb": 256, "type": "ssd"}],
  "network": {"macs": ["..."], "wireless": true},
  "gpu": {"model": "..."},
  "bios": {"vendor": "...", "version": "...", "ac_restore": "Power On"},
  "os": {"distro": "Ubuntu", "version": "26.04.1"},
  "notes": ""
}
```

Markdown çıktısı aynı alanların insan-okunur tablosudur (başlık: `# Donanım Envanteri — BF-12010193`, her bölüm tablo satırı).

4. Yeniden-numaralandırma prosedürü (bayi no değişirse):
   1. Eski `BF-<eski>` kaydı envanterde `retired` işaretlenir, 30 gün alias tutulur.
   2. Yeni no ile kurucu yeniden koşar (`blueforce-install.sh --dealer-id <yeni>`).
   3. WireGuard peer, RustDesk etiketi, MeshCentral adı, Ansible inventory, monitoring etiketi yeni ID'ye taşınır; eski peer anahtarı iptal edilir.
   4. Alias süresi dolunca eski kayıt arşivlenir.

## 10. Test Planı

| Test | Beklenen sonuç | Ortam |
|---|---|---|
| `^[0-9]{8}$` dışı girdi (7/9 hane, harf) | Kurucu reddeder, exit ≠ 0 | LAB(2) |
| JSON şema doğrulama (`schema_version`, zorunlu alanlar) | Eksik alan = hata | LAB(2) |
| Yinelenen no ile kayıt | Merkezi envanter reddeder | LAB(2) |
| 9 sistemde ad tutarlılığı | Tümü aynı no'yu taşır | P1(5) |

## 11. Rollback

1. Yanlış no ile kurulan cihaz: `blueforce-install.sh --dealer-id <doğru>` idempotent yeniden koşar, hostname + peer + etiketler düzelir.
2. Envanter kaydı hatalıysa JSON yeniden üretilir, merkezi kayıt güncellenir; eski sürüm arşivde tutulur.

## 12. Kontrol Listesi

- [ ] Format regex'i kurucu + envanter + Ansible'da aynı (`^[0-9]{8}$`).
- [ ] JSON zorunlu alan listesi script ile eşleşiyor.
- [ ] 9 sistem tablosundaki her satırın sahibi doküman linkli (06/07/08/09/14/15/20).
- [ ] Yeniden-no prosedürü runbook'a işlendi.

## 13. Açık Sorular

- [ ] 8 haneden kısa/uzun gerçek no var mı — saha listesiyle doğrulanacak (sahibi: 18-ROLLOUT).
- [ ] Merkezi envanterin fiziksel konumu (VDS'de dosya mı, Semaphore Key Store mu) (sahibi: 09-FLEET yazarı).

---

## Ek: Kimlik Akışı

```mermaid
flowchart LR
    BAYI["Bayi no<br/>12010193"] -->|^[0-9]8$| KURUCU["blueforce-install.sh"]
    KURUCU --> H["hostname<br/>bf-12010193"]
    KURUCU --> WG["WireGuard peer<br/>bf-12010193"]
    KURUCU --> ENV["Envanter JSON/MD<br/>BF-12010193"]
    ENV --> ANS["Ansible inventory"]
    ENV --> MON["Prometheus etiketi"]
    ENV --> RD["RustDesk / MeshCentral"]
```
