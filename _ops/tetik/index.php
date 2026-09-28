<?php
// hedefecu.com — anlık yayın tetiği (https://tetik.hedefecu.com/)
// Yalnız "yayın deposunu ŞİMDİ kontrol et" der: ~/hedefecu-ops/deploy.sh'i arka planda başlatır (cron'u beklemeden).
// İçerik güvenliği deploy.sh'dedir (GitHub'dan indirme, sağlama toplamı, çalıştırılabilir dosya reddi, canlı test, geri dönüş).
// Parametre almaz, veri almaz; en fazla 20 saniyede bir çalışır. Sunucuya bir kez kurulur (cron, sabit commit'ten indirir).
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex, nofollow');

$home  = '/home/hedefecu';
$ops   = $home . '/hedefecu-ops';
$stamp = $ops . '/.tetik';
$now   = time();

if (is_file($stamp) && ($now - filemtime($stamp)) < 20) {
    http_response_code(429);
    echo json_encode(['durum' => 'bekle', 'saniye' => 20 - ($now - filemtime($stamp))]);
    exit;
}
@touch($stamp);

$off = array_map('trim', explode(',', (string) ini_get('disable_functions')));
$can = function ($f) use ($off) { return function_exists($f) && !in_array($f, $off, true); };
$cmd = 'cd ' . escapeshellarg($ops)
     . ' && HOME=' . escapeshellarg($home) . ' PATH=/usr/local/bin:/usr/bin:/bin'
     . ' nohup /bin/bash ' . escapeshellarg($ops . '/deploy.sh')
     . ' >> ' . escapeshellarg($ops . '/deploy.log') . ' 2>&1 < /dev/null &';

if ($can('exec')) {
    exec($cmd); $via = 'exec';
} elseif ($can('shell_exec')) {
    shell_exec($cmd); $via = 'shell_exec';
} elseif ($can('proc_open')) {
    $p = proc_open($cmd, [], $pipes); if (is_resource($p)) { proc_close($p); } $via = 'proc_open';
} elseif ($can('popen')) {
    pclose(popen($cmd, 'r')); $via = 'popen';
} else {
    http_response_code(503);
    echo json_encode(['durum' => 'kapali', 'neden' => 'PHP komut çalıştırma işlevleri sunucuda kapalı']);
    exit;
}
echo json_encode(['durum' => 'tetiklendi', 'yol' => $via, 'zaman' => date('c', $now)]);
