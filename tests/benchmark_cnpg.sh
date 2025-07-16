#!/bin/bash
set -e

# Standalone CNPG Benchmark - No Vault Dependencies
NODE_NAME=$(hostname)

# Auto-detect VM type
if dmesg | grep -qi "Memory Encryption Features active: AMD SEV"; then
    CVM_TYPE="confidential"
elif dmesg | grep -qi "AMD Memory Encryption"; then
    CVM_TYPE="confidential"
else
    CVM_TYPE="regular"
fi

NAMESPACE="benchmark-perfect"
SCRIPT_DIR=$(dirname "$0")
LOG_FILE="/tmp/benchmark-${NODE_NAME}-$(date +%Y%m%d-%H%M%S).log"
RESULTS_FILE="/tmp/benchmark-results-${NODE_NAME}-$(date +%Y%m%d-%H%M%S).json"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling function
cleanup_on_error() {
    log "❌ Error occurred, cleaning up..."
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' | xargs -r kubectl delete pod -n "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
    log "🧹 Emergency cleanup completed"
    exit 1
}

# Set up error trap
trap cleanup_on_error ERR

log "🚀 Standalone CNPG Benchmark - $NODE_NAME ($CVM_TYPE VM)"

# Pre-flight checks
log "🔍 Pre-flight checks..."

if ! command -v kubectl &> /dev/null; then
    log "❌ kubectl is not available"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    log "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

if ! kubectl get crd clusters.postgresql.cnpg.io &> /dev/null; then
    log "❌ CNPG operator not found. Please install it first."
    exit 1
fi

# Check for available storage classes
STORAGE_CLASS=""
for sc in openebs-hostpath local-path hostpath standard gp2 default; do
    if kubectl get storageclass "$sc" &> /dev/null; then
        STORAGE_CLASS="$sc"
        log "✅ Using storage class: $STORAGE_CLASS"
        break
    fi
done

if [ -z "$STORAGE_CLASS" ]; then
    log "❌ No suitable storage class found"
    exit 1
fi

log "✅ Pre-flight checks passed"

# Enhanced cleanup
cleanup_existing_resources() {
    log "🧹 Cleaning up existing resources..."
    
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log "Found existing namespace, attempting graceful cleanup..."
        
        if kubectl get cluster postgres -n "$NAMESPACE" &>/dev/null; then
            kubectl delete cluster postgres -n "$NAMESPACE" --timeout=60s &>/dev/null || {
                log "⚠️ Graceful cluster deletion failed, forcing..."
                kubectl patch cluster postgres -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
                kubectl delete cluster postgres -n "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
            }
        fi
        
        log "⏳ Waiting for pods to terminate..."
        for i in {1..30}; do
            if ! kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
                break
            fi
            sleep 2
        done
        
        kubectl delete namespace "$NAMESPACE" --timeout=60s &>/dev/null || {
            log "⚠️ Graceful namespace deletion failed, forcing..."
            kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
            kubectl delete namespace "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
        }
    fi
    
    log "⏳ Waiting for namespace cleanup..."
    for i in {1..30}; do
        if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
            break
        fi
        sleep 2
    done
    
    log "✅ Cleanup completed"
}

# Perform cleanup
cleanup_existing_resources

# Create namespace
log "📦 Creating namespace..."
for i in {1..5}; do
    if kubectl create namespace "$NAMESPACE" &>/dev/null; then
        log "✅ Namespace created successfully"
        break
    fi
    log "⚠️ Namespace creation failed, retrying... ($i/5)"
    sleep 5
done

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log "❌ Failed to create namespace after retries"
    exit 1
fi

# Create PostgreSQL cluster
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
    storageClass: $STORAGE_CLASS
    size: 2Gi
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "1Gi"
      cpu: "500m"
  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "128MB"
      effective_cache_size: "512MB"
      maintenance_work_mem: "64MB"
      checkpoint_completion_target: "0.9"
      wal_buffers: "16MB"
      default_statistics_target: "100"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
EOF

