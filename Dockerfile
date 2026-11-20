FROM php:8.4-cli-alpine

# OS packages + PHP extensions required by VidLii (intl, gd, mysqli, zip) and MariaDB for the database
RUN echo "os-refresh 2026-11-20" \
 && apk upgrade --no-cache \
 && apk add --no-cache \
      bash \
      icu-dev \
      libpng-dev \
      libjpeg-turbo-dev \
      freetype-dev \
      libzip-dev \
      mariadb \
      mariadb-client \
      ffmpeg \
      tzdata

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" intl gd mysqli pdo_mysql zip opcache

# VidLii relies on short open tags (<? ?>) and large video uploads
RUN printf '%s\n' \
      'short_open_tag=On' \
      'display_errors=Off' \
      'log_errors=On' \
      'error_log=/dev/stderr' \
      'upload_max_filesize=2048M' \
      'post_max_size=2048M' \
      'memory_limit=512M' \
      'max_execution_time=900' \
      'date.timezone=UTC' \
      > /usr/local/etc/php/conf.d/vidlii.ini

ENV PORT=3000 \
    PHP_CLI_SERVER_WORKERS=4

WORKDIR /var/www/html

COPY . /var/www/html
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
 && adduser -D -u 10001 app \
 && mkdir -p /var/www/html/cache \
      /var/www/html/usfi/v /var/www/html/usfi/thmp /var/www/html/usfi/conv \
      /var/www/html/usfi/conv_2 /var/www/html/usfi/prvw \
      /run/mysqld /var/lib/mysql \
 && chown -R app:app /var/www/html /run/mysqld /var/lib/mysql \
 && mariadb-install-db --user=app --datadir=/var/lib/mysql \
      --auth-root-authentication-method=normal --skip-test-db >/dev/null

USER app

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
