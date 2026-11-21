#!/bin/bash
#
# ==============================================================================
# Zabbix Server Performance & OS Tuning Script
# Optimized for standalone nodes with PostgreSQL + TimescaleDB (~100-300 hosts)
# OS : Ubuntu 22.04 / 24.04 LTS / Zabbix 7.0 LTS
# ==============================================================================
set -euo pipefail
trap 'echo "[ERROR] Tuning script failed at line $LINENO." >&2' ERR

CONF_FILE="/etc/zabbix/zabbix_server.conf"
ORIG_BACKUP_FILE="/etc/zabbix/zabbix_server.conf.orig"
LAST_BACKUP_FILE="/etc/zabbix/zabbix_server.conf.bak"

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

if [ ! -f "${CONF_FILE}" ]; then
    echo "[ERROR] ${CONF_FILE} not found!" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Idempotent Backup
# ------------------------------------------------------------------------------
if [ ! -f "${ORIG_BACKUP_FILE}" ]; then
    echo "[INFO] Creating original backup ${ORIG_BACKUP_FILE}..."
    cp "${CONF_FILE}" "${ORIG_BACKUP_FILE}"
else
    echo "[INFO] Updating temporary backup ${LAST_BACKUP_FILE}..."
    cp "${CONF_FILE}" "${LAST_BACKUP_FILE}"
fi

# ------------------------------------------------------------------------------
# Helper function to set or uncomment parameters
# ------------------------------------------------------------------------------
set_param() {
    local param="$1"
    local value="$2"
    if grep -q "^#\?\s*${param}=" "${CONF_FILE}"; then
        sed -i "s|^#\?\s*${param}=.*|${param}=${value}|" "${CONF_FILE}"
    else
        echo "${param}=${value}" >> "${CONF_FILE}"
    fi
}

echo "[INFO] Applying kernel sysctl parameters..."
cat > /etc/sysctl.d/99-zabbix.conf <<EOF
# Zabbix & PostgreSQL tuning
vm.overcommit_memory = 1
fs.file-max = 2097152
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl -p /etc/sysctl.d/99-zabbix.conf >/dev/null || true

echo "[INFO] Applying Zabbix Server performance parameters..."

# ------------------------------------------------------------------------------
# Worker processes (Pollers & Trappers)
# ------------------------------------------------------------------------------
set_param "StartPollers" "15"               # Passive agent pollers
set_param "StartPollersUnreachable" "5"     # Unreachable hosts checks
set_param "StartTrappers" "10"              # Active agent & sender trappers
set_param "StartPingers" "5"                # ICMP pingers
set_param "StartHTTPPollers" "5"            # Web scenario pollers
set_param "StartDBSyncers" "4"              # Flushing data to DB
set_param "StartDiscoverers" "2"            # Network discovery

# ------------------------------------------------------------------------------
# Internal Cache Sizes
# ------------------------------------------------------------------------------
set_param "CacheSize" "128M"                # Configuration cache (hosts, items, triggers)
set_param "HistoryCacheSize" "64M"          # History cache
set_param "HistoryIndexCacheSize" "32M"     # History index cache
set_param "TrendCacheSize" "32M"            # Trend cache
set_param "ValueCacheSize" "64M"            # Value cache for triggers

# ------------------------------------------------------------------------------
# Operational settings
# ------------------------------------------------------------------------------
set_param "Timeout" "10"                    # Poll timeout
set_param "HousekeepingFrequency" "1"       # Hour frequency for non-hypertable cleanups
set_param "MaxHousekeeperDelete" "5000"     # Batch delete size

# ------------------------------------------------------------------------------
# Restart Zabbix Server
# ------------------------------------------------------------------------------
echo "[INFO] Restarting zabbix-server..."
systemctl restart zabbix-server
sleep 2

if systemctl is-active --quiet zabbix-server; then
    echo "[SUCCESS] Zabbix Server configuration updated and service is running normally!"
else
    echo "[ERROR] Zabbix Server failed to start! Check 'journalctl -u zabbix-server'." >&2
    echo "[INFO] Restoring previous configuration..."
    if [ -f "${LAST_BACKUP_FILE}" ]; then
        cp "${LAST_BACKUP_FILE}" "${CONF_FILE}"
    else
        cp "${ORIG_BACKUP_FILE}" "${CONF_FILE}"
    fi
    systemctl restart zabbix-server
    exit 1
fi
