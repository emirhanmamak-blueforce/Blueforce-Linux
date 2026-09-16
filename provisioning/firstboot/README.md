# First boot — terminal wizard, kimlik koruması ve yarıda kalan kurulum

Bu dizin, cihazın ilk açılışında sahada çalışan giriş noktasını barındırır:

- `bf-firstboot` — bayi numarasını toplayan/doğrulayan ve yerel offline kurucuyu bir kez çalıştıran script.
- `blueforce-firstboot.service` — boot'ta script'i bir kez çalıştıran systemd unit'i.
- Bu doküman — gerçek davranış, otomasyon yolu, kimlik değişimi prosedürü ve secret kuralları.

İlk boot, yalnız Subiquity'nin assisted storage onayıyla tamamlanan kurulumdan ve yeniden başlatmadan sonra çalışır.
Kimlik formatı `^[0-9]{8}$` (`docs/02-DEVICE-NAMING-AND-INVENTORY.md`) ve merkezi durumlar
(`PROVISIONED_OFFLINE` → `ENROLLED` → `READY`, `docs/29-DEVICE-ENROLLMENT.md`) bu adımın dışındadır:
firstboot yalnız offline provision'ı yapar, enrollment ve READY ayrı adımlardır.

## 1. Wizard (teknisyen ekranı)

Konsolda (TTY mevcut ve otomasyon istenmemiş) teknisyen şu ekranı görür:

```text
# BLUEFORCE FIELD OS
8 Haneli Bayi Numarası:
> _
```

Davranış:

- Girdi `^[0-9]{8}$` ile doğrulanır. **Hatalı girdi kabul edilmez**; hata satırı ve `(deneme N/3)` ile yeniden sorulur.
  Yalnız baştaki/sondaki boşluk kırpılır (yapıştırma artığı); değerin içinde boşluk veya rakam dışı karakter varsa geçersiz sayılır.
- 3 hatalı denemeden sonra script net bir hatayla `exit 2` verir ve hiçbir değişiklik yapmaz
  (`BF_FIRSTBOOT_MAX_ATTEMPTS` ile deneme sayısı değiştirilebilir).
- Doğru girdide onay ekranı gösterilir; onay `e`/`evet`/`y`/`yes` ile alınır:

```text
Device ID (cihaz kimliği): BF-<dealer-id>
Hostname (makine adı)   : bf-<dealer-id>
Kurulum bu kimlikle başlatılsın mı? [e/H]:
```

- Onay verilmezse kurulum başlamaz; deneme hakkı tükenirse `exit 2`.
- `read` zaman aşımına uğrarsa (varsayılan 300 sn, `BF_FIRSTBOOT_INPUT_TIMEOUT`) script
  "no terminal input arrived" hatasıyla `exit 2` verir; konsolda kimse olmadığında sonsuza kadar bloklamaz.

TTY seçimi: stdin zaten bir terminal ise (systemd `StandardInput=tty-force` durumu) fd 0 kullanılır;
değilse `/dev/tty` açılır; o da açılamıyorsa wizard atlanır ve argüman/dosya yoluna düşülür.

## 2. Kimlik çözümleme sırası

| # | Kaynak | Mod |
|---|---|---|
| 1 | `--dealer-id <8hane>` | non-interactive (otomasyon) |
| 2 | `--dealer-id-file <yol>` | non-interactive (otomasyon) |
| 3 | `--interactive` | wizard (TTY zorunlu) |
| 4 | `BF_FIRSTBOOT_NONINTERACTIVE=1` | non-interactive; seed dosyası (`/etc/blueforce/dealer-id`) okunur |
| 5 | Seed dosyası `/etc/blueforce/dealer-id` geçerliyse | non-interactive; wizard atlanır (log satırı yazılır) |
| 6 | TTY mevcut | wizard |
| 7 | Hiçbiri | net hata + `exit 2` (argüman/dosya önerilir) |

Otomasyon yolu (1, 2, 4) hiçbir soru sormaz: seed/USB ile kurulan cihazda teknisyen girdisi gerekmez.
1. ve 2. maddeler açıkça verildiği için onay ekranı çıkmaz; bu bilinçli bir otomasyon kapısıdır.

