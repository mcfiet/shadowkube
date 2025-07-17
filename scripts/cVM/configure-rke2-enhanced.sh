#!/usr/bin/env bash
set -euo pipefail

echo "=== Enhanced RKE2 Configuration with Installation ==="

# Configuration
RKE2_DIR="/etc/rancher/rke2"
CNI="calico"

# Logging functions
log() { echo -e "\n==> $*"; }
die() {
    echo -e "\n[ERROR] $*" >&2
    exit 1
}

# Check prerequisites
check_prerequisites() {
    # Check if we have required secrets
    if [ ! -f /run/cvm-secrets/k8s.token ]; then
        die "Kubernetes token not found in /run/cvm-secrets/k8s.token"
    fi
    
    if [ ! -f /run/cvm-secrets/node.role ]; then
        die "Node role not found in /run/cvm-secrets/node.role"
    fi
    
    # Check if encrypted storage is mounted
    if ! mountpoint -q /var/lib/rancher >/dev/null 2>&1; then
        die "Encrypted storage not mounted. Run cvm-storage service first."
    fi
    
    log "Prerequisites check passed"
}

# Install RKE2
install_rke2() {
    if command -v rke2 >/dev/null 2>&1; then
        log "RKE2 already installed, skipping installation"
        return 0
    fi
    
    log "Installing RKE2..."
    
    # Download and install RKE2
    curl -sfL https://get.rke2.io | sh - || die "Failed to install RKE2"
    
    # Verify installation
    if ! command -v rke2 >/dev/null 2>&1; then
        die "RKE2 installation failed"
    fi
    
    log "RKE2 installed successfully"
}

# Get network configuration
get_network_config() {
    NODE_IP=$(hostname -I | awk '{print $1}')
    
    # Get Wireguard IP for cluster communication
    if [ -f /etc/wireguard/wg0.conf ]; then
        WG_IP=$(grep "Address" /etc/wireguard/wg0.conf | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f1)
        log "Using Wireguard IP: $WG_IP"
    else
        WG_IP="$NODE_IP"
        log "Wireguard not configured, using node IP: $NODE_IP"
    fi
    
    # Try to get external IP
    EXTERNAL_IP=$(curl -s --connect-timeout 5 "https://ipinfo.io/ip" 2>/dev/null || echo "$NODE_IP")
    
    log "Network configuration:"
    log "  Node IP (internal): $NODE_IP"
    log "  Wireguard IP (cluster): $WG_IP"
    log "  External IP: $EXTERNAL_IP"
}

# Setup RKE2 Master/Server
setup_master() {
    log "Configuring RKE2 MASTER/SERVER"
    
    # Read secrets
    K8S_TOKEN=$(cat /run/cvm-secrets/k8s.token)
    HOSTNAME=$(hostname)
    
    # Create RKE2 directory in encrypted storage
    mkdir -p "$RKE2_DIR"
    
    # Create master configuration
    cat > "$RKE2_DIR/config.yaml" << EOF
# RKE2 Master Configuration for Confidential VM
node-name: $HOSTNAME
cluster-init: true
token: $K8S_TOKEN

# Network configuration
node-ip: $WG_IP
advertise-address: $WG_IP
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16

# TLS configuration - multiple SANs for flexibility
tls-san:
  - $WG_IP
  - $NODE_IP
  - $EXTERNAL_IP
  - localhost
  - 127.0.0.1
  - $HOSTNAME

# Security and features
secrets-encryption: true
write-kubeconfig-mode: "0644"
cni: $CNI

# Disable components we don't need
disable:
  - rke2-ingress-nginx

# Enable audit logging for compliance
audit-policy-file: /etc/rancher/rke2/audit-policy.yaml
EOF
    
    # Create audit policy for compliance
    cat > "$RKE2_DIR/audit-policy.yaml" << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]
- level: Request
  resources:
  - group: ""
    resources: ["*"]
