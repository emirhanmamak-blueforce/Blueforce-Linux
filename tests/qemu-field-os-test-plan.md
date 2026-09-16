# Field OS QEMU/KVM ve LAB Test Planı

Bu plan, mevcut `provisioning/iso/test-iso.sh` aracını değiştirmez. Araç checksum ve El Torito metadata doğrulaması yapar; QEMU/KVM önyükleme ve gerçek çevre birimi kabulü ayrı kanıttır.

## Çalıştırma sınırları

- CI yalnız statik doğrulama çalıştırır: `tests/check-provisioning-static.sh` ve `tests/check-migration-static.sh`. CI disk yazmaz, ISO boot etmez, QEMU/KVM veya PowerShell gerektirmez.
- QEMU/KVM testleri imzalı artefact ile izole LAB hostunda çalışır. Kurulum hedefi yalnız geçici QCOW2 disktir; fiziksel disk veya üretim ağı kullanılmaz.
- Fiziksel LAB testleri iki temsilci cihazda yapılır. USB/seri/MEG, Secure Boot ve Windows image restore yalnız burada kabul edilir.
- Her T1–T18 sonucu release manifesti, ISO/seed checksum ve kullanılan test ortamıyla kaydedilir. Başarısız test artefact'ın saha dağıtımını engeller.

## Test matrisi

| ID | Doğrulama | Ortam | Beklenen kanıt |
|---|---|---|---|
| T1 | Upstream ISO SHA256 doğrulaması | CI statik + LAB | `verify-upstream-iso.sh --check` başarılı |
| T2 | El Torito boot metadata | CI (xorriso varsa) + LAB | `test-iso.sh` başarılı; yoksa fail-closed |
| T3 | Seed yapısal doğrulaması | CI statik | NoCloud `user-data`/`meta-data` ve YAML parse başarılı |
| T4 | Secret ve bayi kimliği taraması | CI statik | provisioning ve migration asset'lerinde secret/kimlik yok |
| T5 | Autoinstall depolama kapısı | CI statik | storage seçimi interaktif, doğrudan wipe yok |
| T6 | UEFI QEMU boot | QEMU/KVM | OVMF ile kurulum menüsü ve seed algılandı |
| T7 | Legacy BIOS QEMU boot | QEMU/KVM | SeaBIOS ile kurulum menüsü ve seed algılandı |
| T8 | Secure Boot | Fiziksel LAB | desteklenen cihazda imzalı upstream yol boot eder |
| T9 | Geçici QCOW2 temiz kurulum | QEMU/KVM | yalnız QCOW2 değişti; sistem `PROVISIONED_OFFLINE` |
| T10 | Air-gapped kurulum | QEMU/KVM | WAN/DNS kapalıyken dış indirme yok |
| T11 | Offline APT manifesti | QEMU/KVM | paketler onaylı snapshot'tan çözülür |
| T12 | İlk açılış durum kapısı | QEMU/KVM | `READY` değil, `PROVISIONED_OFFLINE` görünür |
| T13 | NIC sürücüsü ve bağlantı | QEMU/KVM + fiziksel LAB | arayüz bulunur; fiziksel cihazda link/DHCP kabulü |
| T14 | Disk eşik ve yanlış-disk koruması | QEMU/KVM | 64 GiB altı disk BLOCKED; hedef onayı görünür |
| T15 | RAM ve mimari eşikleri | QEMU/KVM | x86_64/4 GiB temel kabul; alt eşik verdict'i doğru |
| T16 | USB çevre birimi | Fiziksel LAB | USB cihaz envanteri ve MEG kabul senaryosu başarılı |
| T17 | Seri çevre birimi | Fiziksel LAB | tty cihazı ve MEG seri iş akışı başarılı |
| T18 | Windows geri dönüş provası | Fiziksel LAB | hash doğrulanmış image restore sonrası iş akışı gelir |

## QEMU/KVM örnek disiplin

QEMU çağrısı release kaydında saklanır; yalnız geçici dosya kullanılır. Örnek hedef: `mktemp -d` altında QCOW2, OVMF değişken kopyası ve host-only ağ. Komut çalıştırılmadan önce ISO checksum, seed checksum ve disk yolunun geçici dizin altında olduğu doğrulanır. Test bitince QCOW2 yalnız LAB saklama politikasına göre imha edilir.

## Çıkış kriteri

T1–T5 CI statik olarak yeşil olmadan QEMU/KVM başlatılmaz. T6–T15 tamamlanmadan custom ISO saha artefact'ı olmaz. T16–T18 fiziksel LAB kanıtı olmadan cihaz profili veya Windows geçişi kabul edilmez.
