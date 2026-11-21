#!/bin/bash
#
# ==============================================================================
#  Zabbix 7.0 LTS Production Automated Deployment Script
#  Backend DB : PostgreSQL + TimescaleDB (Auto-tuned)
#  Web server : Nginx + PHP-FPM (distro default)
#  OS         : Ubuntu 22.04 / 24.04 LTS (auto-detected)
#
#  Key features:
#   * Fully Idempotent: safe to rerun anytime, resumes cleanly after interruptions
#   * TimescaleDB integration: hypertables, compression and auto-tuned PG
#   * Headless Setup: auto-generates zabbix.conf.php (no manual web wizard)
#   * Standalone-ready: designed for independent nodes in internal network
# ==============================================================================
#
# Usage:
#   sudo ./zabbix_deploy.sh [options]
#
# Options:
#   -d, --domain <fqdn>   ServerName / SSL CN (default: hostname -f)
#   -t, --timezone <tz>   PHP timezone (default: Europe/Moscow)
#   -e, --email <email>   Contact e-mail put into the self-signed cert
#   -h, --help            Show this help
# ==============================================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO. See ${LOG_FILE} for details." >&2' ERR

# ------------------------------------------------------------------------------
# Defaults / configuration
# ------------------------------------------------------------------------------
ZABBIX_MAJOR="7.0"
SUPPORTED_UBUNTU=("22.04" "24.04")
DB_NAME="zabbix"
DB_USER="zabbix"
DOMAIN="$(hostname -f 2>/dev/null || hostname)"
TIMEZONE="Europe/Moscow"
CERT_EMAIL=""
LOG_FILE="/var/log/zabbix-deploy.log"
CRED_FILE="/root/.zabbix_deploy_credentials"
FIREWALL_PORTS=("22/tcp" "80/tcp" "443/tcp" "10051/tcp")

# ------------------------------------------------------------------------------
# Arg parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain) DOMAIN="$2"; shift 2 ;;
    -t|--timezone) TIMEZONE="$2"; shift 2 ;;
    -e|--email) CERT_EMAIL="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

gen_password() {
  openssl rand -base64 24 | tr -d '/+=' | cut -c1-24
}

set_zbx_param() {
  local file="$1"
  local param="$2"
  local val="$3"
  if grep -q "^#\?\s*${param}=" "${file}"; then
    sed -i "s|^#\?\s*${param}=.*|${param}=${val}|" "${file}"
  else
    echo "${param}=${val}" >> "${file}"
  fi
}

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------
require_root
touch "$LOG_FILE"

# Detect OS
# shellcheck source=/dev/null
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]] || [[ " ${SUPPORTED_UBUNTU[*]} " != *" ${VERSION_ID:-} "* ]]; then
  log "Unsupported OS: ${PRETTY_NAME:-unknown}. Supported Ubuntu: ${SUPPORTED_UBUNTU[*]}"
  exit 1
fi
UBUNTU_CODENAME_PKG="ubuntu${VERSION_ID}"
log "Detected OS: ${PRETTY_NAME} (${VERSION_CODENAME})"
log "=== Zabbix ${ZABBIX_MAJOR} deployment starting ==="
log "Domain: ${DOMAIN} | Timezone: ${TIMEZONE}"

if systemctl is-active --quiet zabbix-server 2>/dev/null; then
  log "Notice: zabbix-server is already active. Running in re-configuration / idempotence mode."
fi

# IDEMPOTENCE: reuse existing DB password if previous run generated one
if [ -f "${CRED_FILE}" ] && grep -q "PostgreSQL password" "${CRED_FILE}"; then
  DB_PASS=$(grep "PostgreSQL password" "${CRED_FILE}" | awk -F': ' '{print $2}' | tr -d '[:space:]')
  log "Existing credentials file found. Reusing database password."
else
  DB_PASS="$(gen_password)"
fi

# ------------------------------------------------------------------------------
# System update & base packages
# ------------------------------------------------------------------------------
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y wget gnupg2 curl ca-certificates ufw lsb-release apt-transport-https

