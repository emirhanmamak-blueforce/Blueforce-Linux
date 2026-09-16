# Enrollment sözleşmesi (Field OS yaşam döngüsü)

Bu dizin **sözleşmedir, uç nokta değildir**: istemci davranışı, istek/yanıt şemaları ve
güven modeli burada tanımlanır. Merkezi enrollment API'si bu repoda uygulanmaz;
uygulanması ayrı bir güvenlik incelemesi gerektirir (prompt §18, `docs/29` §13).

İlgili dosyalar: `docs/29-DEVICE-ENROLLMENT.md` (karar K-17), `docs/26` (K-15),
`schemas/enrollment-request.schema.json`, `schemas/enrollment-response.schema.json`.

## 1. Durum makinesi (ileri yönlü, atlama yok)

```text
(yok) --yerel kurulum--> PROVISIONED_OFFLINE --tek kullanımlık token--> ENROLLED --tüm kanallar doğrulandı--> READY
```

| Aşama | Ne kanıtlanır | Gerekli kanıt | İnternet |
|---|---|---|---|
| `PROVISIONED_OFFLINE` | Yerel kurulum tamam; cihaz çevrimdışı işe hazır | `bf-check-local`: yerel sistem durumu, xRDP, WireGuard anahtar çifti | Gerekmez |
| `ENROLLED` | Merkez cihazı tanıdı, WireGuard peer atandı, monitoring/inventory/RustDesk yapılandırması uygulandı | Doğrulanmış enrollment yanıtı + `central_verification` referansları + yeni WG handshake | Gerekir |
| `READY` | Yerel sağlık **ve** üç merkezi kanal doğrulandı | `bf-check-ready`: `bf-check-local` + `bf-check-enrollment` + `bf-remote-status --check` | Gerekir |

Geçiş kuralları (yazıcı ve okuyucu tarafında birlikte uygulanır):

- **Geriye dönüş yok.** `ENROLLED -> PROVISIONED_OFFLINE` ve `READY -> ENROLLED` yazılmaz;
  `bf-enroll` READY cihazda çalışmayı reddeder. READY sonrası ciddi kimlik sorunu
  `docs/27` akışıyla yeniden provision edilir.
- **Atlama yok.** `PROVISIONED_OFFLINE -> READY` doğrudan yazılamaz. READY yalnız
  `bf-check-ready` geçtikten sonra final gate tarafından yazılır; okuma tarafında
  `bf-enrollment-status` böyle bir durumu `INVALID` ve sıfırdan farklı çıkış kodu ile
  bildirir (fail-closed).
- **Atomik yazım.** Her geçiş aynı dizinde `tmp + rename` ile yapılır, dosya modu `0600`,
  `fsync` uygulanır. Yazıcılar `.state.lock` üzerinde `flock` ile serileştirilir ve geçiş
  kilit altında yeniden doğrulanır (boot timer ile teknisyen yarışı).
- **Yetkili yazıcılar.** `PROVISIONED_OFFLINE` yerel kurulum, `ENROLLED` `bf-enroll`,
  `READY` final kurulum kapısı. Başka hiçbir araç yaşam döngüsü durumunu değiştirmez:
  `bf-status`, `bf-enrollment-status`, `bf-check-*` yalnız okur.

Durum dosyası sözleşmesi (`/var/lib/blueforce/state.json`, `chmod 600`, `BF_STATE_FILE`
ile geçersiz kılınabilir): `phase`, `enrollment_status`, `fleet_status`, `device_id`
(`BF-<no>`), `provisioning_id`. Bilinmeyen ek alanlar korunur ve yok sayılır.

## 2. İstek / yanıt sözleşmesi

**İstek** (`bf-enroll`, `schemas/enrollment-request.schema.json`): `device_id`,
`wireguard_public_key`, `idempotency_key`, `hardware`, `release`. İstek gövdesinde
secret yoktur: WireGuard private key, token değeri ve diğer kimlik bilgileri gövdeye
girmez. Tek kullanımlık token `Authorization` başlığında, argv'ye düşmeyen anonim bir
process-substitution fd'si üzerinden taşınır; başlık dosyaya, state'e veya loga yazılmaz.

