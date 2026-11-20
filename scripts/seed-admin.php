<?php
/**
 * Idempotent admin account seeding.
 *
 * Creates the admin user when it is missing and repairs its password hash when
 * the documented password does not verify, so `admin` / ADMIN_PASSWORD always
 * works after a fresh boot. Safe to run on every container start.
 *
 * Environment: SOCKET_IN, DB_IN, ADMIN_USER_IN, ADMIN_PASSWORD_IN
 */

$socket = getenv('SOCKET_IN') ?: '/run/mysqld/mysqld.sock';
$db     = getenv('DB_IN') ?: 'vidlii';
$user   = getenv('ADMIN_USER_IN') ?: 'admin';
$pw     = (string)getenv('ADMIN_PASSWORD_IN');

if ($pw === '') {
    fwrite(STDERR, "[seed-admin] ADMIN_PASSWORD is empty; refusing to seed\n");
    exit(1);
}

$m = @new mysqli(null, 'root', '', $db, 0, $socket);
if ($m->connect_errno) {
    fwrite(STDERR, "[seed-admin] connect failed: {$m->connect_error}\n");
    exit(1);
}
$m->set_charset('utf8mb4');

$esc = static function (string $v) use ($m): string {
    return $m->real_escape_string($v);
};

$select = "SELECT password FROM users WHERE username = '" . $esc($user) . "'";
$res    = $m->query($select);
$row    = $res ? $res->fetch_row() : null;

$hash = password_hash($pw, PASSWORD_BCRYPT);

if ($row === null) {
    $sql = "INSERT INTO users (username, displayname, email, password, reg_date, last_login, birthday, 1st_latest_ip, country, partner, is_admin, is_mod)
            VALUES ('" . $esc($user) . "', '" . $esc($user) . "', '" . $esc($user . '@example.com') . "', '" . $esc($hash) . "', NOW(), NOW(), '1910-01-01', '127.0.0.1', 'US', 1, 1, 1)";
    if (!$m->query($sql)) {
        fwrite(STDERR, "[seed-admin] insert failed: {$m->error}\n");
        exit(1);
    }
    echo "[seed-admin] created account '{$user}'\n";
} elseif (!password_verify($pw, (string)$row[0])) {
    if (!$m->query("UPDATE users SET password = '" . $esc($hash) . "' WHERE username = '" . $esc($user) . "'")) {
        fwrite(STDERR, "[seed-admin] password update failed: {$m->error}\n");
        exit(1);
    }
    echo "[seed-admin] repaired password for '{$user}'\n";
} else {
    echo "[seed-admin] password already valid for '{$user}'\n";
}

// Verify what is actually stored, not what we intended to store.
$res = $m->query($select);
$row = $res ? $res->fetch_row() : null;
if ($row === null || !password_verify($pw, (string)$row[0])) {
    fwrite(STDERR, "[seed-admin] verification FAILED for '{$user}'\n");
    exit(1);
}

echo "[seed-admin] verified login for '{$user}'\n";
exit(0);
