#!/bin/bash
#
# ==============================================================================
# Zabbix Server Performance Tuning Script (~100 hosts)
# OS : Ubuntu 24.04 LTS / Zabbix 7.0 LTS
# ==============================================================================
set -euo pipefail
trap 'echo "[ERROR] Tuning script failed at line $LINENO." >&2' ERR

CONF_FILE="/etc/zabbix/zabbix_server.conf"
BACKUP_FILE="/etc/zabbix/zabbix_server.conf.bak_$(date +%Y%m%d_%H%M%S)"

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

if [ ! -f "${CONF_FILE}" ]; then
    echo "[ERROR] ${CONF_FILE} not found!" >&2
    exit 1
fi

echo "[INFO] Creating backup of ${CONF_FILE} -> ${BACKUP_FILE}..."
cp "${CONF_FILE}" "${BACKUP_FILE}"

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

echo "[INFO] Applying performance parameters for ~100 hosts..."

# ------------------------------------------------------------------------------
# Process count configuration (Workers / Pollers)
# ------------------------------------------------------------------------------
set_param "StartPollers" "10"               # Processes for polling via Zabbix agent (passive)
set_param "StartPollersUnreachable" "3"     # Processes for unreachable hosts
set_param "StartTrappers" "5"               # Processes for Zabbix trapper and active agents
set_param "StartPingers" "3"                # Processes for ICMP checks (ping)
set_param "StartHTTPPollers" "3"            # Processes for web monitoring
set_param "StartDBSyncers" "4"              # Processes flushing cached data to the DB

# ------------------------------------------------------------------------------
# Cache Sizes
# ------------------------------------------------------------------------------
set_param "CacheSize" "64M"                 # Configuration cache (hosts, items, triggers)
set_param "HistoryCacheSize" "32M"          # History cache before writing to DB
set_param "HistoryIndexCacheSize" "16M"     # History index cache
set_param "TrendCacheSize" "16M"            # Trend cache
set_param "ValueCacheSize" "32M"            # Value cache for fast trigger calculations

# ------------------------------------------------------------------------------
# Other operational settings
# ------------------------------------------------------------------------------
set_param "Timeout" "10"                    # Poll timeout (prevents stuck checks from clogging pollers)
set_param "HousekeepingFrequency" "1"       # Clean up old data every hour
set_param "MaxHousekeeperDelete" "5000"     # Max records deleted per batch (avoids overloading the DB)

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
    echo "[INFO] Restoring backup..."
    cp "${BACKUP_FILE}" "${CONF_FILE}"
    systemctl restart zabbix-server
    exit 1
fi