### Komut arayüzü

```bash
sudo bf-firstboot                                   # wizard (konsol)
sudo bf-firstboot --dealer-id <8hane>               # otomasyon
sudo bf-firstboot --dealer-id-file /path/to/dealer-id
sudo bf-firstboot --check --dealer-id <8hane>       # salt-okunur denetim
sudo bf-firstboot --interactive                     # seed dosyası olsa bile wizard
BF_FIRSTBOOT_NONINTERACTIVE=1 sudo bf-firstboot     # boot/otomasyon
```

Ortam değişkenleri: `BF_FIRSTBOOT_MARKER` (marker yolu), `STATE_DIR` (varsayılan `/var/lib/blueforce`),
`BF_INSTALLER_PATH` (kurucu yolu), `BF_ADMIN_PUBLIC_KEY_FILE`, `BF_FIRSTBOOT_MAX_ATTEMPTS`,
`BF_FIRSTBOOT_INPUT_TIMEOUT`, `BF_FIRSTBOOT_TEST_MODE`, `BF_FIRSTBOOT_NONINTERACTIVE`.

### Çıkış kodları

| Kod | Anlam |
|---|---|
| 0 | Kurulum tamam (marker yazıldı) veya zaten tamamlanmış (idempotent) veya `--check` raporu |
| 1 | Offline önkoşul eksik (admin public key), root yok, kurucu yok, veya kurucu hata verdi |
| 2 | Girdi hatası: geçersiz bayi numarası, terminal yok, onay verilmedi, deneme tükendi |

## 3. İdempotentlik ve yarıda kalan kurulum

- Marker: `/var/lib/blueforce/firstboot-complete` (mode `600`, içinde bayi numarası).
- Marker varsa script **hiçbir şey yapmaz**: sormaz, yazmaz, kurucuyu çağırmaz, `exit 0`. Wizard bu durumda asla açılmaz.
- Marker varken farklı bir bayi numarası verilirse identity değişmez; yalnız uyarı yazılır ve admin prosedürüne
  (§4) işaret edilir. Sıradan kullanıcı yoluyla kimlik değiştirilemez.
- Marker yalnız kurucu başarıyla bittikten sonra yazılır (`set -euo pipefail` sayesinde hata hâlinde yazılmaz).
- Önceki koşu yarıda kaldıysa (`$STATE_DIR/install-state` dolu) kurucu `--resume` ile çağrılır:
  kurucu `--offline --dealer-id <no> --yes` (+ gerekirse `--resume`) argümanlarıyla koşar.
- Script her zaman kurucuyu `--offline` ile çağırır; kurucu `PROVISIONED_OFFLINE` durumuna tamamlar.
- `--check` hiçbir dosya/dizin/log üretmez ve kurucuyu çağırmaz.

## 4. Kimlik değişimi prosedürü (admin / recovery — varsayılan KAPALI)

Bayi numarası değişimi **sıradan kullanıcı yolu değildir**. Wizard ve normal koşu bu yolu içermez.
Yalnız root + açık operatör kapısı + yazılı onay + audit kaydı ile çalışır:

1. Fiziksel konsolda root oturumu açılır ve operatör kapısı açıkça verilir: `BF_ALLOW_REIDENTITY=1`.
2. Komut: `BF_ALLOW_REIDENTITY=1 sudo -E bf-firstboot --force-reidentity --dealer-id <yeni-no>`.
3. Ekranda eski/yeni kimlik ve "dokuz merkezi sistem güncellenmeli" uyarısı gösterilir.
4. Onay, **yeni bayi numarasının yeniden yazılması** ile alınır; eşleşmezse hiçbir değişiklik yapılmaz (`exit 2`).
5. Kurucu yeni kimlikle koşar, eski marker `firstboot-complete.reidentified-<UTC>` olarak saklanır,
   yeni marker yazılır.
6. Her adım `/var/log/blueforce-reidentity.log` (mode `600`, UTC zaman + `uid=`) ve journal'a yazılır:
   kim, ne zaman, eski → yeni. Audit log yazılamıyorsa değişim **reddedilir** (fail-closed).

