#!/bin/bash
set -e

# Simple CNPG Benchmark - Just use what CNPG gives us
NODE_NAME=$(hostname)

# Auto-detect VM type
if dmesg 2>/dev/null | grep -qi "Memory Encryption Features active: AMD SEV"; then
    CVM_TYPE="confidential"
elif dmesg 2>/dev/null | grep -qi "AMD Memory Encryption"; then
    CVM_TYPE="confidential"
else
    CVM_TYPE="regular"
fi

NAMESPACE="benchmark-perfect"
LOG_FILE="/tmp/benchmark-${NODE_NAME}-$(date +%Y%m%d-%H%M%S).log"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "🚀 Simple CNPG Benchmark - $NODE_NAME ($CVM_TYPE VM)"

# Clean up
log "🧹 Quick cleanup..."
kubectl delete namespace "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
sleep 5

# Create namespace
log "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE"

# Create the simplest possible CNPG cluster
log "🗄️ Creating simple PostgreSQL cluster..."
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  instances: 1
  storage:
    size: 1Gi
EOF

# Wait for cluster
log "⏳ Waiting for cluster..."
kubectl wait --for=condition=Ready cluster/postgres -n "$NAMESPACE" --timeout=300s

# Wait for pods
log "⏳ Waiting for pods..."
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n "$NAMESPACE" --timeout=300s

log "✅ Cluster is ready!"

# Get service IP
PG_IP=$(kubectl get svc postgres-rw -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
log "📡 PostgreSQL service: $PG_IP"

# Show all secrets CNPG created
log "🔍 Available secrets:"
kubectl get secrets -n "$NAMESPACE" | grep -v "default-token"

# Try to find ANY working credentials
log "🔑 Finding working credentials..."

# Try all possible secret and field combinations
WORKING_CREDS=""
for secret in postgres-superuser postgres-app postgres-owner postgres; do
    if kubectl get secret "$secret" -n "$NAMESPACE" &>/dev/null; then
        log "Found secret: $secret"
        
        for user_field in username user owner; do
            for pass_field in password POSTGRES_PASSWORD; do
                USER=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath="{.data.$user_field}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
                PASS=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath="{.data.$pass_field}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
                
                if [ -n "$PASS" ]; then
                    # Default user if not found
                    USER=${USER:-"postgres"}
                    
                    log "Testing: $USER / password(${#PASS} chars) from secret $secret"
                    
                    # Test this combination
                    if kubectl run test-conn --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
                        --env="PGPASSWORD=$PASS" \
                        --env="PGHOST=$PG_IP" \
                        --env="PGUSER=$USER" \
                        --timeout=30s \
                        -- psql -c "SELECT 1;" &>/dev/null; then
                        
                        log "✅ Working credentials found: $USER from $secret"
                        WORKING_CREDS="$USER:$PASS"
                        break 3
                    fi
                fi
            done
        done
    fi
done

if [ -z "$WORKING_CREDS" ]; then
    log "❌ No working credentials found"
    log "Let's try connecting directly to the pod:"
    kubectl exec postgres-1 -n "$NAMESPACE" -- psql -U postgres -c "SELECT 1;" || log "Direct connection also failed"
    exit 1
fi

# Parse working credentials
POSTGRES_USER=$(echo "$WORKING_CREDS" | cut -d: -f1)
POSTGRES_PASSWORD=$(echo "$WORKING_CREDS" | cut -d: -f2)

log "✅ Using credentials: $POSTGRES_USER / password(${#POSTGRES_PASSWORD} chars)"

# Set up pgbench in the working database
log "🗄️ Setting up pgbench..."
kubectl run setup-pgbench --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=$POSTGRES_USER" \
  --timeout=300s \
  -- bash -c '
set -e

# Figure out what database to use
echo "=== Finding usable database ==="

# Try different databases
for db in postgres app template1; do
    echo "Trying database: $db"
    if PGDATABASE=$db psql -c "SELECT current_database();" 2>/dev/null; then
        echo "✅ Using database: $db"
        export PGDATABASE=$db
        break
    fi
done

if [ -z "$PGDATABASE" ]; then
    echo "❌ No accessible database found"
    exit 1
fi

echo "=== Setting up pgbench in $PGDATABASE ==="
echo "User: $PGUSER"
echo "Database: $PGDATABASE"

# Initialize pgbench
if pgbench -i -s 10 -q; then
    echo "✅ pgbench initialized successfully"
    psql -c "\dt pgbench*"
    
    ROW_COUNT=$(psql -t -c "SELECT count(*) FROM pgbench_accounts;" | tr -d " ")
    echo "✅ Created $ROW_COUNT accounts for benchmarking"
else
    echo "❌ pgbench initialization failed"
    exit 1
fi
' || {
    log "❌ pgbench setup failed"
    exit 1
}

