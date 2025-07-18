#!/bin/bash
set -e

echo "=== Enhanced cVM Setup with Master/Worker Support ==="

# Check if role is specified
if [ "$1" != "master" ] && [ "$1" != "worker" ]; then
    echo "Usage: $0 [master|worker]"
    echo "Example: sudo $0 master"
    echo "Example: sudo $0 worker"
    exit 1
fi

NODE_ROLE="$1"
echo "Setting up as $NODE_ROLE node..."

# 1. Install packages
echo "Installing packages..."
sudo zypper refresh

# Install basic packages first
sudo zypper install -y cryptsetup wireguard-tools jq wget gpg2

# Setup HashiCorp repository properly
echo "Setting up HashiCorp repository..."

# Download the keyring
sudo mkdir -p /usr/share/keyrings
wget -O- https://rpm.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# Verify the keyring
gpg --no-default-keyring --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg --fingerprint

# Import to RPM database (SUSE specific)
sudo rpm --import https://rpm.releases.hashicorp.com/gpg

# Add the HashiCorp repository (remove if exists)
sudo zypper rr hashicorp 2>/dev/null || true
sudo zypper ar -f https://rpm.releases.hashicorp.com/RHEL/8/x86_64/stable hashicorp

# Refresh and install HashiCorp packages
sudo zypper refresh
sudo zypper install -y vault

# Install SEV tools (they should work)
sudo zypper install -y sevctl libvirt-client-qemu

# 2. Enable basic services
sudo systemctl enable cvm-secrets-enhanced.service 2>/dev/null || echo "Service will be created"
sudo systemctl enable cvm-storage.service 2>/dev/null || echo "Service will be created"

# 3. VHSM Environment
sudo mkdir -p /etc/vault.d
echo 'VAULT_ADDR=https://vhsm.enclaive.cloud/' > /etc/vault.d/vault.env

# 4. Service dependencies
sudo mkdir -p /etc/systemd/system/rke2-agent.service.d 2>/dev/null || true
sudo mkdir -p /etc/systemd/system/rke2-server.service.d 2>/dev/null || true
sudo mkdir -p /etc/systemd/system/wg-quick@wg0.service.d 2>/dev/null || true

# Dependencies for RKE2
cat > /etc/systemd/system/rke2-agent.service.d/override.conf << 'EOD' 2>/dev/null || true
[Unit]
After=cvm-storage.service
Requires=cvm-storage.service
EOD

cat > /etc/systemd/system/rke2-server.service.d/override.conf << 'EOD' 2>/dev/null || true
[Unit]
After=cvm-storage.service
Requires=cvm-storage.service
EOD

cat > /etc/systemd/system/wg-quick@wg0.service.d/override.conf << 'EOD' 2>/dev/null || true
[Unit]
After=cvm-storage.service
Requires=cvm-storage.service
EOD

sudo systemctl daemon-reload

echo "✅ Enhanced cVM setup complete!"
echo
echo "Next steps:"
echo "1. Run: /usr/local/bin/vhsm-cvm-auth-enhanced.sh $NODE_ROLE"
echo "2. Start services: sudo systemctl start cvm-secrets-enhanced cvm-storage"
echo "3. Configure: sudo /usr/local/bin/configure-wireguard-enhanced.sh"
echo "4. Configure: sudo /usr/local/bin/configure-rke2-enhanced.sh"
echo "5. Start networking: sudo systemctl start wg-quick@wg0"
echo "6. Start K8s: sudo systemctl start rke2-${NODE_ROLE} (server/agent)"