# ------------------------------------------------------------------------------
# Zabbix official repository
# ------------------------------------------------------------------------------
log "Checking Zabbix ${ZABBIX_MAJOR} repository..."
ZBX_DEB="zabbix-release_latest_${ZABBIX_MAJOR}+${UBUNTU_CODENAME_PKG}_all.deb"
TMP_DEB="/tmp/${ZBX_DEB}"

# Clean stale / conflicting repo definitions if necessary
if ! dpkg-query -W -f='${Status}' zabbix-release 2>/dev/null | grep -q "ok installed"; then
  log "Adding Zabbix repository package..."
  if ! wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_MAJOR}/ubuntu/pool/main/z/zabbix-release/${ZBX_DEB}" -O "${TMP_DEB}"; then
    log "Cannot download ${ZBX_DEB}: no Zabbix ${ZABBIX_MAJOR} repo for ${PRETTY_NAME}."
    exit 1
  fi
  dpkg -i "${TMP_DEB}"
  rm -f "${TMP_DEB}"
fi

# ------------------------------------------------------------------------------
# PostgreSQL base installation
# ------------------------------------------------------------------------------
log "Installing PostgreSQL..."
apt-get update -y
apt-get install -y postgresql postgresql-contrib

# Detect PostgreSQL major version (14 on Ubuntu 22.04, 16 on 24.04)
PG_VERSION="$(ls /etc/postgresql/ | sort -V | tail -n1)"
log "Detected PostgreSQL version: ${PG_VERSION}"
systemctl enable --now postgresql

# ------------------------------------------------------------------------------
# TimescaleDB repository & installation
# ------------------------------------------------------------------------------
log "Setting up TimescaleDB repository for PostgreSQL ${PG_VERSION}..."
install -d -m 0755 /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/timescaledb.gpg ]; then
  curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /etc/apt/keyrings/timescaledb.gpg
fi

TS_LIST="/etc/apt/sources.list.d/timescaledb.list"
echo "deb [signed-by=/etc/apt/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ ${VERSION_CODENAME} main" > "${TS_LIST}"
apt-get update -y

TS_PACKAGE="timescaledb-2-postgresql-${PG_VERSION}"
if apt-cache show "${TS_PACKAGE}" >/dev/null 2>&1; then
  log "Installing ${TS_PACKAGE} and timescaledb-tools..."
  apt-get install -y "${TS_PACKAGE}" timescaledb-tools

  # Auto-tune PostgreSQL configuration for TimescaleDB and available hardware
  log "Tuning PostgreSQL for TimescaleDB via timescaledb-tune..."
  timescaledb-tune --quiet --yes --pg-version="${PG_VERSION}" || timescaledb-tune --quiet --yes
  systemctl restart postgresql
  USE_TIMESCALEDB=true
else
  log "WARNING: Package ${TS_PACKAGE} not found in repository. Proceeding without TimescaleDB extension."
  USE_TIMESCALEDB=false
fi

# ------------------------------------------------------------------------------
# Install Zabbix components, Nginx, PHP-FPM
# ------------------------------------------------------------------------------
log "Installing Zabbix components, Nginx and PHP-FPM..."
apt-get install -y \
  nginx \
  zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent2 \
  php-fpm php-pgsql php-gd php-xml php-bcmath php-mbstring php-ldap php-zip

PHP_VER="$(ls /etc/php/ | sort -V | tail -n1)"
PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
log "Detected PHP version: ${PHP_VER}"

# ------------------------------------------------------------------------------
# PostgreSQL: user & database initialization (Idempotent)
# ------------------------------------------------------------------------------
log "Configuring PostgreSQL user and database..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  log "PostgreSQL role '${DB_USER}' exists, updating password."
  sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';"
else
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  log "Database '${DB_NAME}' already exists. Skipping database creation."
else
  sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' TEMPLATE template0;"
fi

# Local socket auth via scram-sha-256
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if [ -f "${PG_HBA}" ]; then
  if ! grep -qE "^local\s+${DB_NAME}\s+${DB_USER}\s+scram-sha-256" "${PG_HBA}"; then
    sed -i "/^# TYPE/a local   ${DB_NAME}   ${DB_USER}   scram-sha-256" "${PG_HBA}"
    systemctl reload postgresql
  fi
