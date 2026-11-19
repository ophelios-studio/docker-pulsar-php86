FROM php:8.6.0-apache-bookworm

# Install utilities and libraries. No package brings its recommendations along (that alone kept exim4, a setuid MTA,
# and openssh-client in the image), and the Debian packages of the official image are brought up to date first, so
# the weekly rebuild takes their security fixes even before the official image is rebuilt. Each apt step empties the
# package lists it downloaded.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    && apt-get install -y --no-install-recommends \
    apt-utils gnupg lsb-release ca-certificates wget build-essential cron git curl zip unzip openssl dialog locales \
    libonig-dev libcurl4 libcurl4-openssl-dev supervisor libsqlite3-dev libsqlite3-0 zlib1g-dev libzip-dev libpq-dev libicu-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# Install composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# The official PHP 8.6 images ship without pecl: every PECL extension is built from source (phpize, configure, make).
# APCu: the latest PECL release (5.1.28) does not compile on PHP 8.6, so a pinned upstream commit is built instead.
# Replace it with a PECL release once one builds on 8.6.
ARG APCU_COMMIT=fb2c942552a3f5dab7f4dea4afb5cf0831222c57
RUN set -eu; \
    mkdir /tmp/apcu && cd /tmp/apcu; \
    curl -fsSL "https://github.com/krakjoe/apcu/archive/${APCU_COMMIT}.tar.gz" | tar -xz --strip-components=1; \
    phpize && ./configure && make -j"$(nproc)" && make install; \
    docker-php-ext-enable apcu --ini-name docker-php-ext-apcu.ini; \
    rm -rf /tmp/apcu

# Install Freetype and GD extensions
RUN docker-php-ext-configure gd --enable-gd --with-freetype --with-jpeg
RUN docker-php-ext-install gd

# Install PHP extensions
RUN docker-php-ext-install pdo_pgsql && \
    docker-php-ext-install pgsql && \
    docker-php-ext-install curl && \
    docker-php-ext-install zip && \
    docker-php-ext-install intl && \
    docker-php-ext-install xml && \
    docker-php-ext-install mbstring && \
    docker-php-ext-install exif && \
    docker-php-ext-install gettext

