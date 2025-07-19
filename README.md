# shadowkube - Confidential VM Cluster Setup (RKE2 + Vault + Wireguard)

This repository provides a complete setup for deploying a Kubernetes cluster (RKE2) on Confidential VMs (cVMs) with a Zero-Trust architecture, automated attestation, secure secrets management via Vault, and automatic peer discovery via Wireguard.

## 🔐 Features

- ✅ Automatic **Master/Worker role detection**
- ✅ **Vault-based attestation** and secret key distribution
- ✅ **Wireguard mesh** with automatic peer discovery
- ✅ **Encrypted storage** with reboot persistence (LUKS)
- ✅ **RKE2 configuration** with auto-discovery and token management
- ✅ **Systemd integration** for full autostart capability

---

## 📦 Directory Structure

```

cvm-cluster-setup/
├── scripts/               # All executable shell scripts
    ├── VM/                # Setup scripts for regular VMs
    └── cVM/               # Setup scripts for confidential VMs
├── server\_configs/        # All Google Cloud server configs
├── systemd/               # systemd service and override files
├── tests/                 # All test scripts
├── setup.sh               # Initial deployment script
└── README.md              # This file

```

---

## 🚀 Quickstart

For setting up the non-confidential VM, refer to our guide:

https://gist.github.com/mcfiet/f4655f938b7dba652b3878b2852ddd2a

### 1. Clone the Repository

Run on all nodes:

```bash
git clone https://github.com/mcfiet/shadowkube.git
cd shadowkube
```

### 2. Preparation

Run on all nodes:

```bash
sudo ./setup.sh
```

This copies all scripts to `/usr/local/bin/` and installs the systemd services.

---

### Master Node Setup

```bash
sudo ./scripts/cVM/setup-cVM.sh master <VAULT-TOKEN>
```

---

### Worker Node Setup

```bash
sudo ./scripts/cVM/setup-cVM.sh worker <VAULT-TOKEN>
```

> \[!NOTE]
> Each node must be connected to every other node in the VPN mesh. If the worker node being set up outputs `==> Starting RKE2 agent...`, then the following must be run on the other nodes:
>
> ```bash
> sudo scripts/cVM/configure-wireguard-enhanced.sh
> ```

---

## ⚙️ Systemd Services

| Service                | Description                              |
| ---------------------- | ---------------------------------------- |
| `cvm-secrets-enhanced` | Secret download + Vault integration      |
| `cvm-storage`          | LUKS-encrypted storage for /etc & /var   |
| `cvm-autostart`        | Bootstraps all cVM services after reboot |
| `wg-quick@wg0`         | Wireguard VPN                            |
| `rke2-server/agent`    | Kubernetes master/worker                 |

---

## 📁 Systemd Overrides

These files ensure services only start after storage and secrets access is available:

- `rke2-agent.override.conf`
- `rke2-server.override.conf`
- `wg-quick@wg0.override.conf`

---

## 🛠 Requirements

- SUSE/OpenSUSE or other RPM-based distribution
- Installed: `vault`, `jq`, `cryptsetup`, `wireguard-tools`, `rke2`
- Vault login token stored in `/root/.vault-token`
- Network access to `https://vhsm.enclaive.cloud/`

---

## ✅ Notes

- 💡 All secrets are **temporarily** available under `/run/cvm-secrets/` and are automatically deleted on shutdown.
- 🔁 The setup is **reboot-safe** thanks to systemd services.
