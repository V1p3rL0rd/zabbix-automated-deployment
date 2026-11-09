# zabbix-automated-deployment
# 🚀 Zabbix 7.0 LTS Production Automated Deployment & Tuning

Automated Bash scripts for deploying and fine-tuning **Zabbix 7.0 LTS** on **Ubuntu 22.04 / 24.04 / 26.04 LTS** using PostgreSQL, Nginx, and PHP-FPM.

---

## 📌 Features

* **One command, any supported Ubuntu LTS**: the Ubuntu release is detected from `/etc/os-release` and the matching official Zabbix repository is added automatically.
* **Zero-dependency deployment**: Installs PostgreSQL, Nginx, PHP-FPM, Zabbix Server, and Agent 2 directly from the standard Ubuntu & official Zabbix repositories.
* **Security out-of-the-box**: Auto-generates SSL/TLS self-signed certificates and configures HTTPS redirect.
* **Automatic Fixes**: Pre-configures required PHP limits (`post_max_size`, `max_execution_time`, `max_input_time`) and reloads PHP-FPM cleanly.
* **Self-healing repo setup**: Removes a leftover/mismatched `zabbix-release` package and stale Zabbix apt sources from previous runs before adding the correct repository.
* **Credentials Storage**: Automatically saves generated database passwords to `/root/.zabbix_deploy_credentials`.
* **Performance Tuning**: Includes an optional script optimized for monitoring **100+ hosts** (adjusts pollers, cache limits, and timeouts).

---

## 📋 System Requirements

* **OS**: Ubuntu 22.04 LTS (Jammy), 24.04 LTS (Noble) or 26.04 LTS (Resolute) — fresh server recommended
* **Privileges**: Root or `sudo` access
* **Ports required**: `80`, `443`, `10051`, `22`

What gets installed (distro defaults, detected at runtime):

| Ubuntu | Zabbix repo | PostgreSQL | PHP |
|--------|-------------|------------|-----|
| 22.04  | `ubuntu22.04` | 14 | 8.1 |
| 24.04  | `ubuntu24.04` | 16 | 8.3 |
| 26.04  | `ubuntu26.04` | 18 | 8.5 |

---

## 🛠️ Quick Start

### 1. Clone and run the deployment
```bash
git clone https://github.com/V1p3rL0rd/zabbix-automated-deployment
cd zabbix-automated-deployment
chmod +x zabbix_deploy.sh zabbix_tuning.sh
sudo ./zabbix_deploy.sh
```

Optional flags:

| Flag | Description | Default |
|------|-------------|---------|
| `-d, --domain <fqdn>` | Nginx `server_name` / SSL certificate CN | `hostname -f` |
| `-t, --timezone <tz>` | PHP timezone | `Europe/Moscow` |
| `-e, --email <email>` | E-mail put into the self-signed certificate | — |

### 2. Finish the setup in the browser
Open `https://<server-ip>/`, complete the Zabbix setup wizard and log in with the default credentials **Admin / zabbix**. Change the password immediately (*User settings → Profile*).

The PostgreSQL password for the `zabbix` user is stored in:
```bash
sudo cat /root/.zabbix_deploy_credentials
```

### 3. (Optional) Apply performance tuning
```bash
sudo ./zabbix_tuning.sh
```

---

## ✅ Verification

```bash
systemctl is-active postgresql nginx php*-fpm zabbix-server zabbix-agent2   # all "active"
dpkg -l 'zabbix*' | awk '/^ii/{print $2, $3}'                               # versions end with +ubuntu<your release>
tail -n 50 /var/log/zabbix-deploy.log
```

---

## 🧯 Troubleshooting

**`Unable to satisfy dependencies ... libxml2 ... [no choices]`**
The Zabbix repository for a *different* Ubuntu release was added (e.g. the 24.04 repo on 26.04). The current script detects the release automatically — make sure you run the latest version from this repository.

**`NO_PUBKEY` for `repo.zabbix.com`**
Two `zabbix-release` packages for different Ubuntu releases were mixed. Re-running the current script cleans this up automatically.

**`Database zabbix already exists. Refusing to overwrite it.`**
A previous run was interrupted after the database was created. The script never overwrites a database on purpose. If `zabbix-server` has never run on this host (fresh install), drop it and run again:
```bash
sudo -u postgres dropdb zabbix
sudo ./zabbix_deploy.sh
```

**`Unsupported OS`**
Only the Ubuntu releases listed above are accepted. When Zabbix publishes a repository for a newer release, add it to `SUPPORTED_UBUNTU` at the top of `zabbix_deploy.sh`.
