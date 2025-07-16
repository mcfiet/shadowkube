#!/bin/bash
set -e

# CNPG Benchmark using the postgres-app secret that CNPG creates
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

log "🚀 CNPG App Benchmark - $NODE_NAME ($CVM_TYPE VM)"

# Clean up first
log "🧹 Quick cleanup..."
kubectl delete namespace "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
sleep 5

# Create namespace
log "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE"

# Create simple cluster that will create postgres-app secret
log "🗄️ Creating PostgreSQL cluster..."
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
  bootstrap:
    initdb:
      database: app
      owner: app
EOF

# Wait for cluster
log "⏳ Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready cluster/postgres -n "$NAMESPACE" --timeout=300s

# Wait for pods
log "⏳ Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n "$NAMESPACE" --timeout=300s

log "✅ Cluster is ready!"

# Get service IP
PG_IP=$(kubectl get svc postgres-rw -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
log "📡 PostgreSQL service: $PG_IP"

# Debug the postgres-app secret structure
log "🔍 Analyzing postgres-app secret structure..."
kubectl get secret postgres-app -n "$NAMESPACE" -o yaml | head -20

# Get credentials from postgres-app secret
log "🔑 Getting credentials from postgres-app secret..."

# Let's see what fields are actually in the secret
log "Fields in postgres-app secret:"
kubectl get secret postgres-app -n "$NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || {
    log "Using base64 to check fields..."
    kubectl get secret postgres-app -n "$NAMESPACE" -o yaml | grep "  [a-zA-Z]" | cut -d: -f1 | sed 's/  //'
}

# Try to get username and password with various field names
APP_USER=""
APP_PASSWORD=""

# Common field names for username
for field in username user owner dbname; do
    if TEMP_USER=$(kubectl get secret postgres-app -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null | base64 -d 2>/dev/null); then
        if [ -n "$TEMP_USER" ]; then
            APP_USER="$TEMP_USER"
            log "Found username in field '$field': $APP_USER"
            break
        fi
    fi
done

# Common field names for password  
for field in password pass pwd; do
    if TEMP_PASSWORD=$(kubectl get secret postgres-app -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null | base64 -d 2>/dev/null); then
        if [ -n "$TEMP_PASSWORD" ]; then
            APP_PASSWORD="$TEMP_PASSWORD"
            log "Found password in field '$field' (length: ${#APP_PASSWORD})"
            break
        fi
    fi
done

# Fallback to default values if not found
APP_USER=${APP_USER:-"app"}
APP_DATABASE=${APP_DATABASE:-"app"}

if [ -z "$APP_PASSWORD" ]; then
    log "❌ Could not find password in postgres-app secret"
    log "Secret contents (field names only):"
    kubectl get secret postgres-app -n "$NAMESPACE" -o yaml
    exit 1
fi

log "✅ Using credentials: $APP_USER / password(${#APP_PASSWORD} chars) / database: $APP_DATABASE"

# Test connection
log "🔌 Testing database connection..."
kubectl run test-connection --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
    --env="PGPASSWORD=$APP_PASSWORD" \
    --env="PGHOST=$PG_IP" \
    --env="PGUSER=$APP_USER" \
    --env="PGDATABASE=$APP_DATABASE" \
    --timeout=60s \
    -- psql -c "SELECT current_database(), current_user, version();" || {
    log "❌ Connection test failed with app credentials"
    
    # Try with postgres user as fallback
    log "Trying with postgres user..."
    kubectl run test-postgres --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
        --env="PGPASSWORD=$APP_PASSWORD" \
        --env="PGHOST=$PG_IP" \
        --env="PGUSER=postgres" \
        --env="PGDATABASE=postgres" \
        --timeout=60s \
        -- psql -c "SELECT current_database(), current_user, version();" || {
        log "❌ Connection also failed with postgres user"
        exit 1
    }
    
    # Update credentials if postgres worked
    APP_USER="postgres"
    APP_DATABASE="postgres"
}

log "✅ Database connection successful"

# Set up pgbench
log "🗄️ Setting up pgbench..."
kubectl run setup-pgbench --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$APP_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=$APP_USER" \
  --env="PGDATABASE=$APP_DATABASE" \
  --timeout=300s \
  -- bash -c '
set -e

echo "=== Setting up pgbench ==="
echo "Connected to: $PGDATABASE as $PGUSER"

# Initialize pgbench
echo "Initializing pgbench with scale factor 10..."
if pgbench -i -s 10 -q; then
    echo "✅ pgbench initialized successfully"
    
    # Verify tables
    psql -c "\dt pgbench*"
    
    ROW_COUNT=$(psql -t -c "SELECT count(*) FROM pgbench_accounts;" | tr -d " ")
    echo "✅ Created $ROW_COUNT accounts for benchmarking"
    
    echo "=== pgbench setup completed ==="
