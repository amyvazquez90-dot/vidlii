<?php
/**
 * Boot-time self check: does the application's own database path work?
 *
 * Reads the same .env the app reads, connects over TCP with the application
 * user exactly like the app does, runs Auth::login's query and verifies the
 * admin password hash. Prints one line per step so failures are visible in the
 * container log instead of surfacing as "Invalid Username or Password".
 *
 * Environment: ROOT_IN (app root), ADMIN_USER_IN, ADMIN_PASSWORD_IN
 */

$root = getenv('ROOT_IN') ?: '/var/www/html';
$user = getenv('ADMIN_USER_IN') ?: 'admin';
$pass = getenv('ADMIN_PASSWORD_IN') ?: 'vidlii-admin-2025';
$envFile = rtrim($root, '/') . '/.env';

if (!is_readable($envFile)) {
    echo "[verify-db] FAIL: {$envFile} is not readable\n";
    exit(1);
}

$raw = file_get_contents($envFile);
if (!preg_match('/^database\s*=\s*"([^"]+)"/m', $raw, $m)) {
    echo "[verify-db] FAIL: no database DSN in .env\n";
    exit(1);
}

$dsn = $m[1];
if (!preg_match('#^mysqli://([^:]+):([^@]*)@([^/]+)/([^?]+)#', $dsn, $d)) {
    echo "[verify-db] FAIL: DSN is not parseable\n";
    exit(1);
}
[, $dbUser, $dbPass, $dbHost, $dbName] = $d;

// The app connects through the Unix socket when the DSN asks for one.
$socket = preg_match('/[?&]unix_socket=([^&]+)/', $dsn, $s) ? urldecode($s[1]) : null;

// Prove the language file the app will load actually exists.
$lang = preg_match('/^language\s*=\s*"([^"]*)"/m', $raw, $l) ? $l[1] : '';
$langFile = rtrim($root, '/') . '/languages/' . $lang . '.php';
if (!is_file($langFile)) {
    echo "[verify-db] WARN: language '{$lang}' has no file (languages/{$lang}.php)\n";
}

try {
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $conn = $socket
        ? new mysqli('localhost', $dbUser, $dbPass, $dbName, 0, $socket)
        : new mysqli($dbHost, $dbUser, $dbPass, $dbName);
    echo "[verify-db] connected as {$dbUser} to {$dbName}"
        . ($socket ? " via socket" : ' via TCP') . "\n";

    $stmt = $conn->prepare(
        'SELECT username, password FROM users WHERE username = ? OR displayname = ? OR email = ? LIMIT 1'
    );
    $stmt->bind_param('sss', $user, $user, $user);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();

    if (!$row) {
        echo "[verify-db] FAIL: no user row matches '{$user}'\n";
        exit(1);
    }
    if (!password_verify($pass, (string)$row['password'])) {
        echo "[verify-db] FAIL: stored password hash for '{$row['username']}' does not match\n";
        exit(1);
    }
    echo "[verify-db] login query and password check OK for '{$row['username']}'\n";
} catch (Throwable $e) {
    echo '[verify-db] FAIL: ' . $e->getMessage() . "\n";
    exit(1);
}
