#!/bin/bash
set -e

NODE_NAME=$(hostname)
CVM_TYPE="confidential"

echo "🚀 Simple Working PostgreSQL Benchmark - $NODE_NAME"

NAMESPACE="pgbench-simple"
kubectl delete namespace $NAMESPACE --ignore-not-found=true --wait=true
sleep 5
kubectl create namespace $NAMESPACE

# Create minimal cluster
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

echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=Ready cluster/pg -n $NAMESPACE --timeout=300s

# Wait longer for everything to be fully initialized
echo "⏳ Waiting for services and secrets..."
sleep 30

# Check if secret exists, if not wait more
for i in {1..20}; do
    if kubectl get secret pg-superuser -n $NAMESPACE >/dev/null 2>&1; then
        break
    fi
    echo "Waiting for superuser secret... ($i/20)"
    sleep 3
done

# Get password
PG_PASSWORD=$(kubectl get secret pg-superuser -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
echo "Password retrieved: ${#PG_PASSWORD} characters"

# Get service IP for direct connection
PG_IP=$(kubectl get svc pg-rw -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')
echo "PostgreSQL IP: $PG_IP"

# Simple benchmark using IP instead of DNS
echo "🚀 Running benchmark..."
kubectl run benchmark --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never << BENCHMARK_EOF
#!/bin/bash
export PGPASSWORD='$PG_PASSWORD'
export PGHOST='$PG_IP'
export PGUSER='postgres'
export PGDATABASE='postgres'

echo "Testing connection to $PG_IP..."
pg_isready -h $PG_IP -U postgres

echo "Creating benchmark database..."
createdb benchmark -h $PG_IP -U postgres
export PGDATABASE='benchmark'

echo "Initializing pgbench..."
pgbench -h $PG_IP -U postgres -d benchmark -i -s 5 -q

echo ""
echo "=== PostgreSQL Benchmark Results ==="
echo "Node: $NODE_NAME ($CVM_TYPE VM)"
echo ""

echo "Single client test:"
pgbench -h $PG_IP -U postgres -d benchmark -c 1 -T 10 | grep "tps ="

echo ""
echo "5 clients test:"
pgbench -h $PG_IP -U postgres -d benchmark -c 5 -T 10 | grep "tps ="

echo ""
echo "10 clients test:"
pgbench -h $PG_IP -U postgres -d benchmark -c 10 -T 10 | grep "tps ="

echo ""
echo "✅ Benchmark completed!"
BENCHMARK_EOF

echo "✅ PostgreSQL benchmark finished!"

# Optional VHSM storage
if command -v vault >/dev/null 2>&1; then
    export VAULT_ADDR=https://vhsm.enclaive.cloud/
    if vault token lookup >/dev/null 2>&1; then
        vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-postgres-$(date +%s) \
            node="$NODE_NAME" vm_type="$CVM_TYPE" status="completed" timestamp="$(date)"
        echo "💾 Results stored in VHSM"
    fi
fi

# Cleanup
kubectl delete namespace $NAMESPACE
