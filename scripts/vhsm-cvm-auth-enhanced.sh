#!/bin/bash
set -e

echo "=== Enhanced cVM Authentication with Master/Worker Support ==="

export VAULT_ADDR=https://vhsm.enclaive.cloud/

# Determine node role
if [ "$1" = "master" ] || [ "$1" = "server" ]; then
  NODE_ROLE="master"
  echo " Configuring as MASTER node"
elif [ "$1" = "worker" ] || [ "$1" = "agent" ]; then
  NODE_ROLE="worker"
  echo " Configuring as WORKER node"
else
  echo "Usage: $0 [master|worker]"
  exit 1
fi

# Generate cVM attestation
/usr/local/bin/simple-cvm-attestation.sh

CVM_ATTESTATION=$(jq -c . /tmp/cvm-attestation.json)
HOSTNAME=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=$(curl -s ifconfig.me || echo "$NODE_IP")

echo "Registering enhanced cVM node..."
vault write -namespace=team-msc cubbyhole/cluster-nodes/$HOSTNAME \
  attestation="$CVM_ATTESTATION" \
  role="$NODE_ROLE" \
  internal_ip="$NODE_IP" \
  external_ip="$EXTERNAL_IP" \
  status="verified" \
  join_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$NODE_ROLE" = "master" ]; then
  echo " Setting up MASTER node secrets..."
  K8S_TOKEN=$(openssl rand -hex 32)
  CLUSTER_CA_KEY=$(openssl genrsa 4096 | base64 -w 0)
  CLUSTER_CA_CERT=$(openssl req -new -x509 -key <(echo "$CLUSTER_CA_KEY" | base64 -d) -sha256 -subj "/C=DE/ST=SH/O=ZeroTrust/CN=cluster-ca" -days 3650 | base64 -w 0)

  vault write -namespace=team-msc cubbyhole/cluster-info/master \
    master_hostname="$HOSTNAME" \
    master_internal_ip="$NODE_IP" \
    master_external_ip="$EXTERNAL_IP" \
    k8s_join_token="$K8S_TOKEN" \
    cluster_ca_key="$CLUSTER_CA_KEY" \
    cluster_ca_cert="$CLUSTER_CA_CERT" \
    cluster_created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  vault write -namespace=team-msc cubbyhole/cvm-cluster/$HOSTNAME-luks \
    key="$(openssl rand -hex 32)" purpose="disk_encryption" node_role="master"
  vault write -namespace=team-msc cubbyhole/cvm-cluster/$HOSTNAME-wireguard \
    private_key="$(wg genkey)" purpose="vpn_encryption" node_role="master"
  vault write -namespace=team-msc cubbyhole/cvm-cluster/$HOSTNAME-kubernetes \
    token="$K8S_TOKEN" purpose="k8s_master_token" node_role="master"

  echo "✅ Master secrets created"
else
  echo " Setting up WORKER node secrets..."
  MASTER_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-info/master 2>/dev/null || echo "{}")
  if [ "$(echo $MASTER_INFO | jq -r '.data')" = "null" ]; then
    echo "❌ No master node found! Please setup master first."
    exit 1
  fi

  MASTER_IP=$(echo $MASTER_INFO | jq -r '.data.master_internal_ip')
  K8S_TOKEN=$(echo $MASTER_INFO | jq -r '.data.k8s_join_token')

  vault write -namespace=team-msc cubbyhole/cvm-cluster/$HOSTNAME-luks \
    key="$(openssl rand -hex 32)" purpose="disk_encryption" node_role="worker"
  vault write -namespace=team-msc cubbyhole/cvm-cluster/$HOSTNAME-wireguard \
    private_key="$(wg genkey)" purpose="vpn_encryption" node_role="worker"
  vault write -namespace=team-msc cubbyhole/cvm-cluster/$HOSTNAME-kubernetes \
    token="$K8S_TOKEN" master_ip="$MASTER_IP" purpose="k8s_worker_token" node_role="worker"

  echo "✅ Worker secrets created"
fi

# Shared secrets on master
if [ "$NODE_ROLE" = "master" ]; then
  vault write -namespace=team-msc cubbyhole/cluster-shared/cnpg \
    superuser_password="$(openssl rand -hex 16)" \
    app_user_password="$(openssl rand -hex 16)" \
    replication_password="$(openssl rand -hex 16)" \
    monitoring_password="$(openssl rand -hex 16)" \
    purpose="cnpg_cluster_auth"
  vault write -namespace=team-msc cubbyhole/cluster-shared/postgresql-encryption \
    cluster_encryption_key="$(openssl rand -hex 32)" backup_encryption_key="$(openssl rand -hex 32)" wal_encryption_key="$(openssl rand -hex 32)" purpose="postgresql_data_encryption"
  vault write -namespace=team-msc cubbyhole/cluster-shared/benchmark \
    sysbench_user="sysbench" sysbench_password="$(openssl rand -hex 16)" pgbench_user="pgbench" pgbench_password="$(openssl rand -hex 16)" purpose="database_benchmarking"
  echo "✅ Shared cluster secrets created"
fi

echo "✅ Enhanced cVM registration complete for $NODE_ROLE node"
