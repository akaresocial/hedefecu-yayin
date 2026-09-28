#!/bin/bash
# hedefecu.com — sunucu tarafı otomatik yayın (Alastyr cPanel, cron ile 2 dakikada bir).
#
# Akış: açık yayın deposundaki (akaresocial/hedefecu-yayin) main dalının son commit'ini kontrol et →
# yeni sürüm varsa indir, doğrula → public_html'in anlık yedeğini al → yer değiştirerek kur → canlı siteyi test et →
# test başarısızsa yedeğe geri dön.
#
# Hiçbir şifre/anahtar kullanmaz (depo herkese açık; içinde yalnız derlenmiş site vardır).
# Korunan yollar (asla taşınmaz/silinmez): /.well-known/ /eskisite/ /public_ftp/ /cgi-bin/ /wp-content/uploads/ /.user.ini /php.ini
# ve arama motoru doğrulama dosyaları (google*.html, yandex_*.html, BingSiteAuth.xml). /eskisite/ .htaccess ile erişime kapalıdır.
# Kurulum rsync KULLANMAZ (sunucuda yok): eski girdiler anlık yedeğe taşınır, yenileri içeri taşınır (aynı dosya sistemi → rename).
#
# Güvenlik kapısı: depodaki _ops/enabled dosyası "1" değilse yalnız yedek + kontrol yapılır, kurulum yapılmaz.
set -u
umask 022

REPO="${REPO:-akaresocial/hedefecu-yayin}"
BRANCH="main"
SITE_URL="${SITE_URL:-https://hedefecu.com}"
WEBROOT="${WEBROOT:-$HOME/public_html}"
OPS="${OPS:-$HOME/hedefecu-ops}"
BACKUPS="${BACKUPS:-$HOME/yedekler}"
KEEP=3

mkdir -p "$OPS/releases" "$OPS/snapshots" "$BACKUPS"
LOG_MAX=1048576
[ -f "$OPS/deploy.log" ] && [ "$(wc -c < "$OPS/deploy.log")" -gt "$LOG_MAX" ] && tail -c 262144 "$OPS/deploy.log" > "$OPS/deploy.log.tmp" && mv "$OPS/deploy.log.tmp" "$OPS/deploy.log"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(ts)] $*"; }
status() { printf '{"time":"%s","state":"%s","sha":"%s","note":"%s"}\n' "$(ts)" "$1" "${2:-}" "${3:-}" > "$OPS/status.json"; }

