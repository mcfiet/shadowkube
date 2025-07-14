#!/bin/bash
set -e

# VHSM Environment
export VAULT_ADDR=https://vhsm.enclaive.cloud/

NODE_NAME=$(hostname)
CVM_TYPE="regular"
if sudo dmesg 2>/dev/null | grep -qi "Memory Encryption"; then
    CVM_TYPE="confidential"
fi

echo "🚀 VHSM PostgreSQL Benchmark - $NODE_NAME ($CVM_TYPE)"

# Check VHSM connection
if ! vault token lookup >/dev/null 2>&1; then
    echo "❌ VHSM vault not authenticated. Please run: vault login"
    exit 1
fi

echo "✅ VHSM vault connection verified"

# Get existing CNPG credentials from VHSM
echo "🔐 Getting PostgreSQL credentials from VHSM..."
POSTGRES_SUPERUSER_PASSWORD=$(vault read -namespace=team-msc -field=superuser_password cubbyhole/cluster-shared/cnpg 2>/dev/null || echo "")
PGBENCH_PASSWORD=$(vault read -namespace=team-msc -field=pgbench_password cubbyhole/cluster-shared/benchmark 2>/dev/null || echo "")

if [ -z "$POSTGRES_SUPERUSER_PASSWORD" ] || [ -z "$PGBENCH_PASSWORD" ]; then
    echo "❌ Missing VHSM credentials. Please run the VHSM setup first."
    exit 1
fi

echo "✅ VHSM credentials retrieved"

# Create unique namespace
NAMESPACE="pgbench-$(date +%s)"
echo "📁 Using namespace: $NAMESPACE"

# Create namespace
kubectl create namespace $NAMESPACE

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up..."
    kubectl delete namespace $NAMESPACE --ignore-not-found=true --wait=false &
}
trap cleanup EXIT

# Create PostgreSQL cluster with VHSM credentials
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgres-superuser
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
data:
  username: $(echo -n postgres | base64)
  password: $(echo -n "$POSTGRES_SUPERUSER_PASSWORD" | base64)
---
apiVersion: v1
kind: Secret  
metadata:
  name: benchmark-credentials
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
data:
  username: $(echo -n pgbench | base64)
  password: $(echo -n "$PGBENCH_PASSWORD" | base64)
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: benchmark-pg
  namespace: $NAMESPACE
spec:
  instances: 1
  
  bootstrap:
    initdb:
      database: benchmark
      owner: postgres
      secret:
        name: postgres-superuser
  
  storage:
    storageClass: openebs-hostpath
    size: 2Gi
EOF

echo "⏳ Waiting for PostgreSQL cluster..."
kubectl wait --for=condition=Ready cluster/benchmark-pg -n $NAMESPACE --timeout=300s

echo "✅ PostgreSQL cluster ready!"

# Wait a bit more for service to be fully ready
sleep 10

# Get the actual service IP for debugging
PG_SERVICE_IP=$(kubectl get svc benchmark-pg-rw -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')
echo "📡 PostgreSQL service IP: $PG_SERVICE_IP"

# Create benchmark job with proper DNS and credentials
cat << EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: pgbench-job
  namespace: $NAMESPACE
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: pgbench
        image: postgres:15-alpine
        env:
        - name: PGHOST
          value: "benchmark-pg-rw.$NAMESPACE.svc.cluster.local"
        - name: PGPORT
          value: "5432"
        - name: PGUSER
          value: "postgres"
        - name: PGPASSWORD
          value: "$POSTGRES_SUPERUSER_PASSWORD"
        - name: PGDATABASE
          value: "postgres"
        command:
        - bash
        - -c
        - |
          echo "🔗 Connecting to PostgreSQL..."
          echo "Host: \$PGHOST"
          echo "User: \$PGUSER"
          
          # Wait for connection with better error handling
          for i in {1..60}; do
            if pg_isready -h \$PGHOST -p \$PGPORT -U \$PGUSER; then
              echo "✅ PostgreSQL is ready!"
              break
            fi
            echo "Waiting for PostgreSQL... (\$i/60)"
            sleep 2
          done
          
          # Test connection
          echo "Testing connection..."
          psql -h \$PGHOST -U \$PGUSER -d \$PGDATABASE -c "SELECT version();" || exit 1
          
          # Create benchmark database
          echo "🗄️ Creating benchmark database..."
          createdb -h \$PGHOST -U \$PGUSER benchmark || echo "Database might exist"
          export PGDATABASE=benchmark
          
          echo "📊 Initializing pgbench (scale 10)..."
          pgbench -h \$PGHOST -U \$PGUSER -d benchmark -i -s 10 -q
          
          echo ""
          echo "🚀 Running benchmarks on $NODE_NAME ($CVM_TYPE VM)..."
          echo ""
          
          echo "=== Single Client (30 seconds) ==="
          pgbench -h \$PGHOST -U \$PGUSER -d benchmark -c 1 -j 1 -T 30 -P 5 -r
          
          echo ""
          echo "=== 5 Clients (30 seconds) ==="
          pgbench -h \$PGHOST -U \$PGUSER -d benchmark -c 5 -j 2 -T 30 -P 5 -r
          
          echo ""
          echo "=== 10 Clients (30 seconds) ==="
          pgbench -h \$PGHOST -U \$PGUSER -d benchmark -c 10 -j 4 -T 30 -P 5 -r
          
          echo ""
          echo "=== Read-Only Test (30 seconds) ==="
          pgbench -h \$PGHOST -U \$PGUSER -d benchmark -c 10 -j 4 -T 30 -S -P 5 -r
          
          echo ""
          echo "✅ Benchmark completed!"
EOF

echo "🏃 Running pgbench job..."
kubectl wait --for=condition=complete job/pgbench-job -n $NAMESPACE --timeout=600s

echo ""
echo "📊 Benchmark Results:"
RESULTS=$(kubectl logs job/pgbench-job -n $NAMESPACE)
echo "$RESULTS"

# Extract TPS values
TPS_1=$(echo "$RESULTS" | grep -A10 "Single Client" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
TPS_5=$(echo "$RESULTS" | grep -A10 "5 Clients" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
TPS_10=$(echo "$RESULTS" | grep -A10 "10 Clients" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
TPS_READ=$(echo "$RESULTS" | grep -A10 "Read-Only" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")

echo ""
echo "📈 Summary:"
echo "  Single client: $TPS_1 TPS"
echo "  5 clients:     $TPS_5 TPS" 
echo "  10 clients:    $TPS_10 TPS"
echo "  Read-only:     $TPS_READ TPS"

# Store results back in VHSM
echo ""
echo "💾 Storing results in VHSM..."
vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-postgres-$(date +%Y%m%d-%H%M%S) \
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    node_name="$NODE_NAME" \
    vm_type="$CVM_TYPE" \
    postgres_single_client_tps="$TPS_1" \
    postgres_5_client_tps="$TPS_5" \
    postgres_10_client_tps="$TPS_10" \
    postgres_readonly_tps="$TPS_READ" \
    benchmark_type="postgresql_cnpg" \
    credentials_source="vhsm"

echo "✅ VHSM PostgreSQL benchmark completed!"
echo "🔐 All credentials managed via VHSM"
echo "📊 Results stored in VHSM for analysis"
