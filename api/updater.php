<?php
/**
 * api/updater.php — Система обновления сайта и скриптов проекта с GitHub
 * Проект: astradriverslinux (biblioteka33.ru/linux)
 * =============================================================================
 * Действия:
 *   GET  ?action=status       — текущая версия, репозиторий, статус последнего коммита
 *   POST {"action":"check"}   — проверка наличия свежих коммитов/релизов на GitHub
 *   POST {"action":"update"}  — загрузка и накат обновлений (git pull или zip-архив)
 */

error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED);
ini_set('display_errors', '0');
set_time_limit(300);

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');
header('Content-Type: application/json; charset=UTF-8');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

define('APP_ROOT', dirname(__DIR__));
define('VERSION_FILE', APP_ROOT . DIRECTORY_SEPARATOR . '.version.json');
define('DATA_DIR', APP_ROOT . DIRECTORY_SEPARATOR . 'data');

if (!is_dir(DATA_DIR)) {
    @mkdir(DATA_DIR, 0775, true);
}
$stateFile = DATA_DIR . DIRECTORY_SEPARATOR . 'updater_state.json';

// Конфигурация
$config = [
    'github_repo'   => 'giddammit-crypto/astradriverslinux',
    'github_branch' => 'main',
    'update_token'  => '',
    'github_token'  => '',
    'cache_ttl'     => 1800,
];

$configFile = __DIR__ . '/config.php';
if (is_readable($configFile)) {
    $loaded = include $configFile;
    if (is_array($loaded)) {
        $config = array_merge($config, $loaded);
    }
}