Kapılar: root değilse `exit 1`; `BF_ALLOW_REIDENTITY=1` yoksa `exit 1`; TTY yoksa `exit 2`.
Değişimden sonra `docs/02-DEVICE-NAMING-AND-INVENTORY.md` §9'daki yeniden-numaralandırma adımları
(WireGuard peer, RustDesk/MeshCentral etiketi, Ansible inventory, monitoring etiketi) uygulanır.

## 5. Secret kuralları

- `BF_ADMIN_PUBLIC_KEY_FILE` **yalnız public SSH key** içerebilir; root sahipliğinde ve grup/dünya
  tarafından yazılamaz olmalıdır (`root:600` veya `root:640`). Private key, inline anahtar veya
  boş/okunamayan dosya `OFFLINE BLOCKED` ile reddedilir.
- Bu kural değiştirilmedi: dosya `ssh-ed25519`/`ssh-rsa`/`ssh-ecdsa`/`sk-ssh-ed25519` public key satırı
  ile başlamalı ve `PRIVATE KEY` içermemelidir.
- Script secret **loglamaz**: mesajlarda yalnız dosya yolları ve cihaz kimlikleri geçer; anahtar içeriği,
  token, parola hiçbir satıra yazılmaz (`--force-reidentity` audit kaydı da yalnız kimlikleri yazar).
- Wizard girdisi ekrana yankılanır (teknisyen yazar); bu ekran token/parola istemez, yalnız bayi numarası alır.
- ISO'da geçerli yerel APT indeksleri, checksum/lock ve tüm somut pinli paketler yoksa işlem
  `OFFLINE BLOCKED` ile durur ve cihaz provision edilmiş sayılmaz. Yalnız offline bundle + public-key
  önkoşulları geçerse `PROVISIONED_OFFLINE` yazılır.

## 6. systemd unit ve boot'u kilitlememe

`blueforce-firstboot.service`:

- `ConditionPathExists=/etc/blueforce/admin-authorized-key.pub` — zorunlu seed önkoşulu yoksa unit hiç başlamaz.
- `ConditionPathExists=!/var/lib/blueforce/firstboot-complete` — provision edilmiş cihazda atlanır (başarısız sayılmaz).
- `StandardInput=tty-force` + `TTYPath=/dev/tty1` — wizard sahada konsolda görünür.
- TTY kurulamazsa (konsolsuz/headless sistem) systemd unit'i başarısız sayar, **boot devam eder**;
  script de TTY yoksa argüman/dosya yoluna düşer.
- `TimeoutStartSec=45min` — konsolda kimse yoksa job sonsuza kadar açık kalmaz.
- `Type=oneshot`, `RemainAfterExit=yes`, `WantedBy=multi-user.target` — boot'ta bir kez çalışır.
- `NoNewPrivileges=yes`, `PrivateTmp=yes` korunur. `ProtectSystem=strict` ve `ProtectHome=yes`
  **bilinçli olarak yoktur**: offline kurucu `/etc`, `/usr` ve `/home/blueforce` altına yazar.

Not: unit çıktısı konsol TTY'sine gider; aynı satırlar `logger -t bf-firstboot` ile journal'a da yazılır,
kurucu kendi logunu `/var/log/blueforce-install.log` içinde tutar.

## 7. Test

```bash
bash tests/test-firstboot-static.sh
```

Statik test, gerçek systemd/apt işlemi yapmadan şunları doğrular: bayi numarası regex'i, hatalı girdinin
reddi, wizard ekranı ve onay akışı (pty ile), marker idempotentliği, kimlik değişiminin kapalı olması,
public-key önkoşulu ve secret sızıntısı olmadığı, `--check` ve `BF_FIRSTBOOT_TEST_MODE` modlarının
mutasyonsuzluğu. Root gerektiren senaryolar `unshare -r` ile ayrı bir kullanıcı ad alanında koşar;
bu izin yoksa ilgili testler `SKIP` olarak raporlanır.
