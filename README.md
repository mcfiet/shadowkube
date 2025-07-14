# shadowkube - Confidential VM Cluster Setup (RKE2 + Vault + Wireguard)

Dieses Repository bietet ein vollständiges Setup zur Einrichtung eines Kubernetes-Clusters (RKE2) auf Confidential VMs (cVMs) mit Zero-Trust-Architektur, automatisierter Attestierung, sicherem Secrets-Management über Vault und automatischer Peer-Discovery via Wireguard.

## 🔐 Features

- ✅ Automatische **Master/Worker-Rollerkennung**
- ✅ **Vault-basierte Attestierung** und geheime Schlüsselverteilung
- ✅ **Wireguard Mesh** mit automatischer Peer-Discovery
- ✅ **Encrypted Storage** mit Reboot-Sicherheit (LUKS)
- ✅ **RKE2 Konfiguration** mit auto-discovery und Token-Management
- ✅ **Systemd Integration** für vollständige Autostarts

---

## 📦 Verzeichnisstruktur

```

cvm-cluster-setup/
├── scripts/               # Alle ausführbaren Shell-Skripte
├── systemd/               # systemd Service- und Override-Dateien
├── setup.sh               # Initiales Deployment-Skript
└── README.md              # Diese Datei

````

---

## 🚀 Quickstart

### 1. Repo klonen

```bash
git clone https://mcfiet/shadowkube cvm-cluster-setup
cd cvm-cluster-setup
````

### 2. Vorbereitung

```bash
chmod +x setup.sh
sudo ./setup.sh
```

Dies kopiert alle Skripte nach `/usr/local/bin/` und installiert systemd-Dienste.

---

## 🧑‍✈️ Master Node Setup

```bash
# 1. Initiales Setup
sudo /usr/local/bin/setup-cvm-enhanced.sh master

# 2. Attestierung + Vault-Integration
sudo /usr/local/bin/vhsm-cvm-auth-enhanced.sh master

# 3. Secrets und Storage
sudo systemctl start cvm-secrets-enhanced
sudo systemctl start cvm-storage

# 4. Wireguard & RKE2 Konfiguration
sudo /usr/local/bin/configure-wireguard-enhanced.sh
sudo /usr/local/bin/configure-rke2-enhanced.sh

# 5. Services starten
sudo systemctl start wg-quick@wg0
sudo systemctl start rke2-server
```

---

## 🧑‍🔧 Worker Node Setup

```bash
# 1. Initiales Setup
sudo /usr/local/bin/setup-cvm-enhanced.sh worker

# 2. Attestierung + Vault-Integration
sudo /usr/local/bin/vhsm-cvm-auth-enhanced.sh worker

# 3. Secrets und Storage
sudo systemctl start cvm-secrets-enhanced
sudo systemctl start cvm-storage

# 4. Wireguard & RKE2 Konfiguration (mit Master Auto-Discovery)
sudo /usr/local/bin/configure-wireguard-enhanced.sh
sudo /usr/local/bin/configure-rke2-enhanced.sh

# 5. Services starten
sudo systemctl start wg-quick@wg0
sudo systemctl start rke2-agent
```

---

## ⚙️ Systemd Dienste

| Dienst                 | Beschreibung                                 |
| ---------------------- | -------------------------------------------- |
| `cvm-secrets-enhanced` | Secret-Download + VAULT-Integration          |
| `cvm-storage`          | LUKS-verschlüsselter Storage für /etc & /var |
| `cvm-autostart`        | Bootstrapping aller cVM-Dienste nach Reboot  |
| `wg-quick@wg0`         | Wireguard VPN                                |
| `rke2-server/agent`    | Kubernetes Master/Worker                     |

---

## 📁 systemd Overrides

Diese Dateien stellen sicher, dass Dienste erst nach dem Storage und Secret-Zugriff starten:

* `rke2-agent.override.conf`
* `rke2-server.override.conf`
* `wg-quick@wg0.override.conf`

---

## 🛠 Voraussetzungen

* SUSE/OpenSUSE oder andere RPM-basierte Distribution
* `vault`, `jq`, `cryptsetup`, `wireguard-tools`, `rke2`
* VAULT Login-Token in `/root/.vault-token` hinterlegt
* Netzwerkzugang zu `https://vhsm.enclaive.cloud/`

---

## ✅ Hinweise

* 💡 Alle Secrets sind **temporär** unter `/run/cvm-secrets/` verfügbar und werden beim Shutdown automatisch gelöscht.
* 🔁 Das Setup ist **reboot-sicher** durch systemd-Dienste.

