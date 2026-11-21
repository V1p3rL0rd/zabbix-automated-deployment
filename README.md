# 🚀 Zabbix 7.0 LTS Production Automated Deployment & Tuning

**English** | [Русский](README.ru.md)

Automated, fully idempotent Bash scripts for deploying and fine-tuning **Zabbix 7.0 LTS** on **Ubuntu 22.04 / 24.04 LTS** powered by **PostgreSQL**, **TimescaleDB**, **Nginx**, and **PHP-FPM**.

Designed specifically for rapid rollout of standalone, high-performance monitoring nodes in secure internal network environments.

---

## 📌 Features

* **100% Idempotent & Fault-Tolerant**: Safe to run and re-run at any time. If interrupted, simply re-run the script—it safely detects existing databases, schemas, certificates, and credentials without data loss or duplicate configuration.
* **TimescaleDB Integration & Auto-Tuning**:
  * Automatically sets up the official TimescaleDB repository and installs matching extension packages for PostgreSQL (PG 14 on 22.04, PG 16 on 24.04).
  * Automatically applies hardware-based PostgreSQL tuning via `timescaledb-tune` (shared buffers, work memory, worker processes).
  * Creates native TimescaleDB hypertables and applies automatic data compression for history, trends, and audit logs.
* **Zero-Touch Headless Setup**: Automatically generates `/etc/zabbix/web/zabbix.conf.php` with proper permissions. **No manual browser setup wizard required!**
* **Self-Healing Repository Setup**: Detects OS codenames from `/etc/os-release` and cleans up stale/mismatched Zabbix apt sources or release deb packages.
* **Security Out-of-the-Box**:
  * Auto-generates self-signed TLS certificates (reused on subsequent runs).
  * Enforces HTTPS with HTTP-to-HTTPS redirect and TLS 1.2 / 1.3.
  * Configures local socket authentication with `scram-sha-256` (no database ports exposed to the network).
  * Configures UFW firewall (`22`, `80`, `443`, `10051`).
  * Stores generated database credentials with restricted permissions (`chmod 600`) at `/root/.zabbix_deploy_credentials`.
* **Performance & OS Tuning**: Dedicated `zabbix_tuning.sh` script optimizes internal Zabbix pollers, trappers, and caches, as well as Linux kernel parameters (`vm.overcommit_memory`, `fs.file-max`, network sockets) for **100–300+ hosts**.

---

## 📋 System Requirements

* **OS**: Ubuntu 22.04 LTS (Jammy) or 24.04 LTS (Noble)
* **Privileges**: Root or `sudo` access
* **Required Ports**: `80` (HTTP), `443` (HTTPS), `10051` (Zabbix Trapper/Server), `22` (SSH)

| Ubuntu Version | Zabbix Version | PostgreSQL | TimescaleDB | PHP-FPM |
| :--- | :--- | :--- | :--- | :--- |
| **Ubuntu 22.04 LTS** | 7.0 LTS | 14 | timescaledb-2-postgresql-14 | 8.1 |
| **Ubuntu 24.04 LTS** | 7.0 LTS | 16 | timescaledb-2-postgresql-16 | 8.3 |

---

## 🛠️ Quick Start

### 1. Clone and Run Deployment

```bash
git clone https://github.com/V1p3rL0rd/zabbix-automated-deployment
cd zabbix-automated-deployment
chmod +x zabbix_deploy.sh zabbix_tuning.sh
sudo ./zabbix_deploy.sh
```

#### Optional Flags:
| Flag | Description | Default |
| :--- | :--- | :--- |
| `-d, --domain <fqdn>` | Nginx `server_name` / TLS Certificate CN | `hostname -f` |
| `-t, --timezone <tz>` | PHP timezone | `Europe/Moscow` |
| `-e, --email <email>` | Email for TLS certificate | — |
| `-h, --help` | Show usage help | — |

### 2. Access Web Interface
Open your browser at `https://<server-ip>/` (or your domain).
Because the web configuration is created headlessly by the script, you are immediately greeted by the login screen.

* **Default Username**: `Admin`
* **Default Password**: `zabbix`

> ⚠️ **Important**: Change the default admin password immediately under *User settings → Profile*!

PostgreSQL credentials and deployment metadata are stored at:
```bash
sudo cat /root/.zabbix_deploy_credentials
```

### 3. (Optional) Apply Performance & Kernel Tuning

Run the tuning script to configure pollers, cache sizes, and kernel sysctl parameters:
```bash
sudo ./zabbix_tuning.sh
```

---

## ✅ Verification & Status Check

Verify that all monitoring and backend services are active:
```bash
systemctl is-active postgresql nginx php*-fpm zabbix-server zabbix-agent2
```
All services should return `active`.

Verify TimescaleDB hypertables:
```bash
sudo -u postgres psql -d zabbix -c "SELECT hypertable_name FROM timescaledb_information.hypertables;"
```

View deployment logs:
```bash
tail -n 50 /var/log/zabbix-deploy.log
```

---

## 🧰 Idempotence & Recovery

If a network timeout occurs or the server restarts midway during deployment:
1. Re-run `sudo ./zabbix_deploy.sh`.
2. The script will:
   * Keep the previously generated database password from `/root/.zabbix_deploy_credentials`.
   * Skip database creation if it already exists.
   * Skip schema import if tables are already populated.
   * Reuse the existing TLS certificates in `/etc/ssl/zabbix/`.
   * Ensure services are properly configured and started.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
