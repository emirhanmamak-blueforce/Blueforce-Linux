# Blueforce Linux Filo — 700 Saha Cihazı

> %100 ücretsiz / self-hosted Linux filo mimarisi: başka bir DevOps mühendisinin sıfırdan kurabileceği 26 Türkçe dokümanın ana reposu.

## Amaç

AdBlue saha otomasyonundaki ~700 Windows mini PC'yi, lisans maliyeti olmayan, merkezi yönetilebilir, kesintisiz çalışan bir Linux filosuna taşımak.

Bu repo üç şeyi tek yerde toplar:

1. **Kararlar** — her teknik seçim için gerekçe, alternatif, risk, maliyet ve lisans notu.
2. **Kurulum ve işletme dokümanları** — `docs/` altında 26 Türkçe Markdown dosyası.
3. **Uygulanabilir iskelet** — `scripts/`, `ansible/`, `config/`, `monitoring/`, `rustdesk/` klasörleri (kod ve config Faz 3'te dolar).

Öncelik sırası: **kesintisiz çalışma > veri kaybı yok > uzaktan erişim > bakım kolaylığı.**

## 700 Cihaz Özeti

| Konu | Özet |
|---|---|
| Cihaz sayısı | ~700 saha PC'si (bayi/istasyon yanında) |
| Cihaz kimliği | 8 haneli bayi no → Device ID `BF-<no>`, hostname `bf-<no>` (ör. `BF-12010193` / `bf-12010193`). Tüm sistemlerde aynı ID kullanılır. |
| Hedef OS | Ubuntu LTS (sürüm Faz 1'de resmi kaynaktan doğrulanacak) |
| Ağ | Turkcell modem arkası, CGNAT/NAT varsayımı; merkezle bağlantı WireGuard tüneli üzerinden |
| Uzaktan erişim | RustDesk OSS self-hosted (hbbs/hbbr) ana yol; SSH + WireGuard yedek yol; RDP/GUI ihtiyaca göre |
| Filo yönetimi | Ansible + Semaphore UI Community (aday; Faz 2'de karar) |
| İzleme | Prometheus/Node Exporter/Grafana OSS veya Uptime Kuma (Faz 2'de karşılaştırılacak) |
| Güncelleme politikası | **Onaysız update yasak** (apt, release upgrade, Docker image, MEG dahil). Rollout: LAB(2) → PILOT-1(5) → PILOT-2(20) → WAVE-1(50) → WAVE-2(100) → PRODUCTION |
| Doküman dili | Türkçe; komut, dosya, servis ve terim adları İngilizce kalır |

## Docs Haritası (26 dosya)

Tüm dokümanlar `docs/` altındadır ve `docs/_TEMPLATE.md` şablonuna uyar.

| No | Dosya | Konu |
|---|---|---|
| 00 | `00-MASTER-PLAN.md` | Genel plan, fazlar, kapsam |
| 01 | `01-ARCHITECTURE.md` | Uçtan uca mimari |
| 02 | `02-DEVICE-NAMING-AND-INVENTORY.md` | `BF-<no>` / `bf-<no>` isimlendirme ve envanter |
| 03 | `03-UBUNTU-BASELINE.md` | Ubuntu taban kurulum |
| 04 | `04-GOLDEN-IMAGE-AND-PROVISIONING.md` | Golden image ve ilk kurulum |
| 05 | `05-ONE-CLICK-INSTALLER.md` | Tek-tık kurucu |
| 06 | `06-USERS-SSH-AND-PERMISSIONS.md` | Kullanıcılar, SSH, yetkiler |
| 07 | `07-REMOTE-ACCESS.md` | RustDesk + SSH + RDP erişim yolları |
| 08 | `08-WIREGUARD-AND-NETWORK.md` | WireGuard ve ağ |
| 09 | `09-FLEET-MANAGEMENT.md` | Ansible/Semaphore filo yönetimi |
| 10 | `10-UPDATE-AND-ROLLBACK-POLICY.md` | Güncelleme ve geri alma politikası |
| 11 | `11-SECURITY-HARDENING.md` | Güvenlik sertleştirme |
| 12 | `12-DOCKER-OPERATIONS.md` | Docker işletimi |
| 13 | `13-MEG-LINUX-ACCEPTANCE.md` | MEG Linux kabul kriterleri |
| 14 | `14-MONITORING-AND-HEALTH.md` | İzleme ve sağlık |
| 15 | `15-LOGGING.md` | Log toplama ve saklama |
| 16 | `16-POWER-LOSS-AND-AUTO-RECOVERY.md` | Elektrik kesintisi ve otomatik kurtarma |
| 17 | `17-BACKUP-RECOVERY-AND-REINSTALL.md` | Yedekleme, kurtarma, yeniden kurulum |
| 18 | `18-PILOT-AND-700-DEVICE-ROLLOUT.md` | Pilot ve 700 cihaz rollout |
| 19 | `19-TROUBLESHOOTING.md` | Sorun giderme |
| 20 | `20-FIELD-TECHNICIAN-RUNBOOK.md` | Saha teknisyeni runbook |
| 21 | `21-CENTRAL-ADMIN-RUNBOOK.md` | Merkezi yönetici runbook |
| 22 | `22-DOCUMENTATION-PLATFORM.md` | Doküman platformu (Docusaurus adayı) |
| 23 | `23-SECURITY-AND-LICENSE-AUDIT.md` | Güvenlik ve lisans denetimi |
| 24 | `24-DECISION-LOG.md` | Karar günlüğü (kaynak URL + sürüm + tarih ile) |
| 25 | `25-IMPLEMENTATION-ROADMAP.md` | Uygulama yol haritası |

Şablon: `docs/_TEMPLATE.md`. Karar günlüğü: `docs/24-DECISION-LOG.md`.

## Maliyet Kuralı

- Hedef **%100 ücretsiz / self-hosted**'dir.
- Ücretli veya lisans kısıtlı her araç dokümanda açıkça işaretlenir ve **ücretsiz alternatifi** ile birlikte verilir.
- Varsayıma dayalı lisans kararı verilmez; resmi kaynak (resmi docs, GitHub, fiyat sayfası) URL + sürüm + tarih ile kaydedilir.
- Örnek: AnyDesk kararı resmi kaynaktan doğrulanmadan yazılmaz.

## İsimlendirme Örneği

Bayi no `12010193` için:

- Device ID: `BF-12010193`
- Hostname: `bf-12010193`
- WireGuard peer adı, RustDesk ID etiketi, Ansible inventory adı, monitoring etiketi: hepsi aynı ID'yi kullanır.

## Klasör Yapısı

```
.
├── README.md
├── SUMMARY.md                # Faz 4'te üretilecek
├── docs/                     # 26 doküman (00–25) + _TEMPLATE.md
├── scripts/
│   ├── install/              # ilk kurulum scriptleri (Faz 3'te sözleşme/imza)
│   ├── maintenance/          # bakım scriptleri
│   ├── diagnostics/          # tanı scriptleri
│   └── recovery/             # kurtarma scriptleri
├── ansible/
│   ├── inventory/
│   ├── playbooks/
│   └── roles/
├── config/
│   ├── ssh/
│   ├── wireguard/
│   ├── firewall/
│   ├── docker/
│   └── systemd/
├── monitoring/               # izleme config ve panoları
├── rustdesk/                 # hbbs/hbbr self-hosted config
├── docs-site/                # doküman sitesi iskeleti (Docusaurus adayı)
├── tests/                    # doğrulama testleri
└── research/                 # Faz 1 kaynak doğrulama notları
```

## Durum

- [x] Faz 0: repo iskeleti + şablon
- [ ] Faz 1: kaynak doğrulama (resmi docs/GitHub, 10 kritik konu)
- [ ] Faz 2: mimari kararlar
- [ ] Faz 3: 26 dokümanın parti parti yazımı
- [ ] Faz 4: QA, tutarlılık denetimi, SUMMARY.md
