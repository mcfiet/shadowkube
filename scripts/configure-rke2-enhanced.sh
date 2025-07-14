#!/bin/bash
set -e

echo "Configuring RKE2 with master/worker detection..."

if [ ! -f /run/cvm-secrets/k8s.token ]; then
  echo "❌ Kubernetes token not found"
  exit 1
fi

NODE_ROLE=$(cat /run/cvm-secrets/node.role 2>/dev/null || echo "unknown")
K8S_TOKEN=$(cat /run/cvm-secrets/k8s.token)
NODE_IP=$(hostname -I | awk '{print $1}')

# Get Wireguard IP for cluster communication
if [ -f /etc/wireguard/wg0.conf ]; then
  WG_IP=$(grep "Address" /etc/wireguard/wg0.conf | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f1)
else
  WG_IP="$NODE_IP" # Fallback to node IP
fi

echo "Node IP: $NODE_IP"
echo "Wireguard IP: $WG_IP"

mkdir -p /etc/rancher/rke2

if [ "$NODE_ROLE" = "master" ]; then
  echo "🎯 Configuring RKE2 MASTER/SERVER"

  cat >/etc/rancher/rke2/config.yaml <<MASTEREOF
# RKE2 Master Configuration
cluster-init: true
node-role: server
token: $K8S_TOKEN
node-ip: $WG_IP
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
secrets-encryption: true
cni: calico
write-kubeconfig-mode: "0644"
disable:
  - rke2-ingress-nginx

# TLS configuration - both IPs for flexibility
tls-san:
  - $WG_IP
  - $NODE_IP
  - localhost
  - 127.0.0.1
MASTEREOF

else
  echo "🔧 Configuring RKE2 WORKER/AGENT"

  MASTER_IP=$(cat /run/cvm-secrets/master.ip 2>/dev/null || echo "unknown")

  if [ "$MASTER_IP" = "unknown" ]; then
    echo "❌ Master IP not found! Worker needs master IP."
    exit 1
  fi

  # For workers, use master's Wireguard IP
  cat >/etc/rancher/rke2/config.yaml <<WORKEREOF
# RKE2 Worker Configuration  
node-role: agent
server: https://10.0.0.1:9345
token: $K8S_TOKEN
node-ip: $WG_IP
secrets-encryption: true
write-kubeconfig-mode: "0644"
WORKEREOF

fi

chmod 600 /etc/rancher/rke2/config.yaml

echo "✅ RKE2 configured as $NODE_ROLE"
echo "   Node IP (external): $NODE_IP"
echo "   Wireguard IP (cluster): $WG_IP"
EOF
