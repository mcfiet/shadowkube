#!/bin/bash
set -e

echo "Configuring RKE2 with master/worker detection..."

if [ ! -f /run/cvm-secrets/k8s.token ]; then
  echo "❌ Kubernetes token not found"
  exit 1
fi

NODE_ROLE=$(cat /run/cvm-secrets/node.role || echo "unknown")
K8S_TOKEN=$(cat /run/cvm-secrets/k8s.token)
NODE_IP=$(hostname -I | awk '{print $1}')

if [ -f /etc/wireguard/wg0.conf ]; then
  WG_IP=$(grep "Address" /etc/wireguard/wg0.conf | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f1)
else
  WG_IP="$NODE_IP"
fi

mkdir -p /etc/rancher/rke2

if [ "$NODE_ROLE" = "master" ]; then
  cat >/etc/rancher/rke2/config.yaml <<MASTEREOF
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
tls-san:
  - $WG_IP
  - $NODE_IP
  - localhost
  - 127.0.0.1
MASTEREOF
  echo "✅ RKE2 configured as MASTER"
else
  MASTER_IP=$(cat /run/cvm-secrets/master.ip || echo "unknown")
  if [ "$MASTER_IP" = "unknown" ]; then
    echo "❌ Master IP not found!"
    exit 1
  fi
  cat >/etc/rancher/rke2/config.yaml <<WORKEREOF
node-role: agent
server: https://10.0.0.1:9345
token: $K8S_TOKEN
node-ip: $WG_IP
secrets-encryption: true
write-kubeconfig-mode: "0644"
WORKEREOF
  echo "✅ RKE2 configured as WORKER"
fi

chmod 600 /etc/rancher/rke2/config.yaml
