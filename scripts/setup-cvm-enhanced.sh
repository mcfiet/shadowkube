#!/bin/bash
set -e

echo "=== Enhanced cVM Setup with Master/Worker Support ==="

if [ "$1" != "master" ] && [ "$1" != "worker" ]; then
  echo "Usage: $0 [master|worker]"
  exit 1
fi
NODE_ROLE="$1"
echo "Setting up as $NODE_ROLE node..."

# 1. Install necessary packages
sudo zypper refresh
sudo zypper install -y cryptsetup wireguard-tools vault jq

# 2. Enable services
sudo systemctl enable cvm-secrets-enhanced.service
sudo systemctl enable cvm-storage.service

# 3. Vault environment
sudo mkdir -p /etc/vault.d
echo 'VAULT_ADDR=https://vhsm.enclaive.cloud/' | sudo tee /etc/vault.d/vault.env

# 4. Service overrides
for svc in rke2-agent rke2-server wg-quick@wg0; do
  sudo mkdir -p /etc/systemd/system/${svc}.service.d
  cat >/etc/systemd/system/${svc}.service.d/override.conf <<'EOD'
[Unit]
After=cvm-storage.service
Requires=cvm-storage.service
EOD
done

sudo systemctl daemon-reload

echo "✅ Enhanced cVM setup complete!"
echo "Next steps:"
echo "  1) sudo /usr/local/bin/vhsm-cvm-auth-enhanced.sh $NODE_ROLE"
echo "  2) sudo systemctl start cvm-secrets-enhanced cvm-storage"
echo "  3) sudo /usr/local/bin/configure-wireguard-enhanced.sh"
echo "  4) sudo /usr/local/bin/configure-rke2-enhanced.sh"
echo "  5) sudo systemctl start wg-quick@wg0"
echo "  6) sudo systemctl start rke2-${NODE_ROLE}"
