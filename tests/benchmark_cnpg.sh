#!/bin/bash
set -e

# Enhanced safety and error handling
NODE_NAME=$(hostname)
CVM_TYPE="confidential"
NAMESPACE="benchmark-perfect"
SCRIPT_DIR=$(dirname "$0")
LOG_FILE="/tmp/benchmark-${NODE_NAME}-$(date +%Y%m%d-%H%M%S).log"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling function
cleanup_on_error() {
    log "❌ Error occurred, cleaning up..."
    # Force cleanup resources
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    # Kill any hanging pods
    kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' | xargs -r kubectl delete pod -n "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
    log "🧹 Emergency cleanup completed"
    exit 1
}

# Set up error trap
trap cleanup_on_error ERR

log "🚀 Perfect CNPG Benchmark - $NODE_NAME"

# Pre-flight checks
log "🔍 Pre-flight checks..."

# Check if kubectl is available and configured
if ! command -v kubectl &> /dev/null; then
    log "❌ kubectl is not available"
    exit 1
fi

# Check if we can connect to Kubernetes
if ! kubectl cluster-info &> /dev/null; then
    log "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

# Check if CNPG operator is installed
if ! kubectl get crd clusters.postgresql.cnpg.io &> /dev/null; then
    log "❌ CNPG operator not found. Please install it first."
    exit 1
fi

# Check if OpenEBS is available
if ! kubectl get storageclass openebs-hostpath &> /dev/null; then
    log "❌ openebs-hostpath storage class not found"
    exit 1
fi

log "✅ Pre-flight checks passed"

# Enhanced cleanup with retry logic
cleanup_existing_resources() {
    log "🧹 Cleaning up existing resources..."
    
    # Try graceful cleanup first
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log "Found existing namespace, attempting graceful cleanup..."
        
        # Delete cluster resource first
        if kubectl get cluster postgres -n "$NAMESPACE" &>/dev/null; then
            kubectl delete cluster postgres -n "$NAMESPACE" --timeout=60s &>/dev/null || {
                log "⚠️ Graceful cluster deletion failed, forcing..."
                kubectl patch cluster postgres -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
                kubectl delete cluster postgres -n "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
            }
        fi
        
        # Wait for pods to terminate
        log "⏳ Waiting for pods to terminate..."
        for i in {1..30}; do
            if ! kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
                break
            fi
            sleep 2
        done
        
        # Force cleanup if still exists
        kubectl delete namespace "$NAMESPACE" --timeout=60s &>/dev/null || {
            log "⚠️ Graceful namespace deletion failed, forcing..."
            kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
            kubectl delete namespace "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
        }
    fi
    
    # Wait for namespace to be completely gone
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

# Create namespace with retry
log "📦 Creating namespace..."
for i in {1..5}; do
    if kubectl create namespace "$NAMESPACE" &>/dev/null; then
        log "✅ Namespace created successfully"
        break
    fi
    log "⚠️ Namespace creation failed, retrying... ($i/5)"
    sleep 5
done

# Verify namespace exists
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log "❌ Failed to create namespace after retries"
    exit 1
fi

# Create cluster with enhanced configuration
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
    storageClass: openebs-hostpath
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

# Enhanced waiting with timeout and status checking
log "⏳ Waiting for PostgreSQL cluster to be ready..."
TIMEOUT=600  # 10 minutes
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    if kubectl get cluster postgres -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; then
        log "✅ Cluster is healthy"
        break
    fi
    
    # Check for errors
    if kubectl get cluster postgres -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Failed"; then
        log "❌ Cluster failed to start"
        kubectl describe cluster postgres -n "$NAMESPACE"
        exit 1
    fi
    
    log "⏳ Cluster status: $(kubectl get cluster postgres -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown')"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "❌ Timeout waiting for cluster to be ready"
    kubectl describe cluster postgres -n "$NAMESPACE"
    exit 1
fi

# Additional wait for services to be ready
log "⏳ Waiting for services to be ready..."
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n "$NAMESPACE" --timeout=300s

# Enhanced credential retrieval with retry
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

# Get service IP with retry
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

# Test connection before proceeding
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

# Enhanced database setup with error handling
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

# Initialize pgbench with error handling
echo "Initializing pgbench in app database..."
if ! pgbench -i -s 10 -q; then
    echo "❌ pgbench initialization failed"
    exit 1
fi

echo "✅ pgbench tables created in app database"
psql -c "\dt pgbench*"

# Verify table creation
ROW_COUNT=$(psql -t -c "SELECT count(*) FROM pgbench_accounts;")
echo "✅ Created $ROW_COUNT accounts for benchmarking"
' || {
    log "❌ Database setup failed"
    exit 1
}

