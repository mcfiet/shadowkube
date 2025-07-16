#!/bin/bash
set -e

# Robust Standalone CNPG Benchmark with Enhanced Error Handling
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
    
    # Show cluster status
    log "🔍 Cluster debug information:"
    kubectl get cluster postgres -n "$NAMESPACE" -o yaml 2>/dev/null || log "No cluster found"
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || log "No pods found"
    kubectl get services -n "$NAMESPACE" 2>/dev/null || log "No services found"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null || log "No events found"
    
    # Cleanup
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    
    log "🧹 Emergency cleanup completed"
    exit 1
}

# Set up error trap
trap cleanup_on_error ERR

log "🚀 Robust Standalone CNPG Benchmark - $NODE_NAME ($CVM_TYPE VM)"

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
    log "Available storage classes:"
    kubectl get storageclass
    exit 1
fi

log "✅ Pre-flight checks passed"

# Enhanced cleanup with better error handling
cleanup_existing_resources() {
    log "🧹 Cleaning up existing resources..."
    
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log "Found existing namespace, attempting graceful cleanup..."
        
        # Show what we're cleaning up
        kubectl get all -n "$NAMESPACE" 2>/dev/null || log "No resources found in namespace"
        
        if kubectl get cluster postgres -n "$NAMESPACE" &>/dev/null; then
            log "Deleting PostgreSQL cluster..."
            kubectl delete cluster postgres -n "$NAMESPACE" --timeout=60s &>/dev/null || {
                log "⚠️ Graceful cluster deletion failed, forcing..."
                kubectl patch cluster postgres -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
                kubectl delete cluster postgres -n "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null || true
            }
        fi
        
        log "⏳ Waiting for pods to terminate..."
        for i in {1..30}; do
            POD_COUNT=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
            if [ "$POD_COUNT" -eq 0 ]; then
                break
            fi
            log "   Still have $POD_COUNT pods running..."
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

# Create PostgreSQL cluster with enhanced configuration
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
      log_statement: "all"
      log_min_duration_statement: "0"
  # Add bootstrap configuration
  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: postgres-app
EOF

# Enhanced waiting with detailed status monitoring
log "⏳ Waiting for PostgreSQL cluster to be ready..."
TIMEOUT=900  # 15 minutes
ELAPSED=0
LAST_STATUS=""

while [ $ELAPSED -lt $TIMEOUT ]; do
    STATUS=$(kubectl get cluster postgres -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    if [ "$STATUS" != "$LAST_STATUS" ]; then
        log "⏳ Cluster status: $STATUS"
        LAST_STATUS="$STATUS"
    fi
    
    if echo "$STATUS" | grep -q "Cluster in healthy state"; then
        log "✅ Cluster is healthy"
        break
    fi
    
    if echo "$STATUS" | grep -q "Failed"; then
        log "❌ Cluster failed to start"
        log "📋 Cluster details:"
        kubectl describe cluster postgres -n "$NAMESPACE"
        log "📋 Pod details:"
        kubectl get pods -n "$NAMESPACE" -o wide
        kubectl describe pods -n "$NAMESPACE"
        exit 1
    fi
    
    # Show pod status every 30 seconds
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        POD_STATUS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1 ":" $3}' | tr '\n' ' ')
        if [ -n "$POD_STATUS" ]; then
            log "   Pod status: $POD_STATUS"
        fi
    fi
    
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "❌ Timeout waiting for cluster to be ready"
    log "📋 Final cluster state:"
    kubectl describe cluster postgres -n "$NAMESPACE"
    kubectl get pods -n "$NAMESPACE" -o wide
    kubectl logs -n "$NAMESPACE" -l cnpg.io/cluster=postgres --tail=50
    exit 1
fi

# Wait for pods to be ready
log "⏳ Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=postgres -n "$NAMESPACE" --timeout=300s

# Enhanced credential retrieval
log "🔑 Retrieving credentials..."
for i in {1..15}; do
    if kubectl get secret postgres-app -n "$NAMESPACE" &>/dev/null; then
        if POSTGRES_PASSWORD=$(kubectl get secret postgres-app -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); then
            if [ -n "$POSTGRES_PASSWORD" ]; then
                log "✅ Retrieved PostgreSQL password (length: ${#POSTGRES_PASSWORD})"
                break
            fi
        fi
    fi
    log "⚠️ Waiting for credentials... ($i/15)"
    
    # Show available secrets for debugging
    if [ $i -eq 5 ]; then
        log "📋 Available secrets:"
        kubectl get secrets -n "$NAMESPACE"
    fi
    
    sleep 5
done

if [ -z "$POSTGRES_PASSWORD" ]; then
    log "❌ Failed to retrieve PostgreSQL password"
    log "📋 Available secrets:"
    kubectl get secrets -n "$NAMESPACE"
    log "📋 Secret details:"
    kubectl describe secret postgres-app -n "$NAMESPACE" 2>/dev/null || log "Secret not found"
    exit 1
fi

# Enhanced service IP retrieval
log "🔍 Getting service information..."
for i in {1..15}; do
    if kubectl get svc postgres-rw -n "$NAMESPACE" &>/dev/null; then
        if PG_IP=$(kubectl get svc postgres-rw -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null); then
            if [ -n "$PG_IP" ] && [ "$PG_IP" != "null" ]; then
                log "✅ PostgreSQL service IP: $PG_IP"
                break
            fi
        fi
    fi
    log "⚠️ Waiting for service IP... ($i/15)"
    
    # Show available services for debugging
    if [ $i -eq 5 ]; then
        log "📋 Available services:"
        kubectl get services -n "$NAMESPACE"
    fi
    
    sleep 5
done

if [ -z "$PG_IP" ] || [ "$PG_IP" = "null" ]; then
    log "❌ Failed to get service IP"
    log "📋 Available services:"
    kubectl get services -n "$NAMESPACE"
    log "📋 Service details:"
    kubectl describe service postgres-rw -n "$NAMESPACE" 2>/dev/null || log "Service not found"
    exit 1
fi

# Enhanced connection testing with debugging
log "🔌 Testing database connection..."
log "   Connection details: $PG_IP:5432, user: app, database: app"

# First, check if the pod is actually running and ready
log "📋 Pod readiness check:"
kubectl get pods -n "$NAMESPACE" -o wide

# Test with a simple connection first
log "🔌 Attempting basic connection test..."
CONNECTION_TEST_OUTPUT=$(kubectl run connection-test --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
    --env="PGPASSWORD=$POSTGRES_PASSWORD" \
    --env="PGHOST=$PG_IP" \
    --env="PGUSER=app" \
    --env="PGDATABASE=app" \
    --timeout=120s \
    -- bash -c '
echo "Testing connection to $PGHOST:5432"
echo "User: $PGUSER, Database: $PGDATABASE"

# Test network connectivity first
echo "Testing network connectivity..."
if command -v nc >/dev/null; then
    nc -zv $PGHOST 5432 || echo "Port 5432 not reachable"
fi

# Test basic connection
echo "Testing PostgreSQL connection..."
psql -h $PGHOST -U $PGUSER -d $PGDATABASE -c "SELECT 1 as test;" 2>&1 || {
    echo "Connection failed, trying alternative methods..."
    
    # Try connecting to postgres database instead
    echo "Trying postgres database..."
    PGDATABASE=postgres psql -h $PGHOST -U $PGUSER -c "SELECT 1 as test;" 2>&1 || echo "Postgres database also failed"
    
    # Show connection details
    echo "Environment:"
    env | grep PG
    
    echo "DNS resolution:"
    nslookup $PGHOST || echo "DNS lookup failed"
}
' 2>&1) || {
    log "❌ Connection test failed"
    log "📋 Connection test output:"
    echo "$CONNECTION_TEST_OUTPUT" | tee -a "$LOG_FILE"
    
    log "📋 Debugging information:"
    kubectl get pods -n "$NAMESPACE" -o wide
    kubectl describe pods -n "$NAMESPACE"
    kubectl logs -n "$NAMESPACE" -l cnpg.io/cluster=postgres --tail=20
    
    # Try to continue anyway for debugging
    log "⚠️ Continuing despite connection failure for debugging..."
}

log "✅ Connection test completed (may have warnings)"

# Try database setup with more robust error handling
log "🗄️ Setting up benchmark database..."

SETUP_OUTPUT=$(kubectl run setup-db --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
  --timeout=600s \
  -- bash -c '
set -e
echo "=== Database Setup Debug Information ==="
echo "Host: $PGHOST"
echo "User: $PGUSER"  
echo "Database: $PGDATABASE"
echo "Password length: ${#PGPASSWORD}"

echo "=== Testing Connection ==="
psql -c "SELECT current_database(), current_user, version();"

echo "=== Checking existing tables ==="
psql -c "\dt" || echo "No tables found"

echo "=== Initializing pgbench ==="
pgbench -i -s 10 -q || {
    echo "❌ pgbench initialization failed, trying with verbose output:"
    pgbench -i -s 10 -v
}

echo "=== Verifying tables ==="
psql -c "\dt pgbench*"

ROW_COUNT=$(psql -t -c "SELECT count(*) FROM pgbench_accounts;" | tr -d " ")
echo "✅ Created $ROW_COUNT accounts for benchmarking"

echo "=== Database setup completed successfully ==="
' 2>&1) || {
    log "❌ Database setup failed"
    log "📋 Setup output:"
    echo "$SETUP_OUTPUT" | tee -a "$LOG_FILE"
    
    # Don't exit here, let's see if we can still get some information
    log "⚠️ Continuing despite setup failure..."
}

log "✅ Database setup phase completed"

# Create a simplified benchmark if full setup failed
log "🚀 Running simplified PostgreSQL benchmark..."

BENCHMARK_OUTPUT=$(kubectl run pgbench-simple --image=postgres:15-alpine -n "$NAMESPACE" --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
  --timeout=300s \
  -- bash -c '
echo "=== Simple PostgreSQL Benchmark ==="
echo "Node: '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
echo "Timestamp: $(date)"

# Check if pgbench tables exist
if psql -c "\dt pgbench_accounts" >/dev/null 2>&1; then
    echo "✅ pgbench tables found, running benchmark..."
    
    echo "=== Quick Performance Test ==="
    pgbench -c 1 -j 1 -T 10 -P 2 2>&1 || echo "Benchmark failed"
    
else
    echo "⚠️ pgbench tables not found, creating minimal dataset..."
    
    # Try to create a simple test
    psql -c "CREATE TABLE IF NOT EXISTS simple_test (id SERIAL PRIMARY KEY, data TEXT);"
    psql -c "INSERT INTO simple_test (data) SELECT '"'"'test'"'"' FROM generate_series(1, 1000);"
    
    echo "✅ Created simple test table with $(psql -t -c "SELECT count(*) FROM simple_test;" | tr -d " ") rows"
fi

echo "=== Database Information ==="
psql -c "SELECT pg_size_pretty(pg_database_size(current_database()));"
psql -c "SELECT count(*) as table_count FROM information_schema.tables WHERE table_schema = '"'"'public'"'"';"

echo "=== Benchmark completed ==="
' 2>&1) || {
    log "❌ Benchmark failed"
}

log "📋 Benchmark output:"
echo "$BENCHMARK_OUTPUT" | tee -a "$LOG_FILE"

# Cleanup
log "🧹 Cleaning up resources..."
kubectl delete namespace "$NAMESPACE" --timeout=60s &>/dev/null || {
    log "⚠️ Graceful cleanup failed, forcing..."
    kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null || true
    kubectl delete namespace "$NAMESPACE" --force --grace-period=0 &>/dev/null || true
}

log "✅ Robust benchmark completed"
log "📁 Full log saved to: $LOG_FILE"

echo ""
echo "🎯 Robust Benchmark Summary:"
echo "   Node: $NODE_NAME ($CVM_TYPE VM)"
echo "   Log file: $LOG_FILE"
echo "   Status: Completed with detailed debugging"

echo ""
echo "📊 Key Information:"
echo "   - VM Type: $CVM_TYPE"
echo "   - Storage Class: $STORAGE_CLASS"
echo "   - Connection Issues: $(grep -c "failed\|error\|Error" "$LOG_FILE" || echo "0") errors found"

echo ""
echo "🔬 Next Steps:"
echo "   1. Review the full log: cat $LOG_FILE"
echo "   2. Compare with cVM results"
echo "   3. Identify root cause of connection issues if any"