# Wait for cluster to be ready
log "⏳ Waiting for PostgreSQL cluster to be ready..."
TIMEOUT=600
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    STATUS=$(kubectl get cluster postgres -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    if echo "$STATUS" | grep -q "Cluster in healthy state"; then
        log "✅ Cluster is healthy"
        break
    fi
    
    if echo "$STATUS" | grep -q "Failed"; then
        log "❌ Cluster failed to start"
        kubectl describe cluster postgres -n "$NAMESPACE"
        exit 1
    fi
    
    log "⏳ Cluster status: $STATUS"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "❌ Timeout waiting for cluster to be ready"
    exit 1
fi

log "⏳ Waiting for services to be ready..."
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n "$NAMESPACE" --timeout=300s

# Get credentials
log "🔑 Retrieving credentials..."
for i in {1..10}; do
    if POSTGRES_PASSWORD=$(kubectl get secret postgres-app -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); then
        if [ -n "$POSTGRES_PASSWORD" ]; then
            log "✅ Retrieved PostgreSQL password (length: ${#POSTGRES_PASSWORD})"
            break
        fi
    fi
    log "⚠️ Waiting for credentials... ($i/10)"
    sleep 5
done

if [ -z "$POSTGRES_PASSWORD" ]; then
    log "❌ Failed to retrieve PostgreSQL password"
    exit 1
fi

# Get service IP
for i in {1..10}; do
    if PG_IP=$(kubectl get svc postgres-rw -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null); then
        if [ -n "$PG_IP" ]; then
            log "✅ PostgreSQL service IP: $PG_IP"
            break
        fi
    fi
    log "⚠️ Waiting for service IP... ($i/10)"
    sleep 5
done

if [ -z "$PG_IP" ]; then
    log "❌ Failed to get service IP"
    exit 1
fi

# Test connection
log "🔌 Testing database connection..."
if ! kubectl run connection-test --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
    --env="PGPASSWORD=$POSTGRES_PASSWORD" \
    --env="PGHOST=$PG_IP" \
    --env="PGUSER=app" \
    --env="PGDATABASE=app" \
    --timeout=60s \
    -- psql -c "SELECT 1;" &>/dev/null; then
    log "❌ Database connection test failed"
    exit 1
fi

log "✅ Database connection successful"

# Setup database
log "🗄️ Setting up benchmark database..."
kubectl run setup-db --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
  --timeout=300s \
  -- bash -c '
set -e
echo "Connected to app database"
psql -c "SELECT current_database(), current_user;"

echo "Initializing pgbench in app database..."
if ! pgbench -i -s 10 -q; then
    echo "❌ pgbench initialization failed"
    exit 1
fi

echo "✅ pgbench tables created in app database"
psql -c "\dt pgbench*"

ROW_COUNT=$(psql -t -c "SELECT count(*) FROM pgbench_accounts;")
echo "✅ Created $ROW_COUNT accounts for benchmarking"
' || {
    log "❌ Database setup failed"
    exit 1
}

# Initialize results structure
cat > "$RESULTS_FILE" << EOF
{
  "node_name": "$NODE_NAME",
  "vm_type": "$CVM_TYPE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "benchmark_type": "postgresql_cnpg_standalone",
  "postgresql_version": "15",
  "scale_factor": 10,
  "total_rows": 1000000,
  "tests": {}
}
EOF

# Run benchmark
log "🚀 Running PostgreSQL benchmark..."
kubectl run pgbench-perfect --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
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
    
    # Run pgbench and capture output
    local output=$(pgbench "$@" 2>&1)
    echo "$output"
    
    # Extract TPS and latency
    local tps=$(echo "$output" | grep "tps =" | tail -1 | sed "s/.*tps = \([0-9.]*\).*/\1/")
    local latency=$(echo "$output" | grep "latency average =" | tail -1 | sed "s/.*latency average = \([0-9.]*\).*/\1/")
    
    echo "📊 RESULT: $description - TPS: $tps, Latency: ${latency}ms"
    echo ""
}

echo "🚀 Running comprehensive benchmark tests..."

# Basic tests
run_pgbench "Single Client Test (20 seconds)" -c 1 -j 1 -T 20 -P 5
run_pgbench "5 Clients Test (20 seconds)" -c 5 -j 2 -T 20 -P 5  
run_pgbench "10 Clients Test (20 seconds)" -c 10 -j 4 -T 20 -P 5
run_pgbench "Read-Only Test (20 seconds)" -c 10 -j 4 -T 20 -S -P 5

echo "=== EXTENDED RESEARCH BENCHMARKS ==="
echo ""

# High concurrency tests
run_pgbench "High Concurrency: 25 Clients (60 seconds)" -c 25 -j 8 -T 60 -P 10
run_pgbench "High Concurrency: 50 Clients (60 seconds)" -c 50 -j 12 -T 60 -P 10

# Sustained load test
run_pgbench "Sustained Load: 10 Clients (300 seconds)" -c 10 -j 4 -T 300 -P 30

