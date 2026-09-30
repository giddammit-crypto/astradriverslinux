<?php
/**
 * api/config.php — Конфигурация системы автообновления с GitHub
 */
return [
    'github_repo'   => 'giddammit-crypto/astradriverslinux',
    'github_branch' => 'main',
    'update_token'  => '',     // Опциональный секретный пароль для защиты кнопки обновления
    'github_token'  => '',     // Опциональный GitHub Personal Access Token (для приватных репо или лимитов API)
    'cache_ttl'     => 1800,   // Кэш проверки наличия обновлений (секунды)
];