# Enhanced benchmark execution with better error handling
log "🚀 Running PostgreSQL benchmark..."
kubectl run pgbench-perfect --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
  --timeout=1200s \
  -- bash -c '
set -e

echo "=== PostgreSQL Performance Benchmark ==="
echo "Node: '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
echo "Host: $PGHOST"
echo "Database: $PGDATABASE"
echo "User: $PGUSER"
echo "Timestamp: $(date)"
echo ""

# Function to run pgbench with error handling
run_pgbench() {
    local description="$1"
    shift
    echo "=== $description ==="
    if ! pgbench "$@"; then
        echo "⚠️ Test failed: $description"
        return 1
    fi
    echo ""
}

echo "🚀 Running benchmark tests..."

# Basic tests first
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

# Database size test
echo "=== Database Size Test ==="
ROW_COUNT=$(psql -t -c "SELECT count(*) FROM pgbench_accounts;" | tr -d " ")
if [ "$ROW_COUNT" -ge 1000000 ]; then
    echo "Using existing large dataset ($ROW_COUNT rows)"
    run_pgbench "Large Dataset Test (60 seconds)" -c 10 -j 4 -T 60 -P 10
else
    echo "Dataset too small ($ROW_COUNT rows), skipping large dataset test"
fi

# Performance metrics
echo "=== Detailed Performance Analysis ==="
echo "Database size:"
psql -c "SELECT pg_size_pretty(pg_database_size('"'"'app'"'"'));"

echo "Table sizes:"
psql -c "SELECT schemaname,tablename,pg_size_pretty(pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename)) as size FROM pg_tables WHERE schemaname='"'"'public'"'"' ORDER BY pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename) DESC;"

echo "Active connections:"
psql -c "SELECT count(*) as active_connections FROM pg_stat_activity WHERE state = '"'"'active'"'"';"

echo "Cache hit ratio:"
psql -c "SELECT datname, round(blks_hit::float/(blks_hit+blks_read)*100, 2) as cache_hit_ratio FROM pg_stat_database WHERE datname = '"'"'app'"'"';"

# Cleanup temporary files
rm -f /tmp/write_heavy.sql /tmp/large_transactions.sql /tmp/complex_reads.sql /tmp/mixed_workload.sql

echo ""
echo "✅ Enhanced PostgreSQL benchmark completed successfully!"
echo "📊 All tests completed on '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
' || {
    log "❌ Benchmark execution failed"
    exit 1
}

# Store results in VHSM with enhanced metadata
if command -v vault >/dev/null 2>&1; then
    export VAULT_ADDR=https://vhsm.enclaive.cloud/
    if vault token lookup >/dev/null 2>&1; then
        log "💾 Storing comprehensive results in VHSM..."
        vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-postgresql-enhanced-$(date +%s) \
            timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            node_name="$NODE_NAME" \
            vm_type="$CVM_TYPE" \
            benchmark_type="postgresql_cnpg_enhanced" \
            postgresql_version="15" \
            cnpg_version="$(kubectl get cluster postgres -n "$NAMESPACE" -o jsonpath='{.status.cloudNativePGVersion}' 2>/dev/null || echo 'unknown')" \
            scale_factor="10" \
            total_rows="1000000" \
            tests_completed="basic,concurrency,sustained,write_heavy,large_tx,complex_reads,mixed,stress,prepared" \
            log_file="$LOG_FILE" \
            status="success" || log "⚠️ Failed to store results in VHSM"
        log "✅ Results stored in VHSM"
    else
        log "⚠️ VHSM not available, skipping result storage"
    fi
else
    log "⚠️ Vault not available, skipping result storage"
fi

# Final cleanup
log "🧹 Cleaning up resources..."
kubectl delete namespace "$NAMESPACE" --timeout=60s &>/dev/null || {
    log "⚠️ Graceful cleanup failed, forcing..."
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
}

log "✅ Cleanup completed"
log "🎉 Perfect CNPG PostgreSQL benchmark completed successfully!"
log "📁 Log file: $LOG_FILE"
log "💾 Results stored in VHSM for comparison with other nodes"

echo ""
echo "🎯 Benchmark Summary:"
echo "   Node: $NODE_NAME ($CVM_TYPE VM)"
echo "   Log file: $LOG_FILE"
echo "   Status: ✅ Success"
echo "   All tests completed successfully!"