# Tek örnek (üst üste binen cron çalışmalarını engelle)
exec 9> "$OPS/.lock"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
else
  if ! mkdir "$OPS/.lockdir" 2>/dev/null; then
    # 15 dakikadan eski ölü kilidi temizle
    if [ -n "$(find "$OPS/.lockdir" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then rmdir "$OPS/.lockdir"; mkdir "$OPS/.lockdir" || exit 0; else exit 0; fi
  fi
  trap 'rmdir "$OPS/.lockdir" 2>/dev/null' EXIT
fi

# ---------------------------------------------------------------- araç kontrolü (ilk çalışmada günlüğe yazılır)
if [ ! -f "$OPS/.doctor" ]; then
  {
    log "doctor: bash=$BASH_VERSION"
    for t in curl tar gzip rsync git flock sha256sum mysqldump find cp; do
      if command -v "$t" >/dev/null 2>&1; then log "doctor: $t=$(command -v "$t")"; else log "doctor: $t=YOK"; fi
    done
    log "doctor: disk=$(du -sh "$HOME" 2>/dev/null | cut -f1) public_html=$(du -sh "$WEBROOT" 2>/dev/null | cut -f1)"
  }
  touch "$OPS/.doctor"
fi

# ---------------------------------------------------------------- ilk çalışma: WordPress'in tam yedeği (bir kez)
if [ ! -f "$BACKUPS/.wp-ok" ] && [ -f "$WEBROOT/wp-config.php" ]; then
  stamp=$(date '+%Y%m%d-%H%M%S')
  log "yedek: public_html arşivleniyor → $BACKUPS/wp-public_html-$stamp.tar.gz"
  if tar -czf "$BACKUPS/wp-public_html-$stamp.tar.gz" -C "$(dirname "$WEBROOT")" "$(basename "$WEBROOT")"; then
    wpc="$WEBROOT/wp-config.php"
    getv() { sed -n "s/^[[:space:]]*define([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*['\"]\(.*\)['\"][[:space:]]*);.*/\1/p" "$wpc" | head -1; }
    DBN=$(getv DB_NAME); DBU=$(getv DB_USER); DBP=$(getv DB_PASSWORD); DBH=$(getv DB_HOST)
    if [ -n "$DBN" ] && command -v mysqldump >/dev/null 2>&1; then
      if MYSQL_PWD="$DBP" mysqldump -h "${DBH:-localhost}" -u "$DBU" --single-transaction --no-tablespaces "$DBN" | gzip > "$BACKUPS/wp-db-$stamp.sql.gz"; then
        log "yedek: veritabanı → $BACKUPS/wp-db-$stamp.sql.gz ($(du -h "$BACKUPS/wp-db-$stamp.sql.gz" | cut -f1))"
      else
        log "yedek: UYARI veritabanı dökümü başarısız (dosya yedeği tamam; veritabanına zaten dokunulmuyor)"
      fi
    fi
    touch "$BACKUPS/.wp-ok"
    log "yedek: tamam ($(du -h "$BACKUPS/wp-public_html-$stamp.tar.gz" | cut -f1))"
  else
    log "yedek: HATA — arşiv oluşturulamadı; güvenlik için kurulum yapılmayacak"
    status "backup-failed"
    exit 1
  fi
fi

# ---------------------------------------------------------------- uzak sürüm
remote_sha="${TEST_SHA:-}"
if [ -z "$remote_sha" ] && command -v git >/dev/null 2>&1; then
  remote_sha=$(git ls-remote "https://github.com/$REPO.git" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)
fi
if [ -z "$remote_sha" ]; then
  remote_sha=$(curl -fsS --max-time 20 "https://api.github.com/repos/$REPO/commits/$BRANCH" -H 'Accept: application/vnd.github.sha' 2>/dev/null | tr -dc '0-9a-f' | head -c 40)
fi
if [ ${#remote_sha} -ne 40 ]; then
  log "uzak: sürüm okunamadı (ağ/GitHub); sonraki çalışmada tekrar"
  exit 0
fi

current_sha=$(cat "$OPS/current_sha" 2>/dev/null || true)
[ "$remote_sha" = "$current_sha" ] && exit 0
if grep -qx "$remote_sha" "$OPS/bad_shas" 2>/dev/null; then exit 0; fi

log "yeni sürüm: $remote_sha (canlı: ${current_sha:-yok})"
rel="$OPS/releases/$remote_sha"
if [ ! -d "$rel/public" ] && [ -n "${TEST_RELEASE_DIR:-}" ]; then
  cp -a "$TEST_RELEASE_DIR" "$rel"
fi
if [ ! -d "$rel/public" ]; then
  rm -rf "$rel.tmp" && mkdir -p "$rel.tmp"
  if ! curl -fsSL --max-time 180 "https://codeload.github.com/$REPO/tar.gz/$remote_sha" | tar -xz -C "$rel.tmp" --strip-components=1; then
    log "indirme: HATA"; rm -rf "$rel.tmp"; exit 0
  fi
  mv "$rel.tmp" "$rel"
fi

# ---------------------------------------------------------------- doğrulama
fail() { log "doğrulama: HATA — $*"; echo "$remote_sha" >> "$OPS/bad_shas"; status "invalid" "$remote_sha" "$*"; exit 1; }
[ -f "$rel/public/index.html" ] || fail "index.html yok"
[ -f "$rel/public/.htaccess" ] || fail ".htaccess yok"
[ -f "$rel/public/sitemap.xml" ] || fail "sitemap.xml yok"
[ -f "$rel/public/404.html" ] || fail "404.html yok"
rid=$(tr -dc '0-9a-f' < "$rel/_ops/release-id" 2>/dev/null)
[ ${#rid} -ge 8 ] || fail "_ops/release-id yok"
grep -q "^$rid" "$rel/public/version.txt" 2>/dev/null || fail "version.txt yayın kimliğiyle uyuşmuyor"
nfiles=$(find "$rel/public" -type f | wc -l)
[ "$nfiles" -ge 100 ] || fail "dosya sayısı çok az ($nfiles)"
bad_exec=$(find "$rel/public" -type f \( -iname '*.php' -o -iname '*.php[0-9]' -o -iname '*.phtml' -o -iname '*.phar' -o -iname '*.cgi' -o -iname '*.pl' -o -iname '*.py' -o -iname '*.sh' \) | head -3)
[ -z "$bad_exec" ] || fail "yayında çalıştırılabilir dosya var: $bad_exec"
if grep -RIEiq '^[[:space:]]*(AddHandler|SetHandler|Action|ScriptAlias|php_value|php_flag|AddType[^#]*php)' --include=.htaccess "$rel/public"; then
  fail ".htaccess içinde betik çalıştırma yönergesi var"
fi
if [ -f "$rel/_ops/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
  (cd "$rel/public" && sha256sum --quiet -c "../_ops/SHA256SUMS") || fail "sağlama toplamı uyuşmuyor"
fi

# Betik kendini depodan GÜNCELLEMEZ (depoya yazabilen biri sunucuda kod çalıştıramasın). Depodaki sürüm farklıysa
# yalnız günlüğe yazılır; güncelleme için cPanel Dosya Yöneticisi'nden ~/hedefecu-ops/deploy.sh silinir → cron yeniden indirir.
if [ -f "$rel/_ops/deploy.sh" ] && ! cmp -s "$rel/_ops/deploy.sh" "$OPS/deploy.sh" 2>/dev/null; then
  log "betik: depodaki deploy.sh farklı — otomatik güncellenmedi"
fi

# güvenlik kapısı
if [ "$(tr -dc '0-9' < "$rel/_ops/enabled" 2>/dev/null)" != "1" ]; then
  log "kapı: _ops/enabled != 1 — kurulum yapılmadı (yalnız indirildi ve doğrulandı)"
  status "gated" "$remote_sha"
  exit 0
fi

# ---------------------------------------------------------------- kurulum (rsync yok → yer değiştirme; saniyenin altında)
# Korunan girdiler public_html'de yerinde kalır; wp-content içinde yalnız uploads korunur (eski /wardofit/ görselleri).
PRESERVE=" .well-known eskisite public_ftp cgi-bin .user.ini php.ini wp-content "
is_preserved() {
  case "$PRESERVE" in *" $1 "*) return 0 ;; esac
  # Search Console / Yandex / Bing doğrulama dosyaları
  [[ "$1" =~ ^(google[0-9a-f]+\.html|yandex_[0-9a-f]+\.html|BingSiteAuth\.xml)$ ]] && return 0
  return 1
}

stage="$OPS/stage-$rid"
rm -rf "$stage" && mkdir -p "$stage"
cp -a "$rel/public/." "$stage/" || { log "hazırlık: HATA"; status "stage-failed" "$remote_sha"; exit 1; }
snap="$OPS/snapshots/$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$snap/_wpc" && : > "$snap/.moved-out" && : > "$snap/.moved-in" && : > "$snap/.wpc-moved-out"

rollback() {
  local fail_dir="$OPS/failed-$(date '+%Y%m%d-%H%M%S')"; mkdir -p "$fail_dir"
  while IFS= read -r e; do [ -n "$e" ] && { [ -e "$WEBROOT/$e" ] || [ -L "$WEBROOT/$e" ]; } && mv "$WEBROOT/$e" "$fail_dir/$e"; done < "$snap/.moved-in"
  while IFS= read -r e; do [ -n "$e" ] && { [ -e "$snap/$e" ] || [ -L "$snap/$e" ]; } && mv "$snap/$e" "$WEBROOT/$e"; done < "$snap/.moved-out"
  while IFS= read -r c; do [ -n "$c" ] && [ -e "$snap/_wpc/$c" ] && mv "$snap/_wpc/$c" "$WEBROOT/wp-content/$c"; done < "$snap/.wpc-moved-out"
  log "geri dönüş: eski dosyalar yerine kondu; başarısız sürüm → $fail_dir"
}

# 1) eski girdileri anlık yedeğe taşı (korunanlar hariç)
for p in "$WEBROOT"/* "$WEBROOT"/.[!.]* "$WEBROOT"/..?*; do
  { [ -e "$p" ] || [ -L "$p" ]; } || continue
  e=${p##*/}
  is_preserved "$e" && continue
  mv "$p" "$snap/$e" && echo "$e" >> "$snap/.moved-out" || { log "taşıma: HATA ($e)"; rollback; status "rolled-back" "$remote_sha" "move-out"; exit 1; }
done
if [ -d "$WEBROOT/wp-content" ]; then
  for p in "$WEBROOT"/wp-content/* "$WEBROOT"/wp-content/.[!.]*; do
    { [ -e "$p" ] || [ -L "$p" ]; } || continue
    c=${p##*/}; [ "$c" = "uploads" ] && continue
    mv "$p" "$snap/_wpc/$c" && echo "$c" >> "$snap/.wpc-moved-out"
  done
fi
# 2) yeni girdileri içeri al
for p in "$stage"/* "$stage"/.[!.]*; do
  { [ -e "$p" ] || [ -L "$p" ]; } || continue
  e=${p##*/}
  if is_preserved "$e"; then log "uyarı: yayında korunan ad ($e) — atlandı"; continue; fi
  mv "$p" "$WEBROOT/$e" && echo "$e" >> "$snap/.moved-in" || { log "taşıma: HATA ($e)"; rollback; status "rolled-back" "$remote_sha" "move-in"; exit 1; }
done
rm -rf "$stage"
log "kuruldu: $remote_sha / $rid ($nfiles dosya; anlık yedek $snap)"

# ---------------------------------------------------------------- canlı test
sleep 3
bad=0; checked=0
urls="$rel/_ops/urls.txt"
if [ -f "$urls" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    path=$(echo "$line" | awk '{print $1}'); want=$(echo "$line" | awk '{print $2}'); loc=$(echo "$line" | awk '{print $3}')
    out=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 -H 'Cache-Control: no-cache' "$SITE_URL$path")
    code=${out%% *}; got=${out#* }
    checked=$((checked+1))
    if [ "$code" != "$want" ]; then bad=$((bad+1)); log "test: HATA $path → $code (beklenen $want)"; continue; fi
    if [ -n "$loc" ] && [ "$got" != "$SITE_URL$loc" ]; then bad=$((bad+1)); log "test: HATA $path → $got (beklenen $SITE_URL$loc)"; fi
  done < "$urls"
fi
live=$(curl -fsS --max-time 20 -H 'Cache-Control: no-cache' "$SITE_URL/version.txt" 2>/dev/null | head -1)
case "$live" in "$rid"*) : ;; *) bad=$((bad+1)); log "test: HATA version.txt canlıda '$live' (beklenen $rid)" ;; esac

if [ "$bad" -gt 0 ]; then
  log "test: $bad/$checked hata — GERİ DÖNÜLÜYOR"
  rollback
  echo "$remote_sha" >> "$OPS/bad_shas"
  status "rolled-back" "$remote_sha" "$bad hata"
  exit 1
fi

echo "$remote_sha" > "$OPS/current_sha"
status "live" "$remote_sha" "$checked test geçti"
log "test: $checked/$checked geçti — CANLI"

# ---------------------------------------------------------------- temizlik (son $KEEP sürüm ve anlık yedek; WordPress tam yedeği kalıcı)
ls -1dt "$OPS"/releases/*/ 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -rf
ls -1dt "$OPS"/snapshots/*/ 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -rf
ls -1dt "$OPS"/failed-*/ 2>/dev/null | tail -n +3 | xargs -r rm -rf
exit 0
