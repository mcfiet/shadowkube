#!/bin/bash
# Simplified Setup Order for cVM with Encrypted Storage

echo "=== Simplified cVM Setup Order ==="

# Check parameters
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <master|worker> [vault_token]"
    echo "Example: $0 master hvs.XXXXXXXXXXXX"
    exit 1
fi

NODE_ROLE="$1"
VAULT_TOKEN="$2"

echo "🎯 Setting up $NODE_ROLE node..."

# Step 1: Initial setup (packages, services)
echo "📦 Step 1: Initial setup..."

# Minimal package installation
echo "Installing packages..."
sudo zypper refresh
sudo zypper install -y cryptsetup wireguard-tools jq curl gpg2

# HashiCorp repository setup
echo "Setting up HashiCorp repository..."
sudo mkdir -p /usr/share/keyrings
curl -fsSL https://rpm.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
sudo rpm --import https://rpm.releases.hashicorp.com/gpg
sudo zypper ar -f https://rpm.releases.hashicorp.com/RHEL/8/x86_64/stable hashicorp
sudo zypper refresh
sudo zypper install -y vault

# SEV tools (optional)
sudo zypper install -y sevctl libvirt-client-qemu || echo "⚠️ SEV tools not available"

# Vault environment
sudo mkdir -p /etc/vault.d
echo 'VAULT_ADDR=https://vhsm.enclaive.cloud/' | sudo tee /etc/vault.d/vault.env
export VAULT_ADDR=https://vhsm.enclaive.cloud/

# Service dependencies
sudo mkdir -p /etc/systemd/system/{rke2-agent,rke2-server,wg-quick@wg0}.service.d
for service in rke2-agent rke2-server wg-quick@wg0; do
    sudo tee /etc/systemd/system/${service}.service.d/override.conf > /dev/null << EOF
[Unit]
After=cvm-storage.service
Requires=cvm-storage.service
EOF
done
sudo systemctl daemon-reload

# Step 2: Attestation + Vault authentication + Secret generation  
echo "🔐 Step 2: Attestation and Vault authentication..."

# Handle Vault token
if [ -z "$VAULT_TOKEN" ]; then
    echo "Please enter your Vault token:"
    read -s VAULT_TOKEN
fi

# Set Vault environment and login
export VAULT_ADDR=https://vhsm.enclaive.cloud/

echo "Logging into Vault..."
echo "$VAULT_TOKEN" | vault login -address https://vhsm.enclaive.cloud/ -

# Verify login
if ! vault token lookup >/dev/null 2>&1; then
    echo "❌ Vault login failed"
    exit 1
fi

echo "✅ Vault login successful"

# Copy token for scripts that need it
sudo mkdir -p /root
sudo cp ~/.vault-token /root/.vault-token

# Run attestation and auth
sudo /usr/local/bin/vhsm-cvm-auth-enhanced.sh $NODE_ROLE

# Step 3: Get secrets from Vault (including LUKS keys)
echo "🔑 Step 3: Retrieving secrets from Vault..."
sudo systemctl start cvm-secrets-enhanced

# Step 4: Setup encrypted storage (MUST be before any config)
echo "💾 Step 4: Setting up encrypted storage..."
sudo systemctl start cvm-storage

# Step 5: Configure services (now that encrypted storage is ready)
echo "⚙️ Step 5: Configuring network and Kubernetes..."
sudo /usr/local/bin/configure-wireguard-enhanced.sh
sudo /usr/local/bin/configure-rke2-enhanced.sh

# Step 6: Start services
echo "🚀 Step 6: Starting services..."
sudo systemctl start wg-quick@wg0

if [ "$NODE_ROLE" = "master" ]; then
    sudo systemctl start rke2-server
else
    sudo systemctl start rke2-agent
fi

echo "✅ $NODE_ROLE node setup complete!"

# Verification
echo ""
echo "🔍 Verification:"
echo "   Encrypted storage: $(mountpoint -q /var/lib/rancher && echo "✅ Mounted" || echo "❌ Not mounted")"
echo "   Wireguard: $(systemctl is-active wg-quick@wg0)"
if [ "$NODE_ROLE" = "master" ]; then
    echo "   RKE2 Server: $(systemctl is-active rke2-server)"
    echo "   Kubeconfig: $([ -f /etc/rancher/rke2/rke2.yaml ] && echo "✅ Available" || echo "❌ Missing")"
else
    echo "   RKE2 Agent: $(systemctl is-active rke2-agent)"
fi

# Show next steps
echo ""
echo "🎯 Next steps:"
if [ "$NODE_ROLE" = "master" ]; then
    echo "   • Export kubeconfig: export KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
    echo "   • Check cluster: kubectl get nodes"
    echo "   • Setup workers using this same script"
else
    echo "   • Check if node joined: kubectl get nodes (from master)"
fi

echo "   • All configs are stored in encrypted storage (/var/lib/rancher/)"