<?php
// hedefecu.com — ANLIK YAYIN (https://tetik.hedefecu.com/)
//
// Neden PHP: sunucuda (Alastyr, LiteSpeed + PHP 8.3) exec/shell_exec/proc_open/popen/escapeshellarg… kapalı; PHP deploy.sh'i
// başlatamaz. Bu dosya ops/deploy.sh'in AYNI adımlarını saf PHP ile yapar:
//   main'in son commit'i → indir → doğrula → anlık yedek → yer değiştirerek kur → canlı test → hata olursa geri dön.
// deploy.sh ile aynı kilidi (~/hedefecu-ops/.lock, flock) ve aynı durum dosyalarını (current_sha, bad_shas, status.json,
// deploy.log, releases/, snapshots/) kullanır → 15 dakikalık cron ile çakışmaz; hangisi önce görürse o kurar.
//
//   GET /          → hemen {"durum":"tetiklendi"} döner, bağlantı kapanır, yayın arka planda sürer (20 sn'de bir çağrılabilir)
//   GET /?durum=1  → yalnız okur: son yayın durumu (status.json), canlı sürüm, çalışan yayın var mı
//
// Şifre/anahtar kullanmaz. Depodan kod çalıştırmaz: yayında .php/.cgi…, sembolik bağ ya da .htaccess içinde betik yönergesi
// varsa sürüm reddedilir. Kendini güncellemez. İki betik birlikte değişir: ops/deploy.sh ↔ ops/tetik/index.php;
// ikisi de ops/test/deploy-test.sh ile aynı senaryolardan geçmeli.

$CLI = PHP_SAPI === 'cli';
// Yerel deneme için ortam değişkenleri YALNIZ komut satırında okunur (web isteği hiçbir ayarı değiştiremez)
function ayar($k, $d) { global $CLI; $v = $CLI ? getenv($k) : false; return ($v === false || $v === '') ? $d : $v; }
$HOME_DIR = ayar('HOME_DIR', '/home/hedefecu');
$REPO = 'akaresocial/hedefecu-yayin';
$BRANCH = 'main';
$SITE_URL = ayar('SITE_URL', 'https://hedefecu.com');
$WEBROOT = ayar('WEBROOT', "$HOME_DIR/public_html");
$OPS = ayar('OPS', "$HOME_DIR/hedefecu-ops");
$BACKUPS = ayar('BACKUPS', "$HOME_DIR/yedekler");
$TEST_SHA = ayar('TEST_SHA', '');
$TEST_RELEASE_DIR = ayar('TEST_RELEASE_DIR', '');
$KEEP = 3;
// Korunan girdiler public_html'de yerinde kalır; wp-content içinde yalnız uploads korunur (eski /wardofit/ görselleri)
const PRESERVE = ['.well-known', 'eskisite', 'public_ftp', 'cgi-bin', '.user.ini', 'php.ini', 'wp-content'];

umask(022);
date_default_timezone_set('Europe/Istanbul');
ignore_user_abort(true);
@set_time_limit(0);
if (!$CLI) {
  header('Content-Type: application/json; charset=utf-8');
  header('Cache-Control: no-store');
  header('X-Robots-Tag: noindex, nofollow');
}
@mkdir("$OPS/releases", 0755, true);
@mkdir("$OPS/snapshots", 0755, true);