function reply(array $payload, $code = 200) {
    http_response_code($code);
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function get_local_version() {
    if (!is_file(VERSION_FILE)) {
        return [
            'version' => '2.1.0',
            'commit' => '',
            'release_name' => 'Космо 2.1.0',
            'repo' => 'giddammit-crypto/astradriverslinux',
            'branch' => 'main'
        ];
    }
    $decoded = json_decode((string)@file_get_contents(VERSION_FILE), true);
    return is_array($decoded) ? $decoded : ['version' => '2.1.0', 'commit' => ''];
}

function http_request($url, array $headers = [], $timeout = 30) {
    if (function_exists('curl_init')) {
        $ch = curl_init();
        $defaultHeaders = [
            'User-Agent: Cosmo-Updater-Platform/2.1',
            'Accept: application/vnd.github.v3+json'
        ];
        $allHeaders = array_merge($defaultHeaders, $headers);

        curl_setopt_array($ch, [
            CURLOPT_URL => $url,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS => 5,
            CURLOPT_TIMEOUT => $timeout,
            CURLOPT_CONNECTTIMEOUT => 10,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_HTTPHEADER => $allHeaders
        ]);

        $body = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err  = curl_error($ch);
        curl_close($ch);

        return ['code' => $code, 'body' => $body, 'error' => $err];
    } else {
        $opts = [
            'http' => [
                'method' => 'GET',
                'header' => "User-Agent: Cosmo-Updater-Platform/2.1\r\nAccept: application/vnd.github.v3+json\r\n",
                'timeout' => $timeout,
                'ignore_errors' => true
            ]
        ];
        $ctx = stream_context_create($opts);
        $body = @file_get_contents($url, false, $ctx);
        return ['code' => $body !== false ? 200 : 500, 'body' => $body, 'error' => ''];
    }
}

// Получение входных параметров
$rawInput = file_get_contents('php://input');
$input = json_decode($rawInput, true);
if (!is_array($input)) {
    $input = [];
}
$action = isset($_GET['action']) ? (string)$_GET['action'] : (isset($input['action']) ? (string)$input['action'] : 'status');

$localVer = get_local_version();
$state = is_file($stateFile) ? json_decode((string)@file_get_contents($stateFile), true) : [];
if (!is_array($state)) $state = [];

// 1. СТАТУС
if ($action === 'status') {
    $hasGit = is_dir(APP_ROOT . DIRECTORY_SEPARATOR . '.git');
    $gitCommit = '';
    if ($hasGit && function_exists('exec')) {
        $gitCommit = trim((string)@exec('git -C ' . escapeshellarg(APP_ROOT) . ' rev-parse --short HEAD 2>/dev/null'));
    }

    reply([
        'ok' => true,
        'current_version' => $localVer['version'] ?? '2.1.0',
        'current_commit' => $gitCommit ?: ($localVer['commit'] ?? ''),
        'release_name' => $localVer['release_name'] ?? '',
        'repo' => $config['github_repo'],
        'branch' => $config['github_branch'],
        'is_git_repo' => $hasGit,
        'last_checked' => $state['last_checked'] ?? null,
        'latest_remote_commit' => $state['latest_commit'] ?? null,
        'has_update' => !empty($state['has_update'])
    ]);
}

// 2. ПРОВЕРКА ОБНОВЛЕНИЙ
if ($action === 'check') {
    $repo = $config['github_repo'];
    $branch = $config['github_branch'];
    $url = "https://api.github.com/repos/{$repo}/commits/{$branch}";
    
    $headers = [];
    if (!empty($config['github_token'])) {
        $headers[] = 'Authorization: token ' . $config['github_token'];
    }

    $res = http_request($url, $headers);
    if ($res['code'] !== 200 || empty($res['body'])) {
        reply([
            'ok' => false,
            'error' => "Не удалось связаться с GitHub API (HTTP {$res['code']}): " . ($res['error'] ?: 'Неизвестная ошибка')
        ], 502);
    }

    $commitData = json_decode($res['body'], true);
    if (!isset($commitData['sha'])) {
        reply(['ok' => false, 'error' => 'Некорректный ответ GitHub API'], 502);
    }

    $remoteSha = $commitData['sha'];
    $shortRemoteSha = substr($remoteSha, 0, 7);
    $commitMsg = $commitData['commit']['message'] ?? '';
    $commitDate = $commitData['commit']['committer']['date'] ?? '';

    $localSha = $localVer['commit'] ?? '';
    if (is_dir(APP_ROOT . DIRECTORY_SEPARATOR . '.git') && function_exists('exec')) {
        $gitSha = trim((string)@exec('git -C ' . escapeshellarg(APP_ROOT) . ' rev-parse HEAD 2>/dev/null'));
        if ($gitSha) $localSha = $gitSha;
    }

    $hasUpdate = ($localSha && strpos($remoteSha, $localSha) !== 0);

    $state['last_checked'] = date('c');
    $state['latest_commit'] = [
        'sha' => $remoteSha,
        'short_sha' => $shortRemoteSha,
        'message' => $commitMsg,
        'date' => $commitDate
    ];
    $state['has_update'] = $hasUpdate;
    @file_put_contents($stateFile, json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

    reply([
        'ok' => true,
        'has_update' => $hasUpdate,
        'current_commit' => substr($localSha, 0, 7),
        'latest_commit' => $state['latest_commit']
    ]);
}

// 3. ПРИМЕНЕНИЕ ОБНОВЛЕНИЯ
if ($action === 'update') {
    if (!empty($config['update_token'])) {
        $providedToken = (string)($input['token'] ?? ($_POST['token'] ?? ''));
        if ($providedToken !== $config['update_token']) {
            reply(['ok' => false, 'error' => 'Неверный токен авторизации для обновления'], 403);
        }
    }

    $hasGit = is_dir(APP_ROOT . DIRECTORY_SEPARATOR . '.git');
    $branch = $config['github_branch'];
    $output = [];
    $ret = 0;

    if ($hasGit && function_exists('exec')) {
        // Способ 1: через git pull
        $cmd = 'git -C ' . escapeshellarg(APP_ROOT) . ' pull origin ' . escapeshellarg($branch) . ' 2>&1';
        exec($cmd, $output, $ret);
        $fullOutput = implode("\n", $output);

        if ($ret === 0) {
            $newSha = trim((string)@exec('git -C ' . escapeshellarg(APP_ROOT) . ' rev-parse HEAD 2>/dev/null'));
            $localVer['commit'] = $newSha;
            $localVer['updated_at'] = date('c');
            @file_put_contents(VERSION_FILE, json_encode($localVer, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

            $state['has_update'] = false;
            $state['last_updated'] = date('c');
            @file_put_contents($stateFile, json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

            reply([
                'ok' => true,
                'method' => 'git',
                'message' => 'Репозиторий успешно обновлен через git pull',
                'new_commit' => substr($newSha, 0, 7),
                'details' => $fullOutput
            ]);
        }
    }

    // Способ 2: Загрузка архива релизной ветки с GitHub
    $repo = $config['github_repo'];
    $zipUrl = "https://github.com/{$repo}/archive/refs/heads/{$branch}.zip";
    $tmpZip = tempnam(sys_get_temp_dir(), 'cosmo_upd_') . '.zip';

    $res = http_request($zipUrl, [], 120);
    if ($res['code'] !== 200 || empty($res['body'])) {
        reply(['ok' => false, 'error' => "Не удалось скачать архив обновления с GitHub (HTTP {$res['code']})"], 502);
    }
    file_put_contents($tmpZip, $res['body']);

    if (class_exists('ZipArchive')) {
        $zip = new ZipArchive();
        if ($zip->open($tmpZip) === true) {
            $extractDir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'cosmo_extract_' . uniqid();
            @mkdir($extractDir, 0775, true);
            $zip->extractTo($extractDir);
            $zip->close();
            @unlink($tmpZip);

            // Находим корневую подпапку архива
            $entries = scandir($extractDir);
            $rootSubdir = null;
            foreach ($entries as $e) {
                if ($e !== '.' && $e !== '..' && is_dir($extractDir . DIRECTORY_SEPARATOR . $e)) {
                    $rootSubdir = $extractDir . DIRECTORY_SEPARATOR . $e;
                    break;
                }
            }

            if ($rootSubdir && is_dir($rootSubdir)) {
                // Копируем файлы поверх текущего каталога
                $copyFiles = ['index.html', 'installer_gui.py', '.version.json'];
                foreach ($copyFiles as $cf) {
                    if (is_file($rootSubdir . DIRECTORY_SEPARATOR . $cf)) {
                        @copy($rootSubdir . DIRECTORY_SEPARATOR . $cf, APP_ROOT . DIRECTORY_SEPARATOR . $cf);
                    }
                }
                // Копируем scripts/ и assets/
                foreach (['scripts', 'assets'] as $cd) {
                    $srcDir = $rootSubdir . DIRECTORY_SEPARATOR . $cd;
                    $dstDir = APP_ROOT . DIRECTORY_SEPARATOR . $cd;
                    if (is_dir($srcDir)) {
                        if (!is_dir($dstDir)) @mkdir($dstDir, 0775, true);
                        $dirFiles = scandir($srcDir);
                        foreach ($dirFiles as $df) {
                            if ($df !== '.' && $df !== '..') {
                                @copy($srcDir . DIRECTORY_SEPARATOR . $df, $dstDir . DIRECTORY_SEPARATOR . $df);
                                @chmod($dstDir . DIRECTORY_SEPARATOR . $df, 0755);
                            }
                        }
                    }
                }
                // Удаляем временные файлы
                exec('rm -rf ' . escapeshellarg($extractDir));

                $state['has_update'] = false;
                $state['last_updated'] = date('c');
                @file_put_contents($stateFile, json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

                reply([
                    'ok' => true,
                    'method' => 'archive',
                    'message' => 'Файлы сайта и скрипты успешно обновлены из архива репозитория GitHub!'
                ]);
            }
        }
    }

    reply(['ok' => false, 'error' => 'Не удалось распаковать архив обновления'], 500);
}

reply(['ok' => false, 'error' => 'Неизвестное действие: ' . htmlspecialchars($action)], 400);