fi

# Enable TimescaleDB extension in the database
if [ "${USE_TIMESCALEDB}" = "true" ]; then
  log "Enabling TimescaleDB extension in database '${DB_NAME}'..."
  sudo -u postgres psql -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
fi

# ------------------------------------------------------------------------------
# Database Schema Import & TimescaleDB Hypertables (Idempotent)
# ------------------------------------------------------------------------------
SCHEMA_EXISTS=$(sudo -u postgres psql -d "${DB_NAME}" -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='users'" 2>/dev/null || true)
if [ "${SCHEMA_EXISTS}" != "1" ]; then
  log "Importing Zabbix base database schema (this may take a couple of minutes)..."
  zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | \
    PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h localhost -d "${DB_NAME}" -q
  log "Base schema imported successfully."
else
  log "Zabbix base schema is already present. Skipping base schema import."
fi

# Apply TimescaleDB hypertable schema if TimescaleDB is enabled
if [ "${USE_TIMESCALEDB}" = "true" ]; then
  TS_HYPERTABLE_EXISTS=$(sudo -u postgres psql -d "${DB_NAME}" -tAc "SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name='history'" 2>/dev/null || true)
  if [ "${TS_HYPERTABLE_EXISTS}" != "1" ]; then
    log "Applying TimescaleDB schema for Zabbix hypertables and compression..."
    TS_SQL=""
    if [ -f "/usr/share/zabbix-sql-scripts/postgresql/timescaledb/schema.sql" ]; then
      TS_SQL="/usr/share/zabbix-sql-scripts/postgresql/timescaledb/schema.sql"
    elif [ -f "/usr/share/zabbix-sql-scripts/postgresql/timescaledb.sql" ]; then
      TS_SQL="/usr/share/zabbix-sql-scripts/postgresql/timescaledb.sql"
    fi

    if [ -n "${TS_SQL}" ]; then
      PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h localhost -d "${DB_NAME}" -f "${TS_SQL}" -q
      log "TimescaleDB schema applied successfully."
    else
      log "WARNING: TimescaleDB schema SQL script not found in /usr/share/zabbix-sql-scripts/postgresql/!"
    fi
  else
    log "TimescaleDB hypertables already configured. Skipping TimescaleDB schema import."
  fi
fi

# ------------------------------------------------------------------------------
# Configure zabbix-server
# ------------------------------------------------------------------------------
log "Configuring /etc/zabbix/zabbix_server.conf..."
ZBX_CONF="/etc/zabbix/zabbix_server.conf"
set_zbx_param "${ZBX_CONF}" "DBHost" "localhost"
set_zbx_param "${ZBX_CONF}" "DBName" "${DB_NAME}"
set_zbx_param "${ZBX_CONF}" "DBUser" "${DB_USER}"
set_zbx_param "${ZBX_CONF}" "DBPassword" "${DB_PASS}"

# ------------------------------------------------------------------------------
# TLS Certificate (Self-signed, Idempotent)
# ------------------------------------------------------------------------------
CERT_DIR="/etc/ssl/zabbix"
SSL_CERT="${CERT_DIR}/zabbix.crt"
SSL_KEY="${CERT_DIR}/zabbix.key"

if [ -f "${SSL_CERT}" ] && [ -f "${SSL_KEY}" ]; then
  log "Existing TLS certificate and key found at ${CERT_DIR}. Skipping certificate generation."
else
  log "Generating self-signed TLS certificate for ${DOMAIN}..."
  mkdir -p "${CERT_DIR}"
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "${SSL_KEY}" \
    -out "${SSL_CERT}" \
    -subj "/C=RU/ST=Moscow/L=Moscow/O=Zabbix/CN=${DOMAIN}${CERT_EMAIL:+/emailAddress=${CERT_EMAIL}}"
  chmod 600 "${SSL_KEY}"
fi

# ------------------------------------------------------------------------------
# Nginx site configuration
# ------------------------------------------------------------------------------
log "Configuring Nginx..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

cat > /etc/nginx/conf.d/zabbix.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    root /usr/share/zabbix;
    index index.php;

    access_log /var/log/nginx/zabbix_access.log;
    error_log  /var/log/nginx/zabbix_error.log;

    client_max_body_size 16M;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "date.timezone=${TIMEZONE}";
    }

    location /assets {
        access_log off;
        expires 10d;
    }
}
EOF

