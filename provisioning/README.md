# Blueforce OS provisioning

Bu dizin işletim sistemi provisioning kapsamının sahibidir. Mevcut `scripts/install/` uygulama bootstrap'ı olarak kalır ve burada taşınmaz.

Güvenlik sınırları:

- Bu iskelet cihaz kimliği, parola, private key, token veya bayiye özel veri içermez.
- Autoinstall V1 disk seçmez ve silmez; `interactive-sections: [storage]` teknisyen seçimini zorunlu tutar.
- Upstream ISO ve paketler örtük indirilmez. Her ISO işleminden önce açık SHA256 doğrulaması gerekir.
- Remaster araçları `xorriso` yoksa veya boot metadatası desteklenmiyorsa başarısız olur.
- Firstboot sadece sekiz haneli bayi numarası biçimini denetler; kurucu veya enrollment çağrısı yapmaz.

Kontrol:

```bash
tests/check-provisioning-static.sh
```

LAB doğrulaması, hedef Ubuntu sürümü, boot menüsü entegrasyonu, gerçek identity storage ve enrollment taşıma güvenliği sonraki fazların açık işleridir.