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
git clone https://github.com/mcfiet/shadowkube.git
cd shadowkube
```

### 2. Vorbereitung

```bash
sudo ./setup.sh
```

Dies kopiert alle Skripte nach `/usr/local/bin/` und installiert systemd-Dienste.

---

## 🧑‍✈️ Master Node Setup

```bash
sudo ./scripts/cVM/setup-cVM.sh master <VAULT-TOKEN>
```

## kubectl
```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config
```

---

## 🧑‍🔧 Worker Node Setup

```bash
sudo ./scripts/cVM/setup-cVM.sh worker <VAULT-TOKEN>
```
>[!NOTE]
>Jede Node muss mit jeder anderen im VPN Mesh verbunden sein. Wenn die Worker Node, die gerade eingerichtet wird, `==> Starting RKE2 agent...` ausgibt, dann muss auf den anderen Nodes folgendes ausgeführt werden:
>```bash
>sudo scripts/cVM/configure-wireguard-enhanced.sh
>```

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

