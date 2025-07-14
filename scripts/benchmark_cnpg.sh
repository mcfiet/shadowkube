#!/bin/bash
set -e

export VAULT_ADDR=https://vhsm.enclaive.cloud/

NODE_NAME=$(hostname)
CVM_TYPE="confidential"  # We know it's confidential from your output

echo "🚀 Debug VHSM PostgreSQL Benchmark - $NODE_NAME ($CVM_TYPE)"

# Get credentials
POSTGRES_SUPERUSER_PASSWORD=$(vault read -namespace=team-msc -field=superuser_password cubbyhole/cluster-shared/cnpg)
echo "✅ Got password (length: ${#POSTGRES_SUPERUSER_PASSWORD})"

NAMESPACE="pgbench-debug"
kubectl delete namespace $NAMESPACE --ignore-not-found=true --wait=true
kubectl create namespace $NAMESPACE

# Simple cluster first
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

echo "⏳ Waiting for cluster..."
kubectl wait --for=condition=Ready cluster/pg -n $NAMESPACE --timeout=300s

echo "✅ Cluster ready, checking services..."
kubectl get svc -n $NAMESPACE
kubectl get pods -n $NAMESPACE

# Get the actual superuser password from the cluster
ACTUAL_PASSWORD=$(kubectl get secret pg-superuser -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
echo "🔐 Using cluster-generated password"

# Simple test first
echo "🧪 Testing connection..."
kubectl run test-connection --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never -- bash -c "
export PGPASSWORD='$ACTUAL_PASSWORD'
echo 'Testing pg_isready...'
pg_isready -h pg-rw -U postgres
echo 'Testing simple query...'
psql -h pg-rw -U postgres -d postgres -c 'SELECT version();'
echo 'Connection test successful!'
"

# Now run actual benchmark
echo "🚀 Running actual benchmark..."
kubectl run pgbench-simple --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never -- bash -c "
export PGPASSWORD='$ACTUAL_PASSWORD'
export PGHOST=pg-rw
export PGUSER=postgres
export PGDATABASE=postgres

echo 'Setting up benchmark...'
createdb benchmark || true
export PGDATABASE=benchmark

echo 'Initializing pgbench...'
pgbench -i -s 5 -q

echo 'Running benchmarks...'
echo '=== 1 client ==='
pgbench -c 1 -T 15 | grep 'tps ='

echo '=== 5 clients ==='  
pgbench -c 5 -T 15 | grep 'tps ='


echo 'Benchmark complete!'
"

# Store results in VHSM
vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-postgres-debug \
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    node_name="$NODE_NAME" \
    vm_type="$CVM_TYPE" \
    status="completed"

echo "✅ Debug benchmark completed!"

# Cleanup
kubectl delete namespace $NAMESPACE