**Yanıt** (`schemas/enrollment-response.schema.json`): `status` (`accepted`), `device_id`,
`idempotency_key` (istekle birebir aynı olmalı), isteğe bağlı `enrollment_id`,
`wireguard` (hub public key + adres + endpoint + allowed_ips) ve **zorunlu**
`central_verification` (`status`, `verification_id` ve her biri `status` +
`verification_id` taşıyan `monitoring`, `remote`, `management`). Yanıt bütünüyle
doğrulanır: fazla alan, uyuşmayan kimlik ya da `idempotency_key` tüm yanıtı reddettirir.
Yerel WireGuard yapılandırması yalnız bu doğrulamadan sonra kurulur; private key
merkezden **kabul edilmez**, cihazda kalır.

`central_verification` referansları istemci tarafından üretilmez; yalnız doğrulanmış
enrollment yanıtından kalıcılaştırılır. Eksik/biçimsiz kayıt ENROLLED kapısını, `pending`
kanal ise READY kapısını fail-closed düşürür (cihaz ENROLLED kalır).

## 3. Güven modeli: alternatifler

| Seçenek | Artı | Eksi | 700 cihaz ölçeği | Sonuç |
|---|---|---|---|---|
| **Tek kullanımlık, TTL'li token** | Küçük sızıntı alanı; kayıp başına iptal edilebilir; cihaz bağlama (`BF-<no>`) | Token üretim/i̇ptal hizmeti gerekir | Cihaz başına ayrı kayıt izi | **Seçildi** (K-17) |
| İmzalı bootstrap bundle (merkez imzalı dosya, cihaz sadece tüketir) | Çevrimiçi token hizmeti gerekmez; imza ile kimlik doğrulama | İmza anahtarı rotasyonu, bundle dağıtım kanalı ve çevrimdışı "eski bundle" riski; geri çekme zor | Bundle sürüm/iptal yönetimi filo çapında iş yükü | Elendi (V1) |
| Paylaşılan kalıcı bootstrap secret | Kurulumu basit | Tek sızıntı tüm filoyu etkiler; cihaz başına iptal imkânsız | Kabul edilemez blast-radius | Elendi |
| Manuel merkezi kayıt | Ek sistem yok | Denetim izi zayıf, insan hatası | 700 kayıt için sürdürülemez | Elendi |

Hiçbir seçenekte **700 cihaza ortak kalıcı secret konmaz**. Karar kaydı: `docs/24` K-17,
alternatif analizi `docs/29` §5.

### 3.1 Çevrimdışı → çevrimiçi geçiş (katılım) mekanizması

Teknisyen tokenı cihaz başına bir kez iletir:

```bash
# İnternet varken anında enrollment (önerilen):
printf '%s\n' '<tek-kullanımlık-token>' | sudo -E bf-enroll --token-stdin

# İnternet yokken: token'ı cihazda bırakmadan boot denemesine hazırla:
printf '%s\n' '<tek-kullanımlık-token>' | sudo -E bf-enroll-now --stage
```

`--stage` gerekçesi: saha cihazı çoğu kez önce çevrimdışı kurulur. İnternet geldiğinde
"kendiliğinden katılma" için tek kullanımlık token'ın cihazda **sınırlı ömürlü** bir
bekleme dosyasında durması gerekir. Uygulanan sınırlar:

- Dosya `<state dir>/enrollment.token`, mod `0600`, sahibi çalıştıran kullanıcı (root),
  TTL `BF_ENROLLMENT_TOKEN_MAX_AGE` (varsayılan 1800 sn, süre sonunda silinir).
- Token argv'ye, state dosyasına, support bundle'a ve kurulum medyasına (USB/ISO) hiç
  yazılmaz; yalnız bu tek dosyada ve yalnız boot denemesi okuyabilir.
