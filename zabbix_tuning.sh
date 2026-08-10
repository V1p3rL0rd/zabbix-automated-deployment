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
set_param "StartPollers" "10"               # Процессы для опроса по Zabbix agent (пассивный)
set_param "StartPollersUnreachable" "3"     # Процессы для недоступных узлов
set_param "StartTrappers" "5"               # Процессы для Zabbix trapper и активных агентов
set_param "StartPingers" "3"                # Процессы для ICMP-проверок (ping)
set_param "StartHTTPPollers" "3"            # Процессы для веб-мониторинга
set_param "StartDBSyncer" "4"               # Процессы сброса данных из кэша в БД

# ------------------------------------------------------------------------------
# Cache Sizes (Кэши)
# ------------------------------------------------------------------------------
set_param "CacheSize" "64M"                 # Кэш конфигурации (узлы, элементы данных, триггеры)
set_param "HistoryCacheSize" "32M"          # Кэш истории перед записью в БД
set_param "HistoryIndexCacheSize" "16M"     # Индексный кэш истории
set_param "TrendCacheSize" "16M"            # Кэш трендов
set_param "ValueCacheSize" "32M"            # Кэш значений для быстрых вычислений триггеров

# ------------------------------------------------------------------------------
# Other operational settings
# ------------------------------------------------------------------------------
set_param "Timeout" "10"                    # Таймаут на опросы (чтобы подвисшие метрики не забивали поллеры)
set_param "HousekeepingFrequency" "1"       # Очистка старых данных каждый час
set_param "MaxHousekeeperDelete" "5000"     # Лимит удаляемых записей за раз (чтобы не грузить БД)

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