// ---------------------------------------------------------------- yardımcılar
function zaman() { return date('Y-m-d\TH:i:sO'); }
function json($v) { return json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); }
function logla($m) { global $OPS; @file_put_contents("$OPS/deploy.log", '[' . zaman() . "] tetik: $m\n", FILE_APPEND); }
function durum($state, $sha = '', $note = '') {
  global $OPS;
  @file_put_contents("$OPS/status.json", json(['time' => zaman(), 'state' => $state, 'sha' => $sha, 'note' => $note]) . "\n");
}
function yanit($kod, $veri) { global $CLI; if (!$CLI) http_response_code($kod); echo json($veri) . "\n"; }
// Çalışmanın sonu. Web'de yanıt baştan gönderildi (bağlantı kapalı); komut satırında sonucu yaz ve çıkış koduyla bit.
function bitir($kod, $veri) { global $CLI; if ($CLI) { echo json($veri) . "\n"; exit($kod >= 400 ? 1 : 0); } exit; }
function girdiler($d) { $l = @scandir($d); return $l === false ? [] : array_values(array_diff($l, ['.', '..'])); }
function korunan($e) {
  // + arama motoru doğrulama dosyaları (google*.html, yandex_*.html, BingSiteAuth.xml)
  return in_array($e, PRESERVE, true) || preg_match('/^(google[0-9a-f]+\.html|yandex_[0-9a-f]+\.html|BingSiteAuth\.xml)$/', $e) === 1;
}
function sil($p) {
  if (is_link($p) || is_file($p)) return @unlink($p);
  if (!is_dir($p)) return true;
  @chmod($p, 0755);
  $ok = true;
  foreach (girdiler($p) as $e) $ok = sil("$p/$e") && $ok;
  return @rmdir($p) && $ok;
}
// cp -a karşılığı (sembolik bağ kopyalanmaz: yayında bulunamaz, doğrulamada reddedilir)
function kopyala($src, $dst) {
  if (!is_dir($dst) && !@mkdir($dst, 0755, true)) return false;
  foreach (girdiler($src) as $e) {
    $s = "$src/$e"; $d = "$dst/$e";
    if (is_link($s)) return false;
    if (is_dir($s)) { if (!kopyala($s, $d)) return false; continue; }
    if (!@copy($s, $d)) return false;
    @chmod($d, 0644);
    @touch($d, (int) filemtime($s));
  }
  return true;
}
// [['f'|'l', göreli yol], …] — find -type f / -type l karşılığı
function agac($dir, $rel = '') {
  $out = [];
  foreach (girdiler($dir) as $e) {
    $p = "$dir/$e"; $r = $rel === '' ? $e : "$rel/$e";
    if (is_link($p)) $out[] = ['l', $r];
    elseif (is_dir($p)) $out = array_merge($out, agac($p, $r));
    else $out[] = ['f', $r];
  }
  return $out;
}
function http_al($url, $sure = 20, $dosya = null, $basliklar = []) {
  $c = curl_init($url);
  $o = [CURLOPT_FOLLOWLOCATION => true, CURLOPT_MAXREDIRS => 5, CURLOPT_CONNECTTIMEOUT => 20, CURLOPT_TIMEOUT => $sure,
        CURLOPT_USERAGENT => 'git/2.40 (hedefecu-tetik)', CURLOPT_HTTPHEADER => $basliklar, CURLOPT_FAILONERROR => true];
  if ($dosya) $o[CURLOPT_FILE] = $dosya; else $o[CURLOPT_RETURNTRANSFER] = true;
  curl_setopt_array($c, $o);
  $r = curl_exec($c);
  return $r === false ? false : ($dosya ? true : (string) $r);
}
// Canlı test istekleri: yönlendirme İZLENMEZ, 6'şar paralel → [[http kodu, yönlendirme adresi], …]
function coklu_istek($urls) {
  $out = [];
  foreach (array_chunk($urls, 6, true) as $parca) {
    $mh = curl_multi_init(); $h = [];
    foreach ($parca as $i => $u) {
      $c = curl_init($u);
      curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => false, CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_TIMEOUT => 20, CURLOPT_HTTPHEADER => ['Cache-Control: no-cache'], CURLOPT_USERAGENT => 'hedefecu-tetik']);
      curl_multi_add_handle($mh, $c);
      $h[$i] = $c;
    }
    do { $st = curl_multi_exec($mh, $calisan); if ($calisan) curl_multi_select($mh, 1.0); } while ($calisan && $st === CURLM_OK);
    foreach ($h as $i => $c) {
      $out[$i] = [(int) curl_getinfo($c, CURLINFO_HTTP_CODE), (string) curl_getinfo($c, CURLINFO_REDIRECT_URL)];
      curl_multi_remove_handle($mh, $c);
    }
  }
  return $out;
}
// deploy.sh'teki grep kalıplarının aynısı (ikisi birlikte değişir)
function htaccess_tehlikeli($t) {
  return preg_match('/^[ \t]*(AddHandler|SetHandler|ForceType[^#\n]*(php|cgi)|Action|ScriptAlias|php_value|php_flag|php_admin_|AddType[^#\n]*php|(Add|Set)OutputFilter[^#\n]*INCLUDES)/im', $t)
      || preg_match('/^[ \t]*Options[ \t][^#\n]*(^|[ \t]|\+)(ExecCGI|Includes)([ \t]|$)/im', $t)
      || preg_match('/^[ \t]*Rewrite(Rule|Cond)[ \t][^#\n]*\[([^\]\n]*,)?[ \t]*H=/im', $t);
}
function satirlar($f) { return array_values(array_filter(array_map('trim', @file($f) ?: []), 'strlen')); }
function ekle($f, $e) { file_put_contents($f, "$e\n", FILE_APPEND); }
function geri_don() {
  global $WEBROOT, $OPS, $SNAP;
  $fail = "$OPS/failed-" . date('Ymd-His');
  if (file_exists($fail)) $fail .= '-t';
  @mkdir($fail, 0755, true);
  foreach (satirlar("$SNAP/.moved-in") as $e) if (file_exists("$WEBROOT/$e") || is_link("$WEBROOT/$e")) @rename("$WEBROOT/$e", "$fail/$e");
  foreach (satirlar("$SNAP/.moved-out") as $e) if (file_exists("$SNAP/$e") || is_link("$SNAP/$e")) @rename("$SNAP/$e", "$WEBROOT/$e");
  foreach (satirlar("$SNAP/.wpc-moved-out") as $c) if (file_exists("$SNAP/_wpc/$c")) @rename("$SNAP/_wpc/$c", "$WEBROOT/wp-content/$c");
  logla("geri dönüş: eski dosyalar yerine kondu; başarısız sürüm → $fail");
}
// Son $tut dizin kalır. Sunucu izni yüzünden silinemeyen dizin "silinemeyen/" altına alınır (her çalışmada yeniden denenmesin)
function temizle($desen, $tut) {
  global $OPS;
  $d = glob($desen, GLOB_ONLYDIR) ?: [];
  usort($d, function ($a, $b) { return filemtime($b) <=> filemtime($a); });
  foreach (array_slice($d, $tut) as $x) {
    if (sil($x)) continue;
    @mkdir("$OPS/silinemeyen", 0755, true);
    @rename($x, "$OPS/silinemeyen/" . basename($x));
    logla("temizlik: $x tamamen silinemedi (sunucu izni) → $OPS/silinemeyen/");
  }
}

