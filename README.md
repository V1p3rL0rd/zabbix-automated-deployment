# zabbix-automated-deployment
# 🚀 Zabbix 7.0 LTS Production Automated Deployment & Tuning

Automated Bash scripts for deploying and fine-tuning **Zabbix 7.0 LTS** on **Ubuntu 24.04 LTS** using PostgreSQL, Nginx, and PHP-FPM.

---

## 📌 Features

* **Zero-dependency deployment**: Installs PostgreSQL, Nginx, PHP-FPM, Zabbix Server, and Agent 2 directly from standard Ubuntu 24.04 & official Zabbix repositories.
* **Security out-of-the-box**: Auto-generates SSL/TLS self-signed certificates and configures HTTPS redirect.
* **Automatic Fixes**: Pre-configures required PHP limits (`post_max_size`, `max_execution_time`, `max_input_time`) and reloads PHP-FPM cleanly.
* **Credentials Storage**: Automatically saves generated database passwords to `/root/.zabbix_deploy_credentials`.
* **Performance Tuning**: Includes an optional script optimized for monitoring **100+ hosts** (adjusts pollers, cache limits, and timeouts).

---

## 📋 System Requirements

* **OS**: Ubuntu 24.04 LTS (Noble Numbat)
* **Privileges**: Root or `sudo` access
* **Ports required**: `80`, `443`, `10051`, `22`

---

## 🛠️ Quick Start

### 1. Clone the repository
```bash
git clone [https://github.com/V1p3rL0rd/zabbix-automated-deployment.git](https://github.com/V1p3rL0rd/zabbix-automated-deployment.git)
cd zabbix-automated-deployment/
chmod +x zabbix_deploy.sh
./zabbix_deploy.sh

after zabbix installation run zabbix_tuning.sh 
