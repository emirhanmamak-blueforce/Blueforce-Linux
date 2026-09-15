# B — Uzaktan Erişim Araştırması (Faz 1B)

Tarih: 2026-09-15. Kapsam: 700 cihazlık filo için bağımsız uzaktan erişim kanalı.
Sözlük: hbbs = RustDesk ID/randevu (rendezvous) + sinyalizasyon sunucusu;
hbbr = röle (relay) sunucusu; VDS = sanal özel sunucu.

> Not: Web arama altyapısı (Nous gateway) kapalı olduğundan bulgular
> curl ile çekilen resmi dokümantasyon sayfaları + GitHub API üzerinden
> doğrulandı. Cloudflare korumalı `anydesk.com` pazarlama sayfalarına curl
> ile erişilemedi; AnyDesk fiyatlandırması gerçek tarayıcı ile, lisans
> şartları ise Cloudflare korumasız resmi bilgi bankası
> (`support.anydesk.com`) üzerinden doğrulandı.

## 1. RustDesk OSS self-hosted (hbbs + hbbr)

- Mimari: istemciler önce hbbs'e kaydolur (ID, heartbeat, NAT tipi testi);
  doğrudan P2P kurulamazsa trafik hbbr üzerinden rölelenir. İkisi de tek
  `rustdesk/rustdesk-server` imajından `hbbs` / `hbbr` komutuyla çalışır.
  Kaynak: https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/
  (erişim 2026-09-15; sürüm bilgisi aşağıda).
- VDS kurulumu (Docker Compose, önerilen `network_mode: "host"`):
  `rustdesk/rustdesk-server:latest` imajı, `./data:/root` kalıcı hacmi,
  `unless-stopped` yeniden başlatma. Kaynak:
  https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/docker/
  (erişim 2026-09-15).
- Güvenlik duvarı portları: hbbs 21115/TCP (NAT testi), 21116/TCP+UDP
  (ID kaydı/heartbeat + TCP hole punching), 21118/TCP (web istemcisi,
  opsiyonel); hbbr 21117/TCP (röle), 21119/TCP (web istemcisi, opsiyonel).
  21114/TCP yalnızca Pro web konsolunundur. 21118/21119 kullanılmıyorsa
  kapalı tutulmalıdır (IP sahteciliği uyarısı dokümanda). Kaynak: aynı
  Docker sayfası (erişim 2026-09-15).
- Pro gerektirmeyen özellikler (OSS'ta mevcut): sınırsız istemci, kendi
  ID + röle altyapın, uçtan uca şifreli P2P/röleli oturum, dosya transferi,
  katılımsız erişim (kalıcı parola), betikli toplu dağıtım (PowerShell /
  batch / MSI / macOS bash / Linux bash). Toplu dağıtımda istemciye
  self-hosted sunucu adresi + yapılandırma dizesi (config string) gömülür.
  Kaynak: https://rustdesk.com/docs/en/self-host/client-deployment/
  (erişim 2026-09-15).
- Yalnızca Pro'da olanlar (OSS'ta YOK): web konsolu, API, OIDC/SSO, LDAP,
  2FA, erişim kontrolü, rol tabanlı yönetim, denetim logları, strateji/
  adres defteri, özel istemci üretici. Kaynak:
  https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/ +
  https://rustdesk.com/pricing/ (erişim 2026-09-15; Individual ~11,88
  USD/ay, Basic ~23,88 USD/ay, yıllık faturalı).
- Sürümler (GitHub API, 2026-09-15): istemci `rustdesk/rustdesk` 1.4.9
  (2026-07-06); sunucu `rustdesk/rustdesk-server` 1.1.16 (2026-07-20).
  Lisans: AGPL-3.0 (her iki repo). Yıldız: istemci ~123,6b, sunucu ~10,4b.

### WireGuard çökerse bağımsız kanal çalışır mı? — EVET

RustDesk istemcisi, yapılandırılan ID sunucusuna (VDS genel IP/DNS,
21115-21117) doğrudan internet üzerinden ulaşır; trafik WireGuard
arayüzünden geçme zorunluluğu yoktur (istemcide tünel içi bir adres değil,
VDS'nin gerçek adresi tanımlanır). hbbs/hbbr, istemcilerin gerçek gelen
IP'sini görmelidir (`--net=host` önerisinin gerekçesi de budur). Dolayısıyla
WireGuard servisi veya ana tünel çökse bile RustDesk kanalı ayakta kalır;
tek ortak bağımlılık VDS'nin kendisi ve genel internet erişimidir. Bu,
tasarım hedefiyle de tutarlıdır: "kendi randevu/röle sunucunu kur, verinin
kontrolü sende" (https://github.com/rustdesk/rustdesk README,
erişim 2026-09-15). Öneri: Blueforce mimarisinde RustDesk kanalını
WireGuard'a bağımlı yapmayacak şekilde, istemcide VDS genel adresi kullan;
`ALWAYS_USE_RELAY=Y` yalnız NAT sorunlu sahalarda değerlendir (gecikme/
bant genişliği maliyetiyle).

