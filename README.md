# hedefecu.com — yayın deposu

Bu depo **otomatik oluşturulur**: içinde yalnızca hedefecu.com'un derlenmiş (ziyaretçilere sunulan) dosyaları ve
sunucunun kullandığı yayın betiği bulunur. Kaynak kod ayrı ve özel bir depodadır. Elle düzenlemeyin.

- `public/` — sitenin kendisi (sunucuda `public_html`'e kurulur)
- `_ops/deploy.sh` — sunucuda cron ile çalışan yayın betiği (yedek → kurulum → canlı test → gerekirse geri dönüş)
- `_ops/urls.txt` — kurulum sonrası canlı test listesi
- `_ops/enabled` — `1` değilse kurulum yapılmaz
