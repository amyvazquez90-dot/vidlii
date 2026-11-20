#!/bin/bash
# Starts the bundled MariaDB, prepares the VidLii database on first boot,
# then runs the PHP server on $PORT.
set -euo pipefail

ROOT=/var/www/html
PORT="${PORT:-3000}"
SOCKET=/tmp/mysqld/mysqld.sock
DB_NAME=vidlii
DB_USER=vidlii
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-vidlii-admin-2025}"
SITE_TITLE="${SITE_TITLE:-VidLii}"
SITE_SLOGAN="${SITE_SLOGAN:-Display Yourself.}"

# Random per-boot database password (kept only inside this container).
# Generated with PHP: a `tr | head` pipeline would exit 141 (SIGPIPE) under pipefail.
DB_PASS="$(php -r 'echo bin2hex(random_bytes(16));')"
if [ -z "$DB_PASS" ]; then
  echo "[entrypoint] could not generate database password" >&2
  exit 1
fi

mkdir -p /tmp/mysqld "$ROOT/cache" "$ROOT/usfi/v" "$ROOT/usfi/thmp" \
         "$ROOT/usfi/conv" "$ROOT/usfi/conv_2" "$ROOT/usfi/prvw"

# Fresh data directory (first boot only)
if [ ! -d /var/lib/mysql/mysql ]; then
  echo "[entrypoint] initializing MariaDB data directory"
  mariadb-install-db --datadir=/var/lib/mysql \
    --auth-root-authentication-method=normal --skip-test-db >/dev/null
fi

echo "[entrypoint] starting MariaDB"
mariadbd --datadir=/var/lib/mysql --socket="$SOCKET" \
  --pid-file=/tmp/mysqld/mysqld.pid --port=3306 --bind-address=127.0.0.1 \
  --skip-networking=0 \
  --skip-name-resolve --performance-schema=OFF \
  --innodb-buffer-pool-size=64M --log-error=/tmp/mysqld/mariadb.err &

for _ in $(seq 1 60); do
  if mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; then break; fi
  sleep 1
done

if ! mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; then
  echo "[entrypoint] MariaDB failed to start:" >&2
  cat /tmp/mysqld/mariadb.err >&2 || true
  exit 1
fi

# Import the schema once (detected by the presence of the users table)
if ! mariadb --socket="$SOCKET" -u root -e "SELECT 1 FROM ${DB_NAME}.users LIMIT 1" >/dev/null 2>&1; then
  echo "[entrypoint] importing schema"
  mariadb --socket="$SOCKET" -u root -e \
    "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  mariadb --socket="$SOCKET" -u root "$DB_NAME" < "$ROOT/schema.sql"

  mariadb --socket="$SOCKET" -u root "$DB_NAME" -e \
    "INSERT INTO settings (name, value) VALUES
       ('logo', '0'), ('top_text', ''), ('guidelines', '1'), ('help', '1'),
       ('signup', '1'), ('login', '1'), ('uploader', '1'), ('channels', '1'), ('videos', '1');"

  echo "[entrypoint] database ready"
fi

# Admin account: create it, or repair its password hash so the documented
# credentials always verify. Runs on every boot; the script is idempotent.
if ! SOCKET_IN="$SOCKET" DB_IN="$DB_NAME" ADMIN_USER_IN="$ADMIN_USER" \
     ADMIN_PASSWORD_IN="$ADMIN_PASSWORD" php "$ROOT/scripts/seed-admin.php"; then
  echo "[entrypoint] admin account seeding failed" >&2
fi

# Database account used by the application
mariadb --socket="$SOCKET" -u root -e \
  "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
   ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
   GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
   FLUSH PRIVILEGES;"

cat > "$ROOT/.env" <<EOF
database = "mysqli://${DB_USER}:${DB_PASS}@127.0.0.1/${DB_NAME}?charset=utf8mb4"
host = "127.0.0.1"
db = "${DB_NAME}"
username = "${DB_USER}"
password = "${DB_PASS}"
title = "${SITE_TITLE}"
slogan = "${SITE_SLOGAN}"
uploadLimit = "2147483648"
language = "en_US"
show_online_count = "1"
EOF

# Prove the application's own database path works (same .env, same TCP user,
# same login query). A failure here is logged instead of only surfacing later
# to the user as "Invalid Username or Password".
if ! ROOT_IN="$ROOT" ADMIN_USER_IN="$ADMIN_USER" ADMIN_PASSWORD_IN="$ADMIN_PASSWORD" \
     php "$ROOT/scripts/verify-db.php"; then
  echo "[entrypoint] WARNING: application database self-check failed" >&2
fi

echo "[entrypoint] starting PHP server on 0.0.0.0:${PORT}"
# A few worker processes so asset requests are not serialized behind one request.
export PHP_CLI_SERVER_WORKERS="${PHP_CLI_SERVER_WORKERS:-4}"
exec php -S "0.0.0.0:${PORT}" -t "$ROOT" "$ROOT/router.php"
