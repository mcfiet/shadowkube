#!/bin/bash
set -e

# Fixed Standalone CNPG Benchmark - Works on both cVM and regular VM
NODE_NAME=$(hostname)

# Auto-detect VM type (handle dmesg permission issues)
detect_vm_type() {
    if command -v dmesg >/dev/null 2>&1; then
        if dmesg 2>/dev/null | grep -qi "Memory Encryption Features active: AMD SEV"; then
            echo "confidential"
            return
        elif dmesg 2>/dev/null | grep -qi "AMD Memory Encryption"; then
            echo "confidential"
            return
        fi
    fi
    
    # Fallback detection methods
    if [ -f /proc/cpuinfo ] && grep -qi "sev\|sgx\|txt" /proc/cpuinfo; then
        echo "confidential"
    elif [ -d /sys/kernel/security ] && find /sys/kernel/security -name "*sev*" 2>/dev/null | grep -q .; then
        echo "confidential"
    elif [ -f /dev/sgx_enclave ] || [ -f /dev/sev ]; then
        echo "confidential"
    else
        echo "regular"
    fi
}

CVM_TYPE=$(detect_vm_type)
NAMESPACE="benchmark-perfect"
LOG_FILE="/tmp/benchmark-${NODE_NAME}-$(date +%Y%m%d-%H%M%S).log"
RESULTS_FILE="/tmp/benchmark-results-${NODE_NAME}-$(date +%Y%m%d-%H%M%S).json"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Enhanced error handling with debugging
cleanup_on_error() {
    log "❌ Error occurred, performing detailed debugging..."
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    log "🧹 Emergency cleanup completed"
    exit 1
}

# Set up error trap
trap cleanup_on_error ERR

log "🚀 Fixed CNPG Benchmark - $NODE_NAME ($CVM_TYPE VM)"

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
kubectl create namespace "$NAMESPACE"
log "✅ Namespace created successfully"

# Create PostgreSQL cluster with FIXED configuration for app user
log "🗄️ Creating PostgreSQL cluster with app user..."
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
  
  # FIXED: Properly configure app database and user
  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: postgres-app
---
# Create the app user secret manually to ensure it exists
apiVersion: v1
kind: Secret
metadata:
  name: postgres-app
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
data:
  username: $(echo -n 'app' | base64)
  password: $(openssl rand -base64 32 | base64 -w 0)
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

# Wait for pods to be ready
log "⏳ Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n "$NAMESPACE" --timeout=300s

# Get credentials - try multiple secret names
log "🔑 Retrieving credentials..."
POSTGRES_PASSWORD=""
POSTGRES_USER=""

# Try different secret naming patterns
for secret_name in postgres-app postgres-superuser postgres-owner; do
    if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
        log "Found secret: $secret_name"
        
        # Try different field names
        for field in password POSTGRES_PASSWORD; do
            if TEMP_PASSWORD=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null | base64 -d 2>/dev/null); then
                if [ -n "$TEMP_PASSWORD" ]; then
                    POSTGRES_PASSWORD="$TEMP_PASSWORD"
                    break
                fi
            fi
        done
        
        # Try different user field names
        for field in username user POSTGRES_USER owner; do
            if TEMP_USER=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath="{.data.$field}" 2>/dev/null | base64 -d 2>/dev/null); then
                if [ -n "$TEMP_USER" ]; then
                    POSTGRES_USER="$TEMP_USER"
                fi
            fi
        done
        
        if [ -n "$POSTGRES_PASSWORD" ]; then
            break
        fi
    fi
done