else
    echo "❌ pgbench initialization failed"
    exit 1
fi
' || {
    log "❌ pgbench setup failed"
    exit 1
}

# Run comprehensive benchmark
log "🚀 Running comprehensive PostgreSQL benchmark..."
kubectl run pgbench-benchmark --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$APP_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=$APP_USER" \
  --env="PGDATABASE=$APP_DATABASE" \
  --timeout=1800s \
  -- bash -c '
set -e

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

echo "🚀 Running comprehensive benchmark tests..."

# Basic performance tests
run_pgbench "Single Client Test (20 seconds)" -c 1 -j 1 -T 20 -P 5
run_pgbench "5 Clients Test (20 seconds)" -c 5 -j 2 -T 20 -P 5  
run_pgbench "10 Clients Test (20 seconds)" -c 10 -j 4 -T 20 -P 5
run_pgbench "Read-Only Test (20 seconds)" -c 10 -j 4 -T 20 -S -P 5

echo "=== RESEARCH BENCHMARKS ==="
echo ""

# High concurrency tests (critical for cVM vs regular VM comparison)
run_pgbench "High Concurrency: 25 Clients (60 seconds)" -c 25 -j 8 -T 60 -P 10
run_pgbench "High Concurrency: 50 Clients (60 seconds)" -c 50 -j 12 -T 60 -P 10

# Sustained load test (important for confidential computing overhead)
run_pgbench "Sustained Load: 10 Clients (300 seconds)" -c 10 -j 4 -T 300 -P 30

# Write-heavy test (uses standard TPC-B workload - no custom SQL)
run_pgbench "Write-Heavy: TPC-B Workload (60 seconds)" -c 10 -j 4 -T 60 -P 10

# Mixed read/write test
run_pgbench "Mixed Workload: Default TPC-B (120 seconds)" -c 15 -j 6 -T 120 -P 20

# Connection stress test
run_pgbench "Connection Stress: 50 Connections (30 seconds)" -c 50 -j 10 -T 30 -P 5

# Prepared statements test
run_pgbench "Prepared Statements Test (60 seconds)" -c 10 -j 4 -T 60 -M prepared -P 10

# Large dataset test
run_pgbench "Large Dataset Test (60 seconds)" -c 10 -j 4 -T 60 -P 10

# Performance analysis
echo "=== Detailed Performance Analysis ==="
echo "Database size:"
psql -c "SELECT pg_size_pretty(pg_database_size(current_database())) as database_size;"

echo "Table sizes:"
psql -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename)) as size FROM pg_tables WHERE schemaname='"'"'public'"'"' ORDER BY pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename) DESC;"

echo "Cache hit ratio:"
psql -c "SELECT datname, round(blks_hit::float/(blks_hit+blks_read)*100, 2) as cache_hit_ratio FROM pg_stat_database WHERE datname = current_database();"

echo "Connection info:"
psql -c "SELECT count(*) as active_connections FROM pg_stat_activity WHERE state = '"'"'active'"'"';"

echo ""
echo "✅ Comprehensive PostgreSQL benchmark completed!"
echo "📊 All tests completed on '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
' | tee -a "$LOG_FILE" || {
    log "❌ Benchmark execution failed"
    exit 1
}

# Cleanup
log "🧹 Cleaning up resources..."
kubectl delete namespace "$NAMESPACE" --timeout=60s &>/dev/null || {
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
}

log "✅ CNPG benchmark completed successfully!"
log "📁 Full results saved to: $LOG_FILE"

echo ""
echo "🎯 Benchmark Summary:"
echo "   Node: $NODE_NAME ($CVM_TYPE VM)"
echo "   Log file: $LOG_FILE"
echo "   Status: ✅ Success"

# Extract and display key results
echo ""
echo "📊 Performance Summary:"
echo "----------------------------------------"
grep -E "📊 RESULT:" "$LOG_FILE" | head -10 || echo "No results extracted"

echo ""
echo "🔬 For your research paper:"
echo "   - Compare TPS values between confidential and regular VMs"
echo "   - Focus on high concurrency and sustained load differences"
echo "   - Analyze write-heavy workload performance impact"
echo "   - Document connection handling and latency variations"

echo ""
echo "💾 Next steps:"
echo "   1. Run this script on your regular VM setup"
echo "   2. Compare the TPS results between both environments"
echo "   3. Calculate performance overhead percentages"
echo "   4. Include results in your research paper analysis"