- Token başarılı enrollment'ta veya kesin (HTTP 4xx) reddedilmede **hemen** silinir.
  Yalnız geçici hata (DNS/TCP/TLS/zaman aşımı) token'ı sınırlı yeniden deneme için korur.
- Support bundle bu dosyayı toplamaz; `--stage` yalnız root tarafından kullanılabilir.

Bu mekanizma tek kullanımlık token'ın replay engelini değiştirmez: aynı token merkezde
yalnız bir kez tüketilir, `idempotency_key` retry'leri birleştirir.

## 4. Başarısızlık davranışı (reboot loop yok)

1. HTTP isteği başarısız: yaşam döngüsü önceki aşamada kalır (`PENDING` /
   `PROVISIONED_OFFLINE`); hiçbir yapılandırma kurulmaz.
2. Yanıt doğrulaması başarısız: durum dosyası değişmez, geçici dosyalar silinir.
3. WireGuard etkinleştirmesi başarısız: yeni `wg0.conf` geri alınır (öncesi varsa eski
   hali geri yüklenir, yoksa unit devre dışı bırakılır), durum dosyası yazılmaz.
4. Cihaz reboot edilmez: `blueforce-enroll.service` `Restart=on-failure` +
   `RestartSec=5min` + `StartLimitBurst=6` / `StartLimitIntervalSec=1h` ile en fazla
   saati 6 deneme yapar, sonrası `blueforce-enroll.timer` kadansına döner. İnternet yokken
   agresif deneme yapılmaz; internet gelince cihaz kendiliğinden katılır.
5. Token yoksa veya durum `READY`/kurulmamış ise deneme hiçbir iş yapmadan `0` ile çıkar
   (`PENDING` mesajı ile): yeniden deneme fırtınası oluşmaz.

## 5. Araçlar ve aşama kapıları

| Araç / unit | Aşama | Not |
|---|---|---|
| `bf-check-local` | `PROVISIONED_OFFLINE` | İnternet, handshake ve merkez kanıtı **gerekmez**; eksik `wg0.conf` yalnız uyarıdır |
| `bf-enroll` | `PROVISIONED_OFFLINE -> ENROLLED` | Token stdin'den ya da sahnelenmiş dosyadan; `--check` dry-run |
| `bf-check-enrollment` | `ENROLLED` | Merkez kaydı + atanmış peer + canlı tünel + yeni handshake; handshake yokluğu **başarısızlık** |
| `bf-check-ready` | `READY` | Yerel sağlık + tüm merkezi kanallar; kalıcı READY'a güvenmez |
| `bf-enrollment-status` | tümü (salt-okunur) | Sözleşme doğrulayıcı; `INVALID` durumda çıkış kodu ≠ 0 |
| `bf-status` | tümü (salt-okunur) | `Provisioning` / `Enrollment` / `Fleet State` özet bloğu |
| `blueforce-enroll.service` + `blueforce-enroll.timer` | otomatik deneme | Boot +10 dk, sonra günlük; sınırlı `Restart=` |

`blueforce-enrollment.timer` **ayrıca oluşturulmaz**: kurucu modül (`17-healthcheck`) yalnız
`blueforce-enroll.service` ve `blueforce-enroll.timer` dosyalarını cihaza kurar; ikinci bir
timer kurulmadığı için ölü yapılandırma olurdu. Periyodik kadans mevcut timer ve
servisin sınırlı `Restart=` davranışından gelir.

## 6. Doğrulama

```bash
bash tests/test-field-os-lifecycle.sh    # sözleşme, aşama geçişleri, fail-closed davranışı
bash tests/check-provisioning-static.sh  # şema/secret/cihaz-kimliği taraması
```

Şemalar JSON Schema 2020-12'dir ve `bf-enroll`'in gerçek davranışıyla birebir hizalanır
(zorunlu alanlar, `wireguard` alt alanları, `central_verification` biçimi). Endpoint
uygulaması, kimlik doğrulama, imzalama, iptal ve deneme politikası ayrı güvenlik
incelemesi olmadan eklenmeyecektir.