// ---------------------------------------------------------------- yalnız okuma: durum
if (!$CLI && isset($_GET['durum'])) {
  $st = json_decode((string) @file_get_contents("$OPS/status.json"), true);
  yanit(200, ['durum' => $st ?: null, 'canli_sha' => trim((string) @file_get_contents("$OPS/current_sha")), 'calisiyor' => is_file("$OPS/.running")]);
  exit;
}

// ---------------------------------------------------------------- tetik: 20 sn sınırı, hemen yanıt, arka planda devam
$damga = "$OPS/.tetik";
if (!$CLI && is_file($damga) && time() - (int) filemtime($damga) < 20) {
  yanit(429, ['durum' => 'bekle', 'saniye' => 20 - (time() - (int) filemtime($damga))]);
  exit;
}
@touch($damga);
if (!$CLI) {
  yanit(202, ['durum' => 'tetiklendi', 'zaman' => zaman(), 'izle' => '?durum=1']);
  if (function_exists('litespeed_finish_request')) litespeed_finish_request();
  elseif (function_exists('fastcgi_finish_request')) fastcgi_finish_request();
}

// Tek örnek: deploy.sh ile aynı kilit. Cron çalışıyorsa bitmesini en fazla 2 dk bekle (o da aynı sürümü kuruyor olabilir).
$kilit = fopen("$OPS/.lock", 'c');
$son = time() + 120;
while (!$kilit || !flock($kilit, LOCK_EX | LOCK_NB)) {
  if (time() > $son) { logla('kilit: başka bir çalışma 2 dakikadır sürüyor — vazgeçildi (cron kuracak)'); bitir(409, ['durum' => 'mesgul']); }
  sleep(2);
}
file_put_contents("$OPS/.running", 'tetik pid=' . getmypid() . ' başlangıç=' . zaman() . "\n");
$YARIM = false; $SHA = ''; $SNAP = '';
register_shutdown_function(function () {
  global $OPS, $YARIM, $SHA;
  // yer değiştirme ortasında ölümcül hata / süre aşımı → eski dosyaları geri koy
  if ($YARIM) { $YARIM = false; logla('HATA: kurulum yarıda kesildi — geri dönülüyor'); geri_don(); durum('rolled-back', $SHA, 'yarıda kesildi'); }
  @unlink("$OPS/.running");
});

