#!/bin/bash
#
# ==============================================================================
#  Zabbix 7.0 production deployment script
#  Backend DB : PostgreSQL (default version shipped with Ubuntu 24.04)
#  Web server : Nginx + PHP-FPM (default versions shipped with Ubuntu 24.04)
#  OS         : Ubuntu 24.04 LTS
# ==============================================================================
#
# Usage:
#   sudo ./deploy_zabbix.sh [options]
#
# Options:
#   -d, --domain <fqdn>   ServerName / SSL CN (default: hostname -f)
#   -t, --timezone <tz>   PHP timezone (default: Europe/Moscow)
#   -e, --email <email>   Contact e-mail put into the self-signed cert
#   -h, --help            Show this help
#
# Run it once, wait for it to finish, open https://<domain>/ and complete
# the Zabbix setup wizard. No other manual steps are required for the
# script itself to be considered successful.
# ==============================================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO. See ${LOG_FILE} for details." >&2' ERR

# ------------------------------------------------------------------------------
# Defaults / configuration
# ------------------------------------------------------------------------------
ZABBIX_MAJOR="7.0"
UBUNTU_CODENAME_PKG="ubuntu24.04"
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

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------
require_root
touch "$LOG_FILE"

log "=== Zabbix ${ZABBIX_MAJOR} deployment starting ==="
log "Domain: ${DOMAIN} | Timezone: ${TIMEZONE}"

if systemctl is-active --quiet zabbix-server 2>/dev/null; then
  log "zabbix-server is already running on this host. Aborting to avoid clobbering an existing install."
  exit 1
fi

DB_PASS="$(gen_password)"

# ------------------------------------------------------------------------------
# System update & base packages (all from standard Ubuntu 24.04 repos)
# ------------------------------------------------------------------------------
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y wget gnupg2 curl ca-certificates ufw

# ------------------------------------------------------------------------------
# Zabbix repository (the one and only external repo we add)
# ------------------------------------------------------------------------------
log "Adding Zabbix ${ZABBIX_MAJOR} repository..."
ZBX_DEB="zabbix-release_${ZABBIX_MAJOR}-1+${UBUNTU_CODENAME_PKG}_all.deb"
TMP_DEB="/tmp/${ZBX_DEB}"
wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_MAJOR}/ubuntu/pool/main/z/zabbix-release/${ZBX_DEB}" -O "${TMP_DEB}"
dpkg -i "${TMP_DEB}"
apt-get update -y

# ------------------------------------------------------------------------------
# Install everything else straight from Ubuntu 24.04 default repos
# ------------------------------------------------------------------------------
log "Installing PostgreSQL, Nginx, PHP-FPM and Zabbix packages..."
apt-get install -y \
  postgresql postgresql-contrib \
  nginx \
  zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent2 \
  php-fpm php-pgsql php-gd php-xml php-bcmath php-mbstring php-ldap php-zip

# Detect what actually got installed instead of assuming a version number.
PG_VERSION="$(ls /etc/postgresql/ | sort -V | tail -n1)"
PHP_VER="$(ls /etc/php/ | sort -V | tail -n1)"
PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
log "Detected PostgreSQL ${PG_VERSION}, PHP ${PHP_VER}"

systemctl enable --now postgresql

# ------------------------------------------------------------------------------
# PostgreSQL: create role + database for Zabbix
# ------------------------------------------------------------------------------
log "Creating PostgreSQL role and database for Zabbix..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  log "Role ${DB_USER} already exists, resetting its password."
  sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';"
else
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  log "Database ${DB_NAME} already exists. Refusing to overwrite it. Aborting."
  exit 1
fi
sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' TEMPLATE template0;"

# Allow the zabbix DB user to authenticate locally via password (unix socket only,
# nothing exposed on the network). If the server and DB ever live on separate
# hosts, add a 'host' line with the correct source CIDR and open TCP 5432
# in the firewall for that specific address only.
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if [ -f "${PG_HBA}" ] && ! grep -q "^local\s\+${DB_NAME}\s\+${DB_USER}\s\+scram-sha-256" "${PG_HBA}"; then
  sed -i "/^# TYPE/a local   ${DB_NAME}   ${DB_USER}   scram-sha-256" "${PG_HBA}"
  systemctl reload postgresql
fi

# ------------------------------------------------------------------------------
# Import Zabbix schema
# ------------------------------------------------------------------------------
log "Importing Zabbix database schema (this can take a few minutes)..."
zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | \
  PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h localhost -d "${DB_NAME}" -q

