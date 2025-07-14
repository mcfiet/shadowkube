#!/bin/bash
set -e

NODE_NAME=$(hostname)
CVM_TYPE="confidential"

echo "🚀 Final Working CNPG Benchmark - $NODE_NAME"

NAMESPACE="benchmark-final"
kubectl delete namespace $NAMESPACE --ignore-not-found=true --wait=true
kubectl create namespace $NAMESPACE

# Create cluster WITHOUT custom credentials - let CNPG handle it
cat << EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  instances: 1
  storage:
    storageClass: openebs-hostpath
    size: 1Gi
EOF

echo "⏳ Waiting for PostgreSQL cluster..."
kubectl wait --for=condition=Ready cluster/postgres -n $NAMESPACE --timeout=300s

echo "⏳ Waiting for services and all pods to be ready..."
sleep 30

# Check what secrets actually exist
echo "🔍 Available secrets:"
kubectl get secrets -n $NAMESPACE | grep postgres

# Try different secret names that CNPG might create
for secret_name in postgres-superuser postgres-app postgres-postgres; do
    if kubectl get secret $secret_name -n $NAMESPACE >/dev/null 2>&1; then
        POSTGRES_PASSWORD=$(kubectl get secret $secret_name -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")
        SECRET_USER=$(kubectl get secret $secret_name -n $NAMESPACE -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo "postgres")
        if [ -n "$POSTGRES_PASSWORD" ]; then
            echo "✅ Found working secret: $secret_name (user: $SECRET_USER, password length: ${#POSTGRES_PASSWORD})"
            break
        fi
    fi
done

if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "❌ No valid password found, trying without password authentication"
    # Let's check the actual postgres configuration
    kubectl exec postgres-1 -n $NAMESPACE -- psql -U postgres -c "\du" || echo "Direct connection failed"
    exit 1
fi

# Get service info
PG_IP=$(kubectl get svc postgres-rw -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')
echo "📡 PostgreSQL service: $PG_IP"

# Test the actual credentials that work
echo "🧪 Testing authentication with found credentials..."
kubectl run auth-test --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" -- \
  psql -h $PG_IP -U $SECRET_USER -d postgres -c "SELECT current_user, version();"

echo "✅ Authentication successful!"

# Now run the actual benchmark
echo "🚀 Running PostgreSQL benchmark with working credentials..."
kubectl run pgbench-final --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=$SECRET_USER" \
  --env="PGDATABASE=postgres" \
  -- bash -c '
echo "=== PostgreSQL Performance Benchmark ==="
echo "Node: '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
echo "Host: $PGHOST"
echo "User: $PGUSER"
echo ""

# Create benchmark database if needed
echo "📊 Setting up benchmark database..."
createdb benchmark 2>/dev/null || echo "Database might already exist"
export PGDATABASE=benchmark

echo "Initializing pgbench (scale 10)..."
pgbench -i -s 10 -q

echo ""
echo "🚀 Running benchmark tests..."

echo ""
echo "=== Single Client Test (15 seconds) ==="
pgbench -c 1 -j 1 -T 15

echo ""  
echo "=== 5 Clients Test (15 seconds) ==="
pgbench -c 5 -j 2 -T 15

echo ""
echo "=== 10 Clients Test (15 seconds) ==="
pgbench -c 10 -j 4 -T 15

echo ""
echo "✅ PostgreSQL benchmark completed successfully!"
'

# Store results in VHSM if available
if command -v vault >/dev/null 2>&1; then
    export VAULT_ADDR=https://vhsm.enclaive.cloud/
    if vault token lookup >/dev/null 2>&1; then
        echo "💾 Storing results in VHSM..."
        vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-cnpg-final-$(date +%s) \
            timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            node_name="$NODE_NAME" \
            vm_type="$CVM_TYPE" \
            benchmark_type="postgresql_cnpg_final" \
            status="completed"
        echo "✅ Results stored in VHSM"
    fi
fi

echo "🎉 CNPG PostgreSQL benchmark completed successfully!"

# Cleanup
kubectl delete namespace $NAMESPACE
