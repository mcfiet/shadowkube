#!/bin/bash
# Simplified Setup Order for cVM with Encrypted Storage

echo "=== Simplified cVM Setup Order ==="

NODE_ROLE="${1:-master}"

echo "🎯 Setting up $NODE_ROLE node..."

# Step 1: Initial setup (packages, services)
echo "📦 Step 1: Initial setup..."
sudo /usr/local/bin/setup-cvm-enhanced.sh $NODE_ROLE

# Step 2: Attestation + Vault authentication + Secret generation  
echo "🔐 Step 2: Attestation and Vault authentication..."
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