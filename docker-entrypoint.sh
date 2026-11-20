#!/bin/bash
# Starts the bundled MariaDB, prepares the VidLii database on first boot,
# then runs the PHP server on $PORT.
set -euo pipefail

ROOT=/var/www/html
PORT="${PORT:-3000}"
SOCKET=/run/mysqld/mysqld.sock
DB_NAME=vidlii
DB_USER=vidlii
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-vidlii-admin-2025}"
SITE_TITLE="${SITE_TITLE:-VidLii}"
SITE_SLOGAN="${SITE_SLOGAN:-Display Yourself.}"

# Random per-boot database password (kept only inside this container)
DB_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"

mkdir -p /run/mysqld "$ROOT/cache" "$ROOT/usfi/v" "$ROOT/usfi/thmp" \
         "$ROOT/usfi/conv" "$ROOT/usfi/conv_2" "$ROOT/usfi/prvw"

# Fresh data directory (first boot only)
if [ ! -d /var/lib/mysql/mysql ]; then
  echo "[entrypoint] initializing MariaDB data directory"
  mariadb-install-db --datadir=/var/lib/mysql \
    --auth-root-authentication-method=normal --skip-test-db >/dev/null
fi

echo "[entrypoint] starting MariaDB"
mariadbd --datadir=/var/lib/mysql --socket="$SOCKET" \
  --pid-file=/run/mysqld/mysqld.pid --port=3306 --bind-address=127.0.0.1 \
  --skip-name-resolve --performance-schema=OFF \
  --innodb-buffer-pool-size=64M --log-error=/run/mysqld/mariadb.err &

for _ in $(seq 1 60); do
  if mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; then break; fi
  sleep 1
done

if ! mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; then
  echo "[entrypoint] MariaDB failed to start:" >&2
  cat /run/mysqld/mariadb.err >&2 || true
  exit 1
fi

# Import the schema once (detected by the presence of the users table)
if ! mariadb --socket="$SOCKET" -u root -e "SELECT 1 FROM ${DB_NAME}.users LIMIT 1" >/dev/null 2>&1; then
  echo "[entrypoint] importing schema"
  mariadb --socket="$SOCKET" -u root -e \
    "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  mariadb --socket="$SOCKET" -u root "$DB_NAME" < "$ROOT/schema.sql"

  mariadb --socket="$SOCKET" -u root "$DB_NAME" -e \
    "INSERT INTO options (option_name, value) VALUES ('title', '${SITE_TITLE}'), ('slogan', '${SITE_SLOGAN}');
     INSERT INTO settings (name, value) VALUES
       ('logo', '0'), ('top_text', ''), ('guidelines', '1'), ('help', '1'),
       ('signup', '1'), ('login', '1'), ('uploader', '1'), ('channels', '1'), ('videos', '1');"

  HASH="$(ADMIN_PASSWORD_IN="$ADMIN_PASSWORD" php -r 'echo password_hash(getenv("ADMIN_PASSWORD_IN"), PASSWORD_BCRYPT);' 2>/dev/null || true)"
  if [ -z "$HASH" ]; then
    echo "[entrypoint] could not hash admin password" >&2
    exit 1
  fi
  mariadb --socket="$SOCKET" -u root "$DB_NAME" -e \
    "INSERT INTO users (username, displayname, email, password, reg_date, last_login, birthday, 1st_latest_ip, country, partner, is_admin, is_mod)
     VALUES ('${ADMIN_USER}', '${ADMIN_USER}', '${ADMIN_USER}@example.com', '${HASH}', NOW(), NOW(), '1910-01-01', '127.0.0.1', 'US', 1, 1, 1);"
  echo "[entrypoint] database ready"
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
language = "en"
show_online_count = "1"
EOF

echo "[entrypoint] starting PHP server on 0.0.0.0:${PORT}"
exec php -S "0.0.0.0:${PORT}" -t "$ROOT" "$ROOT/router.php"