nginx -t

# ------------------------------------------------------------------------------
# PHP-FPM Configuration
# ------------------------------------------------------------------------------
log "Setting PHP timezone to ${TIMEZONE}..."
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
sed -i "s#^;\?date\.timezone\s*=.*#date.timezone = ${TIMEZONE}#" "${PHP_INI}"

log "Applying Zabbix-required PHP-FPM limits..."
cat > "/etc/php/${PHP_VER}/fpm/conf.d/99-zabbix.ini" <<EOF
post_max_size = 16M
max_execution_time = 300
max_input_time = 300
EOF

# ------------------------------------------------------------------------------
# Automated Web Frontend Configuration (No Manual Web Wizard needed!)
# ------------------------------------------------------------------------------
log "Generating /etc/zabbix/web/zabbix.conf.php..."
mkdir -p /etc/zabbix/web
cat > /etc/zabbix/web/zabbix.conf.php <<EOF
<?php
// Zabbix GUI configuration file generated by zabbix_deploy.sh
global \$DB;

\$DB['TYPE']     = 'POSTGRESQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = '${DB_NAME}';
\$DB['USER']     = '${DB_USER}';
\$DB['PASSWORD'] = '${DB_PASS}';

// Schema name (relevant for PostgreSQL)
\$DB['SCHEMA']   = '';

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '${DOMAIN}';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF
chown -R www-data:www-data /etc/zabbix/web
chmod 640 /etc/zabbix/web/zabbix.conf.php

# ------------------------------------------------------------------------------
# Firewall
# ------------------------------------------------------------------------------
log "Configuring UFW firewall..."
for port in "${FIREWALL_PORTS[@]}"; do
  ufw allow "${port}" >/dev/null
done
ufw --force enable

# ------------------------------------------------------------------------------
# Enable and start services
# ------------------------------------------------------------------------------
log "Starting and enabling services..."
systemctl enable --now "php${PHP_VER}-fpm"
systemctl restart "php${PHP_VER}-fpm"
systemctl enable --now nginx
systemctl restart nginx
systemctl enable --now zabbix-server zabbix-agent2
systemctl restart zabbix-server zabbix-agent2

# ------------------------------------------------------------------------------
# Sanity check
# ------------------------------------------------------------------------------
sleep 3
ALL_OK=true
for svc in postgresql nginx "php${PHP_VER}-fpm" zabbix-server zabbix-agent2; do
  if systemctl is-active --quiet "${svc}"; then
    log "OK: ${svc} is running."
  else
    log "FAILED: ${svc} is not running. Check 'journalctl -u ${svc}'."
    ALL_OK=false
  fi
done

# ------------------------------------------------------------------------------
# Persist credentials
# ------------------------------------------------------------------------------
cat > "${CRED_FILE}" <<EOF
Zabbix deployment credentials - updated $(date)
---------------------------------------------------
PostgreSQL database : ${DB_NAME}
PostgreSQL user     : ${DB_USER}
PostgreSQL password : ${DB_PASS}
TimescaleDB active  : ${USE_TIMESCALEDB}
Frontend URL        : https://${DOMAIN}/
TLS cert            : ${SSL_CERT}
TLS key             : ${SSL_KEY}

Default web UI login: Admin / zabbix  (CHANGE THIS IMMEDIATELY AFTER FIRST LOGIN!)
EOF
chmod 600 "${CRED_FILE}"

if [ "${ALL_OK}" = "true" ]; then
  log "=== Deployment finished successfully ==="
else
  log "=== Deployment finished WITH ERRORS - see above ==="
  exit 1
fi
log "Frontend URL: https://${DOMAIN}/"
log "Credentials file: ${CRED_FILE}"
