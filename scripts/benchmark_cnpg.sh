#!/bin/bash
set -e

NODE_NAME=$(hostname)
CVM_TYPE="regular"
if sudo dmesg 2>/dev/null | grep -qi "Memory Encryption"; then
    CVM_TYPE="confidential"
fi

echo "🚀 Simple PostgreSQL Benchmark - $NODE_NAME ($CVM_TYPE)"

# Clean up any old stuff
kubectl delete namespace pgbench --ignore-not-found=true --wait=false
sleep 5

# Create namespace
kubectl create namespace pgbench

# Create dead simple cluster
cat << EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: simple-postgres
  namespace: pgbench
spec:
  instances: 1
  storage:
    storageClass: openebs-hostpath
    size: 1Gi
EOF

echo "⏳ Waiting for PostgreSQL (2 minutes max)..."
kubectl wait --for=condition=Ready cluster/simple-postgres -n pgbench --timeout=120s

echo "🏃 Running pgbench..."

# Run benchmark job
kubectl run pgbench-test --image=postgres:15-alpine -n pgbench --rm -i --restart=Never -- bash -c "
export PGHOST=simple-postgres-rw
export PGUSER=postgres
export PGPASSWORD=\$(kubectl get secret simple-postgres-superuser -n pgbench -o jsonpath='{.data.password}' | base64 -d)
export PGDATABASE=postgres

echo 'Waiting for connection...'
for i in {1..30}; do
  if pg_isready -h \$PGHOST -U \$PGUSER; then
    echo 'Connected!'
    break
  fi
  sleep 2
done

echo 'Creating test database...'
createdb pgbench || true
export PGDATABASE=pgbench

echo 'Initializing pgbench...'
pgbench -i -s 5

echo 'Running benchmarks...'
echo '=== 1 client ==='
pgbench -c 1 -T 15

echo '=== 5 clients ==='
pgbench -c 5 -T 15  

echo '=== 10 clients ==='
pgbench -c 10 -T 15

echo 'Done!'
"

# Cleanup
kubectl delete namespace pgbench

echo "✅ Benchmark complete!"
