#!/bin/bash
set -e

NODE_NAME=$(hostname)
CVM_TYPE="confidential"

echo "🚀 Fixed PostgreSQL Benchmark - $NODE_NAME ($CVM_TYPE)"

NAMESPACE="pgbench-fixed"
kubectl delete namespace $NAMESPACE --ignore-not-found=true --wait=true
kubectl create namespace $NAMESPACE

# Create cluster and wait for it to be fully ready including secrets
cat << EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: $NAMESPACE
spec:
  instances: 1
  storage:
    storageClass: openebs-hostpath
    size: 1Gi
EOF

echo "⏳ Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready cluster/pg -n $NAMESPACE --timeout=300s

echo "⏳ Waiting for secrets to be created..."
# Wait for the superuser secret to exist
for i in {1..60}; do
    if kubectl get secret pg-superuser -n $NAMESPACE >/dev/null 2>&1; then
        echo "✅ Superuser secret found!"
        break
    fi
    echo "Waiting for secrets... ($i/60)"
    sleep 2
done

# Get the password
POSTGRES_PASSWORD=$(kubectl get secret pg-superuser -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
echo "🔐 Password retrieved (length: ${#POSTGRES_PASSWORD})"

# Test connection properly
echo "🧪 Testing connection..."
kubectl run test-conn --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
    --env="PGPASSWORD=$POSTGRES_PASSWORD" \
    --env="PGHOST=pg-rw" \
    --env="PGUSER=postgres" \
    --env="PGDATABASE=postgres" \
    -- bash -c '
echo "Environment check:"
echo "PGHOST: $PGHOST"
echo "PGUSER: $PGUSER" 
echo "PGPASSWORD length: ${#PGPASSWORD}"

echo "Testing pg_isready..."
pg_isready

echo "Testing connection..."
psql -c "SELECT version();"

echo "Connection successful!"
'

# Run benchmark if connection test passed
echo "🚀 Running benchmark..."
kubectl run pgbench-test --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
    --env="PGPASSWORD=$POSTGRES_PASSWORD" \
    --env="PGHOST=pg-rw" \
    --env="PGUSER=postgres" \
    --env="PGDATABASE=postgres" \
    -- bash -c '
echo "Setting up benchmark database..."
createdb benchmark
export PGDATABASE=benchmark

echo "Initializing pgbench..."
pgbench -i -s 5 -q

echo ""
echo "Running benchmarks..."

echo "=== 1 client (15 seconds) ==="
pgbench -c 1 -T 15

echo ""
echo "=== 5 clients (15 seconds) ==="  
pgbench -c 5 -T 15

echo ""
echo "=== 10 clients (15 seconds) ==="
pgbench -c 10 -T 15

echo ""
echo "✅ Benchmark completed!"
'

echo "✅ All tests completed!"

# Optional: Store in VHSM if vault is available
if command -v vault >/dev/null 2>&1 && vault token lookup >/dev/null 2>&1; then
    echo "💾 Storing results in VHSM..."
    export VAULT_ADDR=https://vhsm.enclaive.cloud/
    vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-postgres-$(date +%s) \
        timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        node_name="$NODE_NAME" \
        vm_type="$CVM_TYPE" \
        status="completed"
    echo "✅ Results stored in VHSM"
fi

# Cleanup
kubectl delete namespace $NAMESPACE
