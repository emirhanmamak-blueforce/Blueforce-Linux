# Release metadata

`manifest.yaml` iskelet sürüm sözleşmesidir. Gerçek ISO üretimi `iso/build-blueforce-iso.sh` tarafından ayrıca bir `release-manifest.yaml` ve `SHA256SUMS` dosyasıyla kayıt altına alınır.

Yayın girdileri açıkça verilmelidir: doğrulanmış upstream ISO, onun SHA256 kaydı ve gözden geçirilmiş yerel içerikler. Bu repo paket veya ISO indirmez. `status: skeleton` olan bu dosya dağıtım onayı değildir.