# Run the actual benchmark
log "🚀 Running PostgreSQL benchmark..."
kubectl run pgbench-test --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=$POSTGRES_USER" \
  --timeout=1200s \
  -- bash -c '
set -e

# Find the database with pgbench tables
for db in postgres app template1; do
    if PGDATABASE=$db psql -c "SELECT count(*) FROM pgbench_accounts;" &>/dev/null; then
        export PGDATABASE=$db
        break
    fi
done

echo "=== PostgreSQL Performance Benchmark ==="
echo "Node: '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
echo "Host: $PGHOST"
echo "Database: $PGDATABASE"
echo "User: $PGUSER"
echo "Timestamp: $(date)"
echo ""

# Function to run pgbench and extract TPS
run_pgbench() {
    local description="$1"
    shift
    echo "=== $description ==="
    
    local output=$(pgbench "$@" 2>&1)
    echo "$output"
    
    # Extract TPS and latency
    local tps=$(echo "$output" | grep "tps =" | tail -1 | sed "s/.*tps = \([0-9.]*\).*/\1/" || echo "N/A")
    local latency=$(echo "$output" | grep "latency average =" | tail -1 | sed "s/.*latency average = \([0-9.]*\).*/\1/" || echo "N/A")
    
    echo "📊 RESULT: $description - TPS: $tps, Latency: ${latency}ms"
    echo ""
}

echo "🚀 Running core benchmark tests..."

# Core tests that should work
run_pgbench "Single Client Test (20 seconds)" -c 1 -j 1 -T 20 -P 5
run_pgbench "5 Clients Test (20 seconds)" -c 5 -j 2 -T 20 -P 5  
run_pgbench "10 Clients Test (20 seconds)" -c 10 -j 4 -T 20 -P 5
run_pgbench "Read-Only Test (20 seconds)" -c 10 -j 4 -T 20 -S -P 5

echo "=== RESEARCH BENCHMARKS ==="

# High concurrency
run_pgbench "High Concurrency: 25 Clients (60 seconds)" -c 25 -j 8 -T 60 -P 10
run_pgbench "High Concurrency: 50 Clients (60 seconds)" -c 50 -j 12 -T 60 -P 10

# Sustained load
run_pgbench "Sustained Load: 10 Clients (180 seconds)" -c 10 -j 4 -T 180 -P 30

# Simple write test (just standard pgbench)
run_pgbench "Write Test: Standard TPC-B (60 seconds)" -c 10 -j 4 -T 60 -P 10

# Read-heavy test
run_pgbench "Read-Heavy Test: Select Only (60 seconds)" -c 15 -j 6 -T 60 -S -P 10

# Connection test
run_pgbench "Connection Test: 50 Connections (30 seconds)" -c 50 -j 10 -T 30 -P 5

# Performance info
echo "=== Database Information ==="
psql -c "SELECT pg_size_pretty(pg_database_size(current_database())) as db_size;"
psql -c "SELECT count(*) as pgbench_accounts FROM pgbench_accounts;"
psql -c "SELECT version();"

echo ""
echo "✅ Simple PostgreSQL benchmark completed!"
echo "📊 All core tests completed on '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
' | tee -a "$LOG_FILE" || {
    log "❌ Benchmark failed"
    exit 1
}

# Cleanup
log "🧹 Cleaning up..."
kubectl delete namespace "$NAMESPACE" --force --grace-period=0 &>/dev/null || true

log "✅ Simple benchmark completed!"
log "📁 Full log: $LOG_FILE"

echo ""
echo "🎯 Benchmark Summary:"
echo "   Node: $NODE_NAME ($CVM_TYPE VM)"
echo "   Log file: $LOG_FILE"
echo "   Status: ✅ Success"

# Show key results
echo ""
echo "📊 Key Results:"
grep -E "📊 RESULT:" "$LOG_FILE" | head -8 || echo "No results found"

echo ""
echo "🔬 For comparison:"
echo "   - Run this same script on both VM types"
echo "   - Compare TPS numbers between confidential and regular VMs"
echo "   - Look for latency differences in sustained load tests"