# Fallback to superuser if app user not found
if [ -z "$POSTGRES_PASSWORD" ]; then
    log "⚠️ App credentials not found, trying superuser..."
    if kubectl get secret postgres-superuser -n "$NAMESPACE" &>/dev/null; then
        POSTGRES_PASSWORD=$(kubectl get secret postgres-superuser -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
        POSTGRES_USER="postgres"
        POSTGRES_DATABASE="postgres"
    fi
fi

if [ -z "$POSTGRES_PASSWORD" ]; then
    log "❌ Failed to retrieve PostgreSQL password"
    log "📋 Available secrets:"
    kubectl get secrets -n "$NAMESPACE"
    exit 1
fi

# Set defaults
POSTGRES_USER=${POSTGRES_USER:-"app"}
POSTGRES_DATABASE=${POSTGRES_DATABASE:-"app"}

log "✅ Retrieved PostgreSQL credentials (user: $POSTGRES_USER, password length: ${#POSTGRES_PASSWORD})"

# Get service IP
PG_IP=$(kubectl get svc postgres-rw -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
log "✅ PostgreSQL service IP: $PG_IP"

# Test connection
log "🔌 Testing database connection..."
kubectl run connection-test --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
    --env="PGPASSWORD=$POSTGRES_PASSWORD" \
    --env="PGHOST=$PG_IP" \
    --env="PGUSER=$POSTGRES_USER" \
    --env="PGDATABASE=$POSTGRES_DATABASE" \
    --timeout=60s \
    -- psql -c "SELECT current_database(), current_user, version();" || {
    log "❌ Connection test failed"
    exit 1
}

log "✅ Database connection successful"

# Setup database
log "🗄️ Setting up benchmark database..."
kubectl run setup-db --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=$POSTGRES_USER" \
  --env="PGDATABASE=$POSTGRES_DATABASE" \
  --timeout=300s \
  -- bash -c '
set -e
echo "Connected to database: $PGDATABASE as user: $PGUSER"

# Create app database and user if using superuser
if [ "$PGUSER" = "postgres" ]; then
    echo "Creating app database and user..."
    psql -c "CREATE DATABASE app;" 2>/dev/null || echo "Database app already exists"
    psql -c "CREATE USER app WITH ENCRYPTED PASSWORD '"'"'apppass123'"'"';" 2>/dev/null || echo "User app already exists"
    psql -c "GRANT ALL PRIVILEGES ON DATABASE app TO app;"
    psql -c "ALTER USER app CREATEDB;"
    
    # Switch to app database
    export PGDATABASE=app
    export PGUSER=app
    export PGPASSWORD=apppass123
fi

echo "Initializing pgbench in database: $PGDATABASE"
pgbench -i -s 10 -q

echo "✅ pgbench tables created"
psql -c "\dt pgbench*"

ROW_COUNT=$(psql -t -c "SELECT count(*) FROM pgbench_accounts;" | tr -d " ")
echo "✅ Created $ROW_COUNT accounts for benchmarking"
' || {
    log "❌ Database setup failed"
    exit 1
}

# Update credentials if we created app user
if [ "$POSTGRES_USER" = "postgres" ]; then
    POSTGRES_USER="app"
    POSTGRES_PASSWORD="apppass123"
    POSTGRES_DATABASE="app"
fi

# Run comprehensive benchmark
log "🚀 Running comprehensive PostgreSQL benchmark..."
kubectl run pgbench-complete --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=$POSTGRES_USER" \
  --env="PGDATABASE=$POSTGRES_DATABASE" \
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

# FIXED Write-heavy test - avoid primary key conflicts
echo "=== Write-Heavy: Fixed Custom Script (60 seconds) ==="
cat > /tmp/write_heavy_fixed.sql << '"'"'EOF'"'"'
-- Fixed write-heavy test that avoids primary key conflicts
UPDATE pgbench_accounts SET abalance = abalance + 100 WHERE aid = (random() * 100000)::int;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES 
    ((random() * 10)::int + 1, (random() * 10)::int + 1, (random() * 100000)::int + 1, (random() * 1000)::int, CURRENT_TIMESTAMP);
UPDATE pgbench_tellers SET tbalance = tbalance + (random() * 100)::int WHERE tid = (random() * 10)::int + 1;
EOF
run_pgbench "Write-Heavy: Fixed Custom Script (60 seconds)" -c 10 -j 4 -T 60 -f /tmp/write_heavy_fixed.sql -P 10

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
WHERE a.aid = (random() * 100000)::int + 1;
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
psql -c "SELECT pg_size_pretty(pg_database_size(current_database()));"

echo "Table sizes:"
psql -c "SELECT schemaname,tablename,pg_size_pretty(pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename)) as size FROM pg_tables WHERE schemaname='"'"'public'"'"' ORDER BY pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename) DESC;"

echo "Cache hit ratio:"
psql -c "SELECT datname, round(blks_hit::float/(blks_hit+blks_read)*100, 2) as cache_hit_ratio FROM pg_stat_database WHERE datname = current_database();"

# Cleanup temporary files
rm -f /tmp/write_heavy_fixed.sql /tmp/large_transactions.sql /tmp/complex_reads.sql /tmp/mixed_workload.sql

echo ""
echo "✅ Complete PostgreSQL benchmark finished successfully!"
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

log "✅ Fixed benchmark completed successfully!"
log "📁 Results saved to:"
log "   Log file: $LOG_FILE"

echo ""
echo "🎯 Benchmark Summary:"
echo "   Node: $NODE_NAME ($CVM_TYPE VM)"
echo "   Log file: $LOG_FILE"
echo "   Status: ✅ Success"

# Extract key metrics for quick comparison
echo ""
echo "📊 Quick Results Summary:"
echo "----------------------------------------"
grep -E "📊 RESULT:" "$LOG_FILE" | head -10 || echo "No summary data found"

echo ""
echo "🔬 For your research paper:"
echo "   - All TPS values extracted and logged"
echo "   - Fixed write-heavy test (no more primary key conflicts)"
echo "   - Works on both cVM and regular VM"
echo "   - Ready for performance comparison analysis"
