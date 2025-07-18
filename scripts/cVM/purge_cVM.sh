#!/bin/bash
set -e

echo "=== Complete cVM Reset - Clean Slate ==="

# Stop all services first
echo "🛑 Stopping all services..."
sudo systemctl stop rke2-server.service 2>/dev/null || true
sudo systemctl stop rke2-agent.service 2>/dev/null || true
sudo systemctl stop wg-quick@wg0.service 2>/dev/null || true
sudo systemctl stop cvm-storage.service 2>/dev/null || true
sudo systemctl stop cvm-secrets-enhanced.service 2>/dev/null || true

# Disable services
echo "🚫 Disabling services..."
sudo systemctl disable rke2-server.service 2>/dev/null || true
sudo systemctl disable rke2-agent.service 2>/dev/null || true
sudo systemctl disable wg-quick@wg0.service 2>/dev/null || true
sudo systemctl disable cvm-storage.service 2>/dev/null || true
sudo systemctl disable cvm-secrets-enhanced.service 2>/dev/null || true

# Clean up encrypted storage
echo "🧹 Cleaning encrypted storage..."
sudo umount /etc/rancher 2>/dev/null || true
sudo umount /etc/wireguard 2>/dev/null || true
sudo umount /var/openebs 2>/dev/null || true
sudo umount /var/lib/rancher 2>/dev/null || true

# Close LUKS container
sudo cryptsetup luksClose cvm-storage 2>/dev/null || true

# Remove loop device
LOOP_DEV=$(cat /var/run/cvm-loop-device 2>/dev/null || echo "")
if [ -n "$LOOP_DEV" ]; then
    sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
fi

# Remove encrypted storage image
sudo rm -f /var/lib/cvm-storage.img
sudo rm -f /var/run/cvm-loop-device

# Clean up RKE2 completely
echo "🗑️ Removing RKE2..."
sudo rm -rf /var/lib/rancher/
sudo rm -rf /etc/rancher/
sudo rm -rf /usr/local/lib/systemd/system/rke2*
sudo rm -rf /etc/systemd/system/rke2*
sudo rm -f /usr/local/bin/rke2
sudo rm -f /usr/local/bin/kubectl
sudo rm -f /usr/local/bin/crictl

# Clean up Wireguard
echo "🗑️ Removing Wireguard config..."
sudo rm -rf /etc/wireguard/
sudo rm -f /usr/share/keyrings/hashicorp-archive-keyring.gpg

# Clean up systemd services and overrides
echo "🗑️ Removing systemd configs..."
sudo rm -rf /etc/systemd/system/rke2-agent.service.d/
sudo rm -rf /etc/systemd/system/rke2-server.service.d/
sudo rm -rf /etc/systemd/system/wg-quick@wg0.service.d/
sudo rm -f /etc/systemd/system/rke2-*.service
sudo rm -f /etc/systemd/system/cvm-*.service

# Clean up secrets
echo "🗑️ Removing secrets..."
sudo rm -rf /run/cvm-secrets/
sudo rm -f /root/.vault-token
sudo rm -f ~/.vault-token

# Clean up Vault environment
sudo rm -rf /etc/vault.d/

# Clean up any remaining containers/images (if any)
echo "🗑️ Cleaning containers..."
sudo crictl rmi --all 2>/dev/null || true
sudo crictl rm --all 2>/dev/null || true

# Clean up CNI
sudo rm -rf /etc/cni/
sudo rm -rf /opt/cni/
sudo rm -rf /var/lib/cni/

# Clean up systemctl daemon
sudo systemctl daemon-reload

# Clean up user configs
rm -rf ~/.kube/
sudo rm -rf /root/.kube/

# Clean up any remaining processes
sudo pkill -f rke2 2>/dev/null || true
sudo pkill -f containerd 2>/dev/null || true

# Clean up network interfaces (Wireguard)
sudo ip link delete wg0 2>/dev/null || true

# Clean up iptables rules (Wireguard/RKE2)
echo "🗑️ Cleaning iptables rules..."
sudo iptables -t nat -F 2>/dev/null || true
sudo iptables -t nat -X 2>/dev/null || true
sudo iptables -F FORWARD 2>/dev/null || true

# Remove HashiCorp repository (optional)
echo "🗑️ Removing repositories..."
sudo zypper rr hashicorp 2>/dev/null || true

# Clean up any logs
sudo journalctl --vacuum-time=1s 2>/dev/null || true

echo "✅ Complete cVM reset finished!"
echo ""
echo "🎯 System is now clean slate - ready for fresh setup"
echo ""
echo "📋 Next steps:"
echo "1. Reboot (recommended): sudo reboot"
echo "2. Or start fresh setup: sudo ./simplified-setup.sh master/worker TOKEN"
echo ""
echo "⚠️  Note: You may want to clean Vault entries too:"
echo "   vault delete -namespace=team-msc cubbyhole/cluster-nodes/$(hostname)"
echo "   vault delete -namespace=team-msc cubbyhole/cluster-pos/POS-X"