$lg = "$OPS/deploy.log";
if (is_file($lg) && filesize($lg) > 1048576) {
  $f = fopen($lg, 'rb'); fseek($f, -262144, SEEK_END); $t = stream_get_contents($f); fclose($f);
  file_put_contents("$lg.tmp", $t); rename("$lg.tmp", $lg);
}

// WordPress'ten ilk geçiş (tam yedek dahil) yalnız deploy.sh ile yapılır
if (is_file("$WEBROOT/wp-config.php") && !is_file("$BACKUPS/.wp-ok")) bitir(409, ['durum' => 'ilk-gecis-cron-ile']);

// ---------------------------------------------------------------- uzak sürüm (git ls-remote karşılığı)
function uzak_sha() {
  global $TEST_SHA, $REPO, $BRANCH;
  if ($TEST_SHA !== '') return $TEST_SHA;
  $refs = http_al("https://github.com/$REPO.git/info/refs?service=git-upload-pack", 30);
  if ($refs !== false && preg_match('#([0-9a-f]{40}) refs/heads/' . preg_quote($BRANCH, '#') . '(\x00|\n)#', $refs, $m)) return $m[1];
  $r = http_al("https://api.github.com/repos/$REPO/commits/$BRANCH", 20, null, ['Accept: application/vnd.github.sha']);
  return $r === false ? '' : substr(preg_replace('/[^0-9a-f]/', '', $r), 0, 40);
}
$current = trim((string) @file_get_contents("$OPS/current_sha"));
$remote = uzak_sha();
// Yayın betiği gönderir göndermez tetikler; GitHub'ın yeni commit'i göstermesi bir an gecikebilir → bir kez daha bak
if (!$CLI && $remote === $current) { sleep(5); $remote = uzak_sha(); }
if (strlen($remote) !== 40) { logla('uzak: sürüm okunamadı (ağ/GitHub); cron yeniden deneyecek'); bitir(502, ['durum' => 'uzak-okunamadi']); }
if ($remote === $current) bitir(200, ['durum' => 'guncel', 'sha' => $remote]);
if (in_array($remote, satirlar("$OPS/bad_shas"), true)) bitir(200, ['durum' => 'reddedilmis-surum', 'sha' => $remote]);
$SHA = $remote;
logla("yeni sürüm: $remote (canlı: " . ($current ?: 'yok') . ')');
durum('installing', $remote);

// ---------------------------------------------------------------- indir + aç (codeload arşivinde tek üst klasör var → onun içi)
$rel = "$OPS/releases/$remote";
if (!is_dir("$rel/public") && $TEST_RELEASE_DIR !== '') kopyala($TEST_RELEASE_DIR, $rel);
if (!is_dir("$rel/public")) {
  $tmp = "$rel.tmp"; sil($tmp); @mkdir($tmp, 0755, true);
  $tgz = "$OPS/releases/$remote.tar.gz";
  $fh = @fopen($tgz, 'wb');
  $hata = ($fh && http_al("https://codeload.github.com/$REPO/tar.gz/$remote", 180, $fh)) ? null : 'indirme: HATA';
  if ($fh) fclose($fh);
  if (!$hata) {
    try { (new PharData($tgz))->extractTo($tmp, null, true); }
    catch (Throwable $e) { $hata = 'açma: HATA — ' . $e->getMessage(); }
  }
  @unlink($tgz);
  if (!$hata) {
    $ust = array_values(array_filter(girdiler($tmp), function ($e) use ($tmp) { return is_dir("$tmp/$e") && !is_link("$tmp/$e"); }));
    if (count($ust) !== 1) $hata = 'açma: HATA — beklenmeyen arşiv yapısı';
    elseif (!@rename("$tmp/{$ust[0]}", $rel)) $hata = 'açma: HATA — taşınamadı';
  }
  sil($tmp);
  if ($hata) { logla($hata); sil($rel); durum('download-failed', $remote, $hata); bitir(502, ['durum' => 'indirme-hatasi', 'not' => $hata]); }
}

