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
  if command rke2 -v >/dev/null 2>&1; then
    log "RKE2 already installed, skipping installation"
    return 0
  fi

  log "Installing RKE2..."

  # Download and install RKE2
  curl -sfL https://get.rke2.io | sh - || die "Failed to install RKE2"

  # Verify installation
  if ! command -v /usr/local/bin/rke2 >/dev/null 2>&1; then
    die "RKE2 binary not found at /usr/local/bin/rke2"
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
  cat >"$RKE2_DIR/config.yaml" <<EOF
# RKE2 Master Configuration for Confidential VM
node-name: $HOSTNAME

# Network configuration
node-ip: $WG_IP
advertise-address: $WG_IP

# TLS configuration - multiple SANs for flexibility
tls-san:
  - $WG_IP
  - $NODE_IP
  - $EXTERNAL_IP
  - localhost
  - 127.0.0.1
  - $HOSTNAME

# Security and features
cni: $CNI
EOF

  # Create audit policy for compliance
  cat >"$RKE2_DIR/audit-policy.yaml" <<'EOF'
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

  # Setup kubectl for root and current user
  log "Setting up kubectl configuration"

  # For root user
  mkdir -p /root/.kube
  cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
  chown root:root /root/.kube/config
  chmod 600 /root/.kube/config

  # For current user (if not root)
  if [ "$USER" != "root" ] && [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

    mkdir -p "$REAL_HOME/.kube"
    cp /etc/rancher/rke2/rke2.yaml "$REAL_HOME/.kube/config"
    chown "$REAL_USER:$(id -gn $REAL_USER)" "$REAL_HOME/.kube/config"
    chmod 600 "$REAL_HOME/.kube/config"

    log "Kubeconfig setup for user: $REAL_USER"
  fi

  # Add RKE2 binaries to PATH
  if ! grep -q "/var/lib/rancher/rke2/bin" ~/.bashrc; then
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >>~/.bashrc
    export PATH=$PATH:/var/lib/rancher/rke2/bin
  fi

  # Create symlinks for easier access
  ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true
  ln -sf /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl 2>/dev/null || true

  # Read the node token for workers and update Vault
  RKE2_TOKEN=$(cat /var/lib/rancher/rke2/server/node-token)

  # Update Vault with the REAL RKE2 token
  log "Updating Vault with real RKE2 token..."
  export VAULT_ADDR=https://vhsm.enclaive.cloud/

  # Update master cluster info with real token
  vault write -namespace=team-msc cubbyhole/cluster-info/master \
    master_hostname="$HOSTNAME" \
    master_internal_ip="$NODE_IP" \
    master_external_ip="$EXTERNAL_IP" \
    k8s_join_token="$RKE2_TOKEN" \
    cluster_created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    real_token_updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Also update the node-specific token
  vault write -namespace=team-msc cubbyhole/cvm-cluster/$HOSTNAME-kubernetes \
    token="$RKE2_TOKEN" \
    purpose="k8s_master_real_token" \
    node_role="master" \
    updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log "Vault updated with real RKE2 token"

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

  # Get the REAL token from Vault (updated by master)
  export VAULT_ADDR=https://vhsm.enclaive.cloud/

  log "Getting real RKE2 token from master..."
  MASTER_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-info/master 2>/dev/null || echo "{}")

  if [ "$(echo $MASTER_INFO | jq -r '.data')" = "null" ]; then
    die "Master cluster info not found in Vault! Setup master first."
  fi

  # Use the REAL token from the master
  K8S_TOKEN=$(echo $MASTER_INFO | jq -r '.data.k8s_join_token')
  MASTER_IP=$(echo $MASTER_INFO | jq -r '.data.master_internal_ip')

  if [ "$K8S_TOKEN" = "null" ] || [ "$K8S_TOKEN" = "" ]; then
    die "Real RKE2 token not found in Vault! Master may not be fully started."
  fi

  log "Using real RKE2 token from master"
  log "Master IP: $MASTER_IP"

  HOSTNAME=$(hostname)

  # Create RKE2 directory in encrypted storage
  mkdir -p "$RKE2_DIR"

  # Create worker configuration
  cat >"$RKE2_DIR/config.yaml" <<EOF
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

  # Check if systemd service exists, if not create it
  if [ ! -f /etc/systemd/system/rke2-agent.service ] && [ ! -f /usr/lib/systemd/system/rke2-agent.service ]; then
    log "Creating RKE2 agent systemd service..."

    sudo tee /etc/systemd/system/rke2-agent.service >/dev/null <<'EOF'
[Unit]
Description=Rancher Kubernetes Engine v2 (agent)
Documentation=https://rancher.com/docs/rke2/latest/en/
Wants=network-online.target
After=network-online.target
Conflicts=rke2-server.service

[Install]
WantedBy=multi-user.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-/usr/local/lib/systemd/system/%N.env
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service 2>/dev/null'
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/rke2 agent
EOF

    sudo systemctl daemon-reload
  fi

  # Enable and start RKE2 agent
  systemctl enable rke2-agent.service

  log "Starting RKE2 agent..."
  systemctl start rke2-agent.service

  # Wait for agent to connect with better error handling
  log "Waiting for RKE2 agent to connect to master..."
  for i in {1..60}; do
    if systemctl is-active --quiet rke2-agent.service; then
      log "RKE2 agent is running!"
      break
    fi
    if [ $i -eq 60 ]; then
      log "RKE2 agent taking longer than expected. Checking status..."
      systemctl status rke2-agent.service --no-pager -l
      break
    fi
    echo -n "."
    sleep 5
  done

  # Add RKE2 binaries to PATH
  if ! grep -q "/var/lib/rancher/rke2/bin" ~/.bashrc; then
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >>~/.bashrc
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
  echo "  • Check service: systemctl status rke2-agent"
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
