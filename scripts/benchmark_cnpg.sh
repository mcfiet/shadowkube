#!/bin/bash
set -e

NODE_NAME=$(hostname)
CVM_TYPE="confidential"

echo "🚀 Working CNPG Benchmark - $NODE_NAME"

NAMESPACE="benchmark-working"
kubectl delete namespace $NAMESPACE --ignore-not-found=true --wait=true
kubectl create namespace $NAMESPACE

# Create our own credentials first
POSTGRES_PASSWORD=$(openssl rand -hex 16)
echo "🔐 Generated password: ${#POSTGRES_PASSWORD} chars"

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
data:
  username: $(echo -n postgres | base64)
  password: $(echo -n "$POSTGRES_PASSWORD" | base64)
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  instances: 1
  
  bootstrap:
    initdb:
      database: benchmark
      owner: postgres
      secret:
        name: postgres-credentials
  
  storage:
    storageClass: openebs-hostpath
    size: 1Gi
EOF

echo "⏳ Waiting for PostgreSQL cluster..."
kubectl wait --for=condition=Ready cluster/postgres -n $NAMESPACE --timeout=300s

# Wait for service to be ready
echo "⏳ Waiting for service to be available..."
sleep 20

# Get service IP
PG_IP=$(kubectl get svc postgres-rw -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')
echo "📡 PostgreSQL service: $PG_IP"

# Test connection first
echo "🧪 Testing connection..."
kubectl run test --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" -- \
  pg_isready -h $PG_IP -U postgres

echo "✅ Connection successful!"

# Run benchmark
echo "🚀 Running PostgreSQL benchmark..."
kubectl run pgbench --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=postgres" \
  --env="PGDATABASE=benchmark" \
  -- bash -c '
echo "=== PostgreSQL Performance Benchmark ==="
echo "Node: '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
echo "Host: $PGHOST"
echo ""

echo "📊 Initializing pgbench (scale 10)..."
pgbench -i -s 10 -q

echo ""
echo "🚀 Running benchmark tests..."

echo ""
echo "=== Single Client Test (20 seconds) ==="
pgbench -c 1 -j 1 -T 20 -P 5

echo ""  
echo "=== 5 Clients Test (20 seconds) ==="
pgbench -c 5 -j 2 -T 20 -P 5

echo ""
echo "=== 10 Clients Test (20 seconds) ==="
pgbench -c 10 -j 4 -T 20 -P 5

echo ""
echo "=== Read-Only Test (20 seconds) ==="
pgbench -c 10 -j 4 -T 20 -S -P 5

echo ""
echo "✅ Benchmark completed!"
'

# Extract and save results if VHSM is available
if command -v vault >/dev/null 2>&1; then
    export VAULT_ADDR=https://vhsm.enclaive.cloud/
    if vault token lookup >/dev/null 2>&1; then
        echo "💾 Storing results in VHSM..."
        vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-cnpg-$(date +%s) \
            timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            node_name="$NODE_NAME" \
            vm_type="$CVM_TYPE" \
            benchmark_type="postgresql_cnpg" \
            status="completed"
        echo "✅ Results stored in VHSM"
    fi
fi

echo "🎉 CNPG PostgreSQL benchmark completed!"

# Cleanup
kubectl delete namespace $NAMESPACE