## 2. AnyDesk ticari lisans — 700 kurumsal cihazda ücretsiz kullanım yasal mı?

**HAYIR.** Ücretsiz sürüm yalnızca kişisel kullanımı kapsar; ticari
kullanımda giden bağlantıyı başlatan istemcilerin lisanslı olması şarttır.
Resmi bilgi bankası: "Only outgoing clients that initiate connections to
other AnyDesk clients for commercial use need to have an AnyDesk license."
Kaynak: https://support.anydesk.com/docs/anydesk-licenses.md
(güncellenme 2025-10-30, erişim 2026-09-15). 700 cihazlık kurumsal filo
açıkça ticari kullanımdır; ücretsiz sürüm lisans ihlali olur.

- Güncel fiyatlar (https://anydesk.com/en/pricing, tarayıcıyla erişim
  2026-09-15): Solo (100 yönetilen cihaz) → Standard ~34,32 USD/ay
  (500 yönetilen cihaz, 20 kullanıcı) → Advanced ~72,72 USD/ay
  (1000 yönetilen cihaz, 100 kullanıcı) → Ultimate (2000 cihazdan başlar,
  ölçeklenebilir, teklifli). 700 cihaz Standard'ı aşar (500) → en az
  Advanced gerekir; hepsi yıllık faturalı, KDV hariç.
- **Mimari karar: AnyDesk birincil/ücretsiz kanal olarak mimariden
  ÇIKARILDI.** Gerekçe: lisans maliyeti + kapalı kaynak + self-hosted
  seçeneğin yalnızca en üst (Ultimate/On-Premises) planda olması.
- Opsiyonel not (mimari dışı): müşteri sahasında zaten lisanslı AnyDesk
  varsa, teknisyen erişimi için "opsiyonel installer modülü" olarak
  paketlenebilir; ancak Blueforce imajında varsayılan kurulu gelmez,
  envanter/lisans takibi müşteriye aittir.

## 3. Dördüncü bağımsız ücretsiz erişim adayı: MeshCentral (önerilen)

Tailscale/ZeroTier gibi freemium, merkezi kimlik isteyen çözümler elendi;
gerçek OSS + self-hosted olan MeshCentral seçildi.

- Nedir: NodeJS tabanlı, web üzerinden bilgisayar yönetimi; aracı (agent)
  kurulu cihazlar sunucuda görünür; web tabanlı uzak masaüstü + terminal +
  dosya yönetimi dahili. Kaynak: https://meshcentral.com (erişim
  2026-09-15) + https://github.com/Ylianst/MeshCentral readme.md
  (erişim 2026-09-15).
- Lisans: Apache-2.0 (package.json `license` alanı + LICENSE dosyası,
  GitHub API ile doğrulandı 2026-09-15). Ticari kullanım dahil ücretsiz,
  self-hosted'da kullanıcı/cihaz kotası yok.
- Sürüm: 1.2.5 (yayınlanma 2026-08-12, GitHub API 2026-09-15). Aktif bakımda
  (son push 2026-09-14). Yıldız ~7,2b.
- Platformlar: sunucu ve aracı Windows/Linux/macOS/FreeBSD (resmi site).
  Kurulum: `meshcentral` npm paketi üzerinden (`npm install -g meshcentral`
  standardı), dokümantasyon: https://ylianst.github.io/MeshCentral/
  (README'de bağlantılı, erişim 2026-09-15).
- Blueforce rolü: RustDesk birincil grafik kanal; MeshCentral ikincil
  yönetim düzlemi (envanter + terminal + dosya + web konsolu) olarak aynı
  veya ayrı VDS'de koşar. O da kendi portları üzerinden internete çıkar;
  WireGuard'dan bağımsız ikinci bir "ölüm-dışı" kanal sağlar. Not: ilk
  kurulumda TLS (Let's Encrypt / ters vekil) ve 2FA açılmalıdır (resmi
  dokümanda anlatılır).

## 4. Karar özeti

| Kanal | Rol | Lisans | WireGuard bağımsız mı? |
|---|---|---|---|
| RustDesk OSS (hbbs/hbbr, VDS) | Birincil grafik uzak erişim | AGPL-3.0, ücretsiz | EVET |
| MeshCentral (VDS) | İkincil yönetim (terminal/dosya/envanter) | Apache-2.0, ücretsiz | EVET |
| WireGuard | Ana güvenli ağ | OSS | — (kendisi) |
| AnyDesk | Mimariden çıkarıldı; yalnızca müşteri lisanslıysa opsiyonel installer modülü | Ticari lisans gerekli | — |

Doğrulanamayan / sonraki faza kalan: RustDesk `id_ed25519.pub` anahtar
dağıtım otomasyonu detay adımları (Faz 2 kurulum betiklerinde ele alınacak);
MeshCentral gerçek VDS kurulum testi yapılmadı (Faz 2).