EOF
    
    chmod 600 "$RKE2_DIR/config.yaml"
    chmod 600 "$RKE2_DIR/audit-policy.yaml"
    
    # Enable and start RKE2 server
    systemctl enable rke2-server.service
    
    log "Starting RKE2 server..."
    systemctl start rke2-server.service
    
    # Wait for RKE2 to be ready
    log "Waiting for RKE2 server to be ready..."
    for i in {1..60}; do
        if [ -f /etc/rancher/rke2/rke2.yaml ]; then
            log "RKE2 server is ready!"
            break
        fi
        echo -n "."
        sleep 5
    done
    
    if [ ! -f /etc/rancher/rke2/rke2.yaml ]; then
        die "RKE2 server failed to start within 5 minutes"
    fi
    
    # Setup kubectl for root
    log "Setting up kubectl configuration"
    mkdir -p ~/.kube
    cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
    chown $(id -u):$(id -g) ~/.kube/config
    
    # Add RKE2 binaries to PATH
    if ! grep -q "/var/lib/rancher/rke2/bin" ~/.bashrc; then
        echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc
        export PATH=$PATH:/var/lib/rancher/rke2/bin
    fi
    
    # Create symlinks for easier access
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true
    ln -sf /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl 2>/dev/null || true
    
    # Read the node token for workers
    RKE2_TOKEN=$(cat /var/lib/rancher/rke2/server/node-token)
    
    # Summary
    echo -e "\n=== RKE2 Master Setup Complete ==="
    echo "🎯 Master Node: $HOSTNAME"
    echo "🌐 External IP: $EXTERNAL_IP"
    echo "🔗 Cluster IP: $WG_IP"
    echo "🔑 Node Token: $RKE2_TOKEN"
    echo ""
    echo "📋 Next steps:"
    echo "  • Test cluster: kubectl get nodes"
    echo "  • Setup workers with token: $RKE2_TOKEN"
    echo "  • Master IP for workers: $WG_IP"
    echo ""
    echo "💡 All configurations stored in encrypted storage"
}

# Setup RKE2 Worker/Agent
setup_worker() {
    log "Configuring RKE2 WORKER/AGENT"
    
    # Read secrets
    K8S_TOKEN=$(cat /run/cvm-secrets/k8s.token)
    MASTER_IP=$(cat /run/cvm-secrets/master.ip 2>/dev/null || echo "unknown")
    HOSTNAME=$(hostname)
    
    if [ "$MASTER_IP" = "unknown" ]; then
        die "Master IP not found! Worker needs master IP in /run/cvm-secrets/master.ip"
    fi
    
    # Create RKE2 directory in encrypted storage
    mkdir -p "$RKE2_DIR"
    
    # Create worker configuration
    cat > "$RKE2_DIR/config.yaml" << EOF
# RKE2 Worker Configuration for Confidential VM
node-name: $HOSTNAME
server: https://10.0.0.1:9345
token: $K8S_TOKEN

# Network configuration
node-ip: $WG_IP

# Security
secrets-encryption: true
write-kubeconfig-mode: "0644"
cni: $CNI
EOF
    
    chmod 600 "$RKE2_DIR/config.yaml"
    
    # Enable and start RKE2 agent
    systemctl enable rke2-agent.service
    
    log "Starting RKE2 agent..."
    systemctl start rke2-agent.service
    
    # Wait for agent to connect
    log "Waiting for RKE2 agent to connect to master..."
    for i in {1..30}; do
        if systemctl is-active --quiet rke2-agent.service; then
            log "RKE2 agent is running!"
            break
        fi
        echo -n "."
        sleep 5
    done
    
    # Add RKE2 binaries to PATH
    if ! grep -q "/var/lib/rancher/rke2/bin" ~/.bashrc; then
        echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc
        export PATH=$PATH:/var/lib/rancher/rke2/bin
    fi
    
    # Create symlinks for easier access
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true
    ln -sf /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl 2>/dev/null || true
    
    # Summary
    echo -e "\n=== RKE2 Worker Setup Complete ==="
    echo "🔧 Worker Node: $HOSTNAME"
    echo "🌐 External IP: $EXTERNAL_IP"
    echo "🔗 Node IP: $WG_IP"
    echo "🎯 Master IP: 10.0.0.1 (via Wireguard)"
    echo ""
    echo "📋 Next steps:"
    echo "  • Check node status from master: kubectl get nodes"
    echo "  • View logs: journalctl -fu rke2-agent"
    echo ""
    echo "💡 All configurations stored in encrypted storage"
}

# Main execution
main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        die "Please run as root"
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Get network configuration
    get_network_config
    
    # Read node role from secrets
    NODE_ROLE=$(cat /run/cvm-secrets/node.role)
    
    log "Node role detected: $NODE_ROLE"
    
    # Install RKE2
    install_rke2
    
    # Configure based on role
    case "$NODE_ROLE" in
        "master")
            setup_master
            ;;
        "worker")
            setup_worker
            ;;
        *)
            die "Unknown node role: $NODE_ROLE. Expected 'master' or 'worker'"
            ;;
    esac
    
    log "RKE2 configuration complete!"
}

# Run main function
main "$@"