// ---------------------------------------------------------------- doğrulama
function reddet($neden) {
  global $OPS, $SHA;
  logla("doğrulama: HATA — $neden");
  ekle("$OPS/bad_shas", $SHA);
  durum('invalid', $SHA, $neden);
  bitir(422, ['durum' => 'reddedildi', 'neden' => $neden, 'sha' => $SHA]);
}
foreach (['index.html', '.htaccess', 'sitemap.xml', '404.html'] as $f) if (!is_file("$rel/public/$f")) reddet("$f yok");
$rid = preg_replace('/[^0-9a-f]/', '', (string) @file_get_contents("$rel/_ops/release-id"));
if (strlen($rid) < 8) reddet('_ops/release-id yok');
if (strpos((string) @file_get_contents("$rel/public/version.txt"), $rid) !== 0) reddet('version.txt yayın kimliğiyle uyuşmuyor');
$dosyalar = [];
foreach (agac("$rel/public") as $g) { if ($g[0] === 'l') reddet("yayında sembolik bağ var: {$g[1]}"); $dosyalar[] = $g[1]; }
$n = count($dosyalar);
if ($n < 100) reddet("dosya sayısı çok az ($n)");
$calis = preg_grep('/\.(php\d?|pht|phtml|phar|cgi|pl|py|sh|shtml)$/i', $dosyalar);
if ($calis) reddet('yayında çalıştırılabilir dosya var: ' . implode(' ', array_slice($calis, 0, 3)));
foreach ($dosyalar as $f) {
  if (basename($f) === '.htaccess' && htaccess_tehlikeli((string) file_get_contents("$rel/public/$f"))) reddet(".htaccess içinde betik çalıştırma yönergesi var ($f)");
}
if (is_file("$rel/_ops/SHA256SUMS")) {
  foreach (satirlar("$rel/_ops/SHA256SUMS") as $s) {
    if (!preg_match('#^([0-9a-f]{64})  \./(.+)$#', $s, $m) || preg_match('#(^|/)\.\.(/|$)#', $m[2])) reddet('sağlama toplamı dosyası bozuk');
    $p = "$rel/public/{$m[2]}";
    if (!is_file($p) || hash_file('sha256', $p) !== $m[1]) reddet("sağlama toplamı uyuşmuyor ({$m[2]})");
  }
}
// Sunucudaki betikler depodan kendini GÜNCELLEMEZ; fark yalnız günlüğe yazılır
if (is_file("$rel/_ops/deploy.sh") && @sha1_file("$rel/_ops/deploy.sh") !== @sha1_file("$OPS/deploy.sh")) logla('betik: depodaki deploy.sh farklı — otomatik güncellenmedi');
if (is_file("$rel/_ops/tetik/index.php") && @sha1_file("$rel/_ops/tetik/index.php") !== @sha1_file(__FILE__)) logla('tetik: depodaki index.php farklı — otomatik güncellenmedi');

// güvenlik kapısı
if (preg_replace('/[^0-9]/', '', (string) @file_get_contents("$rel/_ops/enabled")) !== '1') {
  logla('kapı: _ops/enabled != 1 — kurulum yapılmadı (yalnız indirildi ve doğrulandı)');
  durum('gated', $remote);
  bitir(200, ['durum' => 'kapi-kapali', 'sha' => $remote]);
}

// ---------------------------------------------------------------- kurulum (yer değiştirme; saniyenin altında)
$stage = "$OPS/stage-$rid";
sil($stage);
if (!kopyala("$rel/public", $stage)) { logla('hazırlık: HATA'); sil($stage); durum('stage-failed', $remote); bitir(500, ['durum' => 'hazirlik-hatasi']); }
$SNAP = "$OPS/snapshots/" . date('Ymd-His');
if (file_exists($SNAP)) $SNAP .= '-t';
@mkdir("$SNAP/_wpc", 0755, true);
foreach (['.moved-out', '.moved-in', '.wpc-moved-out'] as $f) file_put_contents("$SNAP/$f", '');