# Write-heavy test
cat > /tmp/write_heavy.sql << '"'"'EOF'"'"'
INSERT INTO pgbench_accounts (aid, bid, abalance, filler) 
VALUES (random() * 100000, random() * 10 + 1, random() * 1000000, '"'"'heavy write test'"'"');
UPDATE pgbench_accounts SET abalance = abalance + 100 WHERE aid = (random() * 100000)::int;
DELETE FROM pgbench_accounts WHERE aid = (random() * 100000)::int AND abalance < 1000;
EOF
run_pgbench "Write-Heavy: Custom Script (60 seconds)" -c 10 -j 4 -T 60 -f /tmp/write_heavy.sql -P 10

# Large transaction test
cat > /tmp/large_transactions.sql << '"'"'EOF'"'"'
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid BETWEEN 1 AND 1000;
UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid BETWEEN 1001 AND 2000;
UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid BETWEEN 2001 AND 3000;
COMMIT;
EOF
run_pgbench "Large Transactions: Batch Updates (60 seconds)" -c 5 -j 2 -T 60 -f /tmp/large_transactions.sql -P 10

# Complex read queries
cat > /tmp/complex_reads.sql << '"'"'EOF'"'"'
SELECT a.aid, a.abalance, b.bbalance, t.tbalance 
FROM pgbench_accounts a 
JOIN pgbench_branches b ON a.bid = b.bid 
JOIN pgbench_tellers t ON a.bid = t.bid 
WHERE a.aid = (random() * 100000)::int;
EOF
run_pgbench "Complex Read Queries with Joins (60 seconds)" -c 10 -j 4 -T 60 -f /tmp/complex_reads.sql -P 10

# Mixed workload
cat > /tmp/mixed_workload.sql << '"'"'EOF'"'"'
\set aid random(1, 100000)
\set bid random(1, 10)
\set delta random(-5000, 5000)
\set r random(1, 100)
\if :r <= 70
    SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
\else
    UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
\endif
EOF
run_pgbench "Mixed Workload: 70% Read, 30% Write (120 seconds)" -c 15 -j 6 -T 120 -f /tmp/mixed_workload.sql -P 20

# Connection stress test
run_pgbench "Connection Stress Test: 100 Connections (30 seconds)" -c 100 -j 20 -T 30 -P 5

# Prepared statements test
run_pgbench "Prepared Statements Test (60 seconds)" -c 10 -j 4 -T 60 -M prepared -P 10

# Performance metrics
echo "=== Detailed Performance Analysis ==="
echo "Database size:"
psql -c "SELECT pg_size_pretty(pg_database_size('"'"'app'"'"'));"

echo "Table sizes:"
psql -c "SELECT schemaname,tablename,pg_size_pretty(pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename)) as size FROM pg_tables WHERE schemaname='"'"'public'"'"' ORDER BY pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename) DESC;"

echo "Cache hit ratio:"
psql -c "SELECT datname, round(blks_hit::float/(blks_hit+blks_read)*100, 2) as cache_hit_ratio FROM pg_stat_database WHERE datname = '"'"'app'"'"';"

# Cleanup temporary files
rm -f /tmp/write_heavy.sql /tmp/large_transactions.sql /tmp/complex_reads.sql /tmp/mixed_workload.sql

echo ""
echo "✅ Standalone PostgreSQL benchmark completed successfully!"
echo "📊 All tests completed on '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
' | tee -a "$LOG_FILE" || {
    log "❌ Benchmark execution failed"
    exit 1
}

# Final cleanup
log "🧹 Cleaning up resources..."
kubectl delete namespace "$NAMESPACE" --timeout=60s &>/dev/null || {
    log "⚠️ Graceful cleanup failed, forcing..."
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
}

log "✅ Cleanup completed"
log "🎉 Standalone CNPG PostgreSQL benchmark completed successfully!"
log "📁 Results saved to:"
log "   Log file: $LOG_FILE"
log "   JSON file: $RESULTS_FILE"

echo ""
echo "🎯 Benchmark Summary:"
echo "   Node: $NODE_NAME ($CVM_TYPE VM)"
echo "   Log file: $LOG_FILE"
echo "   JSON file: $RESULTS_FILE"
echo "   Status: ✅ Success"

# Extract key metrics for quick comparison
echo ""
echo "📊 Quick Results Summary:"
echo "----------------------------------------"
grep -E "📊 RESULT:|Single Client Test|High Concurrency|Sustained Load|Write-Heavy" "$LOG_FILE" | head -10 || echo "No summary data found"

echo ""
echo "🔬 For your research paper:"
echo "   - Compare TPS values between cVM and regular VM"
echo "   - Analyze latency differences in sustained load tests"
echo "   - Look for write-heavy performance impact (encryption overhead)"
echo "   - Document connection handling differences"
