#!/bin/bash
# Local run helper for VidLii: starts a throwaway MariaDB instance, imports the
# schema on first use, writes .env and serves the app with PHP's built-in server.
# Used for local verification; the deployed container uses docker-entrypoint.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA=/tmp/vidlii-mdb
SOCKET="$DATA/mysqld.sock"
PORT="${LOCAL_PORT:-8123}"
DB_NAME=vidlii
DB_USER=vidlii
DB_PASS=localdevpass

mkdir -p "$DATA" "$ROOT/cache" "$ROOT/usfi/v" "$ROOT/usfi/thmp" \
         "$ROOT/usfi/conv" "$ROOT/usfi/conv_2" "$ROOT/usfi/prvw"

if ! mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; then
  if [ ! -d "$DATA/mysql" ]; then
    mariadb-install-db --datadir="$DATA" --user=root \
      --auth-root-authentication-method=normal --skip-test-db >/dev/null 2>&1
  fi
  mariadbd --user=root --datadir="$DATA" --socket="$SOCKET" --port=3400 \
    --bind-address=127.0.0.1 --skip-name-resolve --performance-schema=OFF \
    --innodb-buffer-pool-size=64M --log-error="$DATA/err.log" &
  for _ in $(seq 1 60); do
    mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1 && break
    sleep 1
  done
fi

if ! mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; then
  echo "[local-run] MariaDB did not start" >&2
  cat "$DATA/err.log" >&2 || true
  exit 1
fi

if ! mariadb --socket="$SOCKET" -u root -e "SELECT 1 FROM ${DB_NAME}.users LIMIT 1" >/dev/null 2>&1; then
  mariadb --socket="$SOCKET" -u root -e \
    "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  mariadb --socket="$SOCKET" -u root "$DB_NAME" < "$ROOT/schema.sql"
  mariadb --socket="$SOCKET" -u root "$DB_NAME" -e \
    "INSERT INTO settings (name, value) VALUES
       ('logo', '0'), ('top_text', ''), ('guidelines', '1'), ('help', '1'),
       ('signup', '1'), ('login', '1'), ('uploader', '1'), ('channels', '1'), ('videos', '1');"
  HASH="$(ADMIN_PASSWORD_IN=localdev php -r 'echo password_hash(getenv("ADMIN_PASSWORD_IN"), PASSWORD_BCRYPT);')"
  mariadb --socket="$SOCKET" -u root "$DB_NAME" -e \
    "INSERT INTO users (username, displayname, email, password, reg_date, last_login, birthday, 1st_latest_ip, country, partner, is_admin, is_mod)
     VALUES ('admin', 'admin', 'admin@example.com', '${HASH}', NOW(), NOW(), '1910-01-01', '127.0.0.1', 'US', 1, 1, 1);"
fi

mariadb --socket="$SOCKET" -u root -e \
  "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
   GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
   FLUSH PRIVILEGES;"

cat > "$ROOT/.env" <<ENV
database = "mysqli://${DB_USER}:${DB_PASS}@127.0.0.1:3400/${DB_NAME}?charset=utf8mb4"
host = "127.0.0.1"
db = "${DB_NAME}"
username = "${DB_USER}"
password = "${DB_PASS}"
title = "VidLii"
slogan = "Display Yourself."
uploadLimit = "2147483648"
language = "en_US"
show_online_count = "1"
ENV

echo "[local-run] serving $ROOT on 127.0.0.1:${PORT}"
export PHP_CLI_SERVER_WORKERS="${PHP_CLI_SERVER_WORKERS:-4}"
exec php -d short_open_tag=On -d display_errors=Off -S "127.0.0.1:${PORT}" -t "$ROOT" "$ROOT/router.php"
