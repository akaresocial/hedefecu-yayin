#!/bin/bash
# hedefecu.com — sunucu tarafı otomatik yayın (Alastyr cPanel, cron ile 2 dakikada bir).
#
# Akış: açık yayın deposundaki (akaresocial/hedefecu-yayin) main dalının son commit'ini kontrol et →
# yeni sürüm varsa indir, doğrula → public_html'in anlık yedeğini al → rsync ile kur → canlı siteyi test et →
# test başarısızsa yedeğe geri dön.
#
# Hiçbir şifre/anahtar kullanmaz (depo herkese açık; içinde yalnız derlenmiş site vardır).
# Korunan yollar (asla silinmez): /.well-known/ /eskisite/ /public_ftp/ /cgi-bin/ /wp-content/uploads/ /.user.ini /php.ini
#
# Güvenlik kapısı: depodaki _ops/enabled dosyası "1" değilse yalnız yedek + kontrol yapılır, kurulum yapılmaz.
set -u
umask 022

REPO="akaresocial/hedefecu-yayin"
BRANCH="main"
SITE_URL="https://hedefecu.com"
WEBROOT="$HOME/public_html"
OPS="$HOME/hedefecu-ops"
BACKUPS="$HOME/yedekler"
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
  if tar -czf "$BACKUPS/wp-public_html-$stamp.tar.gz" -C "$HOME" public_html; then
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
remote_sha=""
if command -v git >/dev/null 2>&1; then
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
grep -q "$remote_sha" "$rel/public/version.txt" 2>/dev/null || true
nfiles=$(find "$rel/public" -type f | wc -l)
[ "$nfiles" -ge 100 ] || fail "dosya sayısı çok az ($nfiles)"
if [ -f "$rel/_ops/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
  (cd "$rel/public" && sha256sum --quiet -c "../_ops/SHA256SUMS") || fail "sağlama toplamı uyuşmuyor"
fi

# yayın betiğinin kendisini güncelle (bir sonraki çalışmada geçerli)
if [ -f "$rel/_ops/deploy.sh" ] && ! cmp -s "$rel/_ops/deploy.sh" "$OPS/deploy.sh"; then
  if bash -n "$rel/_ops/deploy.sh"; then cp "$rel/_ops/deploy.sh" "$OPS/deploy.sh.new" && mv "$OPS/deploy.sh.new" "$OPS/deploy.sh"; log "betik: güncellendi"; fi
fi

# güvenlik kapısı
if [ "$(tr -dc '0-9' < "$rel/_ops/enabled" 2>/dev/null)" != "1" ]; then
  log "kapı: _ops/enabled != 1 — kurulum yapılmadı (yalnız indirildi ve doğrulandı)"
  status "gated" "$remote_sha"
  exit 0
fi

# ---------------------------------------------------------------- kurulum
EXCLUDES=(--exclude=/.well-known/ --exclude=/eskisite/ --exclude=/public_ftp/ --exclude=/cgi-bin/ --exclude=/wp-content/uploads/ --exclude=/.user.ini --exclude=/php.ini)
snap="$OPS/snapshots/$(date '+%Y%m%d-%H%M%S')"
cp -al "$WEBROOT" "$snap" 2>/dev/null || cp -a "$WEBROOT" "$snap" || { log "anlık yedek: HATA"; status "snapshot-failed" "$remote_sha"; exit 1; }
log "anlık yedek: $snap"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete-delay --delay-updates "${EXCLUDES[@]}" "$rel/public/" "$WEBROOT/" || { log "rsync: HATA — geri dönülüyor"; rsync -a --delete "${EXCLUDES[@]}" "$snap/" "$WEBROOT/"; echo "$remote_sha" >> "$OPS/bad_shas"; status "rolled-back" "$remote_sha" "rsync"; exit 1; }
else
  log "rsync yok — kurulum yapılamaz"; status "no-rsync" "$remote_sha"; exit 1
fi
log "kuruldu: $remote_sha ($nfiles dosya)"

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
case "$live" in *"$remote_sha"*) : ;; *) bad=$((bad+1)); log "test: HATA version.txt canlıda '$live'" ;; esac

if [ "$bad" -gt 0 ]; then
  log "test: $bad/$checked hata — GERİ DÖNÜLÜYOR"
  rsync -a --delete "${EXCLUDES[@]}" "$snap/" "$WEBROOT/"
  echo "$remote_sha" >> "$OPS/bad_shas"
  status "rolled-back" "$remote_sha" "$bad hata"
  log "geri dönüş: tamam ($snap)"
  exit 1
fi

echo "$remote_sha" > "$OPS/current_sha"
status "live" "$remote_sha" "$checked test geçti"
log "test: $checked/$checked geçti — CANLI"

# ---------------------------------------------------------------- temizlik (son $KEEP sürüm ve anlık yedek; WordPress tam yedeği kalıcı)
ls -1dt "$OPS"/releases/*/ 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -rf
ls -1dt "$OPS"/snapshots/*/ 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -rf
exit 0