$YARIM = true;
// 1) eski girdileri anlık yedeğe taşı (korunanlar hariç)
foreach (girdiler($WEBROOT) as $e) {
  if (korunan($e)) continue;
  if (@rename("$WEBROOT/$e", "$SNAP/$e")) { ekle("$SNAP/.moved-out", $e); continue; }
  logla("taşıma: HATA ($e)"); $YARIM = false; geri_don(); durum('rolled-back', $remote, 'move-out'); bitir(500, ['durum' => 'geri-donuldu', 'neden' => "taşıma: $e"]);
}
if (is_dir("$WEBROOT/wp-content")) {
  foreach (girdiler("$WEBROOT/wp-content") as $c) {
    if ($c === 'uploads') continue;
    if (@rename("$WEBROOT/wp-content/$c", "$SNAP/_wpc/$c")) ekle("$SNAP/.wpc-moved-out", $c);
  }
}
// 2) yeni girdileri içeri al
foreach (girdiler($stage) as $e) {
  if (korunan($e)) { logla("uyarı: yayında korunan ad ($e) — atlandı"); continue; }
  if (@rename("$stage/$e", "$WEBROOT/$e")) { ekle("$SNAP/.moved-in", $e); continue; }
  logla("taşıma: HATA ($e)"); $YARIM = false; geri_don(); durum('rolled-back', $remote, 'move-in'); bitir(500, ['durum' => 'geri-donuldu', 'neden' => "taşıma: $e"]);
}
$YARIM = false;
sil($stage);
logla("kuruldu: $remote / $rid ($n dosya; anlık yedek $SNAP)");

// ---------------------------------------------------------------- canlı test (_ops/urls.txt: "yol beklenen_kod [beklenen_hedef]")
sleep(3);
$testler = [];
foreach (satirlar("$rel/_ops/urls.txt") as $s) {
  if ($s[0] === '#') continue;
  $p = preg_split('/\s+/', $s);
  $testler[] = [$p[0], $p[1] ?? '', $p[2] ?? ''];
}
$sonuc = coklu_istek(array_map(function ($t) use ($SITE_URL) { return $SITE_URL . $t[0]; }, $testler));
$bad = 0; $hatalar = [];
foreach ($testler as $i => $t) {
  [$yol, $bek, $hedef] = $t; [$kod, $yon] = $sonuc[$i];
  if ((string) $kod !== $bek) { $bad++; $hatalar[] = "$yol → $kod (beklenen $bek)"; logla("test: HATA $yol → $kod (beklenen $bek)"); continue; }
  if ($hedef !== '' && $yon !== $SITE_URL . $hedef) { $bad++; $hatalar[] = "$yol → $yon"; logla("test: HATA $yol → $yon (beklenen $SITE_URL$hedef)"); }
}
$checked = count($testler);
$live = http_al("$SITE_URL/version.txt", 20, null, ['Cache-Control: no-cache']);
$live = $live === false ? '' : (string) strtok($live, "\n");
if (strpos($live, $rid) !== 0) { $bad++; $hatalar[] = "version.txt '$live'"; logla("test: HATA version.txt canlıda '$live' (beklenen $rid)"); }

if ($bad > 0) {
  logla("test: $bad/$checked hata — GERİ DÖNÜLÜYOR");
  geri_don();
  ekle("$OPS/bad_shas", $remote);
  durum('rolled-back', $remote, "$bad hata");
  bitir(500, ['durum' => 'geri-donuldu', 'hatalar' => array_slice($hatalar, 0, 10)]);
}

file_put_contents("$OPS/current_sha", "$remote\n");
durum('live', $remote, "$checked test geçti");
logla("test: $checked/$checked geçti — CANLI");

// ---------------------------------------------------------------- temizlik (son $KEEP sürüm ve anlık yedek; WordPress tam yedeği kalıcı)
temizle("$OPS/releases/*", $KEEP);
temizle("$OPS/snapshots/*", $KEEP);
temizle("$OPS/failed-*", 2);
bitir(200, ['durum' => 'canli', 'sha' => $remote, 'yayin' => $rid, 'test' => "$checked/$checked"]);