# Install ssh2
RUN apt-get update && apt-get install -y --no-install-recommends \
    git libssh2-1 libssh2-1-dev \
    && rm -rf /var/lib/apt/lists/*
# ssh2 1.3.1 is a PECL release, downloaded as a tarball because pecl is missing. Newer releases need libssh2 >= 1.11,
# and Bookworm ships 1.10.
ARG SSH2_VERSION=1.3.1
RUN set -eu; \
    mkdir /tmp/ssh2 && cd /tmp/ssh2; \
    curl -fsSL "https://pecl.php.net/get/ssh2-${SSH2_VERSION}" | tar -xz --strip-components=1; \
    phpize && ./configure && make -j"$(nproc)" && make install; \
    docker-php-ext-enable ssh2; \
    rm -rf /tmp/ssh2

RUN apt-get update && \
    apt-get install -y --no-install-recommends libgmp-dev && \
    rm -rf /var/lib/apt/lists/*
RUN docker-php-ext-install gmp

# Install xdebug (but do not activate it)
# The latest Xdebug release refuses PHP 8.6 at configure time, so a pinned upstream commit (3.6.0alpha2-dev) is built.
# Replace it with a release once one supports 8.6.
ARG XDEBUG_COMMIT=85f513aca01e2edb9b854b6c1bb0f550e62f887b
RUN set -eu; \
    mkdir /tmp/xdebug && cd /tmp/xdebug; \
    curl -fsSL "https://github.com/xdebug/xdebug/archive/${XDEBUG_COMMIT}.tar.gz" | tar -xz --strip-components=1; \
    phpize && ./configure --enable-xdebug && make -j"$(nproc)" && make install; \
    rm -rf /tmp/xdebug
RUN docker-php-ext-enable xdebug
RUN cd /usr/local/etc/php/ && mkdir -p disabled/ && mv conf.d/docker-php-ext-xdebug.ini disabled/

# Enable apache modules. mod_status is turned off: nothing reads /server-status, and a single line of configuration
# would otherwise reopen the request line of every request in flight. The build fails if it is still enabled.
RUN a2enmod rewrite headers expires ssl \
    && a2dismod status \
    && test ! -e /etc/apache2/mods-enabled/status.load

# Install SSL certificates (self-signed)
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/apache-selfsigned.key -out /etc/ssl/certs/apache-selfsigned.crt -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

# Install french language locale
RUN locale-gen en_CA.UTF-8
RUN locale-gen fr_CA.UTF-8
RUN update-locale

# Install cleanup
RUN rm -rf /usr/src/*

# Timezone
ENV TZ="America/Montreal"

# Mailcatcher
RUN apt-get update && apt-get install -y --no-install-recommends rubygems ruby-dev sqlite3 \
    && rm -rf /var/lib/apt/lists/*
RUN gem install mailcatcher --no-document

# Copy specific php.ini directives
COPY custom.ini /usr/local/etc/php/conf.d/base-custom.ini
COPY php2shell.ini /usr/local/etc/php/conf.d/zz-php2shell.ini

# Default virtual hosts (https self signed)
COPY vhosts/default.conf /etc/apache2/sites-enabled/default.conf
COPY vhosts/default-ssl.conf /etc/apache2/sites-enabled/default-ssl.conf

# AllowEncodedSlashes is not inherited from the server config into a <VirtualHost>, so it must sit inside every one,
# or a path holding %2F (an encoded slash in a route parameter) gets Apache's own HTML 404 before PHP runs. The two
# vhosts above carry it; Debian's 000-default.conf, still enabled and first on port 80, gets it here. The build fails
# if any enabled <VirtualHost> is left without it (a downstream image adding its own vhost must add the line too).
RUN set -eu; \
    sed -i --follow-symlinks 's#^\([[:space:]]*<VirtualHost[^>]*>\)[[:space:]]*$#\1\n\tAllowEncodedSlashes NoDecode#' \
        /etc/apache2/sites-enabled/000-default.conf; \
    total="$(grep -hciE '^[[:space:]]*<VirtualHost[[:space:]>]' /etc/apache2/sites-enabled/*.conf | awk '{n += $1} END {print n + 0}')"; \
    test "$total" -gt 0 || { echo "no <VirtualHost> is enabled" >&2; exit 1; }; \
    for vhost in /etc/apache2/sites-enabled/*.conf; do \
        vhosts="$(grep -ciE '^[[:space:]]*<VirtualHost[[:space:]>]' "$vhost" || true)"; \
        patched="$(grep -ciE '^[[:space:]]*AllowEncodedSlashes[[:space:]]+NoDecode[[:space:]]*$' "$vhost" || true)"; \
        test "$vhosts" = "$patched" || { echo "$vhost: $vhosts <VirtualHost>, $patched AllowEncodedSlashes NoDecode" >&2; exit 1; }; \
    done; \
    apache2ctl -t

# Apache names its release and distribution ("Apache/2.4.62 (Debian)") in the Server header of every response and at
# the foot of its own error pages, because Debian's security.conf ships ServerTokens OS and ServerSignature On. They
# are rewritten in that file rather than overridden from another one, so each has a single value. The build fails
# unless the enabled configuration holds exactly ServerTokens Prod and ServerSignature Off.
RUN set -eu; \
    sed -i \
        -e 's#^[[:space:]]*ServerTokens[[:space:]].*$#ServerTokens Prod#I' \
        -e 's#^[[:space:]]*ServerSignature[[:space:]].*$#ServerSignature Off#I' \
        /etc/apache2/conf-available/security.conf; \
    active="$(grep -hiE '^[[:space:]]*Server(Tokens|Signature)[[:space:]]' /etc/apache2/apache2.conf \
        /etc/apache2/conf-enabled/*.conf /etc/apache2/sites-enabled/*.conf | sed 's#^[[:space:]]*##; s#[[:space:]]*$##' | sort -u)"; \
    test "$active" = "$(printf 'ServerSignature Off\nServerTokens Prod')" || { echo "Server directives: $active" >&2; exit 1; }; \
    apache2ctl -t

# Configure and run Supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
# The build fails unless every extension loaded by the PHP 8.4 image is loaded here, and Xdebug loads when enabled.
# PHP 8.6 merged or dropped nothing from this list.
RUN set -eu; \
    loaded="$(php -m | tr 'A-Z' 'a-z')"; \
    for ext in apcu core ctype curl date dom exif fileinfo filter gd gettext gmp hash iconv intl json libxml mbstring \
        mysqlnd openssl pcre pdo pdo_pgsql pdo_sqlite pgsql phar posix random readline reflection session simplexml \
        sodium spl sqlite3 ssh2 standard tokenizer xml xmlreader xmlwriter "zend opcache" zip zlib; do \
        printf '%s\n' "$loaded" | grep -qxF "$ext" || { echo "extension not loaded: $ext" >&2; exit 1; }; \
    done; \
    php -d zend_extension=xdebug.so -v | grep -q Xdebug || { echo "xdebug does not load" >&2; exit 1; }

EXPOSE 80 1080
CMD ["/usr/bin/supervisord"]