# ------------------------------------------------------------------------------
# Configure zabbix-server
# ------------------------------------------------------------------------------
log "Configuring /etc/zabbix/zabbix_server.conf..."
ZBX_CONF="/etc/zabbix/zabbix_server.conf"
sed -i "s/^# DBHost=.*/DBHost=localhost/" "${ZBX_CONF}"
sed -i "s/^DBName=.*/DBName=${DB_NAME}/" "${ZBX_CONF}"
sed -i "s/^DBUser=.*/DBUser=${DB_USER}/" "${ZBX_CONF}"
if grep -q "^# DBPassword=" "${ZBX_CONF}"; then
  sed -i "s/^# DBPassword=.*/DBPassword=${DB_PASS}/" "${ZBX_CONF}"
else
  echo "DBPassword=${DB_PASS}" >> "${ZBX_CONF}"
fi

# ------------------------------------------------------------------------------
# Self-signed TLS certificate (safe default, no external service needed).
# If you want a real CA-signed certificate later, drop it into
# /etc/ssl/zabbix/zabbix.crt and .key and restart nginx - nothing else
# in this config needs to change.
# ------------------------------------------------------------------------------
log "Generating self-signed TLS certificate for ${DOMAIN}..."
CERT_DIR="/etc/ssl/zabbix"
mkdir -p "${CERT_DIR}"
openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
  -keyout "${CERT_DIR}/zabbix.key" \
  -out "${CERT_DIR}/zabbix.crt" \
  -subj "/C=RU/ST=Moscow/L=Moscow/O=Zabbix/CN=${DOMAIN}${CERT_EMAIL:+/emailAddress=${CERT_EMAIL}}"
chmod 600 "${CERT_DIR}/zabbix.key"
SSL_CERT="${CERT_DIR}/zabbix.crt"
SSL_KEY="${CERT_DIR}/zabbix.key"

# ------------------------------------------------------------------------------
# Nginx site (uses "listen 443 ssl http2;" - the syntax compatible with the
# nginx 1.24 shipped in Ubuntu 24.04 as well as newer releases).
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
# PHP-FPM timezone
# ------------------------------------------------------------------------------
log "Setting PHP timezone to ${TIMEZONE}..."
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
sed -i "s#^;\?date\.timezone\s*=.*#date.timezone = ${TIMEZONE}#" "${PHP_INI}"

# Zabbix frontend prerequisites check requires these minimums. When running
# under Apache, the zabbix-apache-conf package sets them automatically via
# php_value directives; under Nginx + PHP-FPM nothing does this for us, so
# we set them explicitly in a dedicated conf.d file.
log "Applying Zabbix-required PHP-FPM limits (post_max_size, max_execution_time, max_input_time)..."
cat > "/etc/php/${PHP_VER}/fpm/conf.d/99-zabbix.ini" <<EOF
post_max_size = 16M
max_execution_time = 300
max_input_time = 300
EOF

# ------------------------------------------------------------------------------
# Firewall
# ------------------------------------------------------------------------------
log "Configuring UFW firewall..."
for port in "${FIREWALL_PORTS[@]}"; do
  ufw allow "${port}" >/dev/null
done
ufw --force enable

# ------------------------------------------------------------------------------
# Enable and start everything
# ------------------------------------------------------------------------------
log "Starting services..."
systemctl enable --now "php${PHP_VER}-fpm"
systemctl restart "php${PHP_VER}-fpm"
systemctl enable --now nginx
systemctl restart nginx
systemctl enable --now zabbix-server zabbix-agent2

# ------------------------------------------------------------------------------
# Post-install sanity check
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
# Persist credentials (root-only)
# ------------------------------------------------------------------------------
cat > "${CRED_FILE}" <<EOF
Zabbix deployment credentials - generated $(date)
---------------------------------------------------
PostgreSQL database : ${DB_NAME}
PostgreSQL user     : ${DB_USER}
PostgreSQL password : ${DB_PASS}
Frontend URL        : https://${DOMAIN}/
TLS cert            : ${SSL_CERT}
TLS key             : ${SSL_KEY}

Default web UI login: Admin / zabbix  <-- change this after first login.
EOF
chmod 600 "${CRED_FILE}"

if [ "${ALL_OK}" = "true" ]; then
  log "=== Deployment finished successfully ==="
else
  log "=== Deployment finished WITH ERRORS - see above ==="
  exit 1
fi
log "Frontend: https://${DOMAIN}/"
log "Credentials saved to: ${CRED_FILE}"

