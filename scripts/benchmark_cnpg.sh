#!/bin/bash
set -e

# =============================================================================
# CNPG PostgreSQL Benchmark for Existing Cluster
# Uses your existing CNPG setup or creates a dedicated benchmark cluster
# =============================================================================

RESULTS_DIR="benchmark-results-$(date +%Y%m%d-%H%M%S)"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING: $1${NC}"; }
error() { echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}"; }

NODE_NAME=$(hostname)
CVM_TYPE="regular"
if dmesg | grep -qi "Memory Encryption"; then
    CVM_TYPE="confidential"
fi

mkdir -p "$RESULTS_DIR"

# =============================================================================
# CNPG PostgreSQL Benchmark
# =============================================================================

run_cnpg_benchmark() {
    log "🐘 Running CNPG PostgreSQL benchmark..."
    
    # Check if kubectl is available
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl not found"
        return 1
    fi
    
    # Always create a dedicated benchmark cluster
    log "   Creating dedicated benchmark cluster..."
    CLUSTER_NAME="benchmark-postgres"
    CLUSTER_NAMESPACE="benchmark"
    
    # Create namespace
    kubectl create namespace benchmark --dry-run=client -o yaml | kubectl apply -f -
    
    # Create optimized benchmark cluster
    cat << EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: benchmark-postgres
  namespace: benchmark
spec:
  instances: 1
  
  postgresql:
    parameters:
      # Optimized for benchmarking
      max_connections: "200"
      shared_buffers: "256MB"
      effective_cache_size: "768MB"
      maintenance_work_mem: "64MB"
      checkpoint_completion_target: "0.9"
      wal_buffers: "16MB"
      default_statistics_target: "100"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
      work_mem: "4MB"
      min_wal_size: "1GB"
      max_wal_size: "4GB"
      # Reduce fsync for benchmarking (not for production!)
      synchronous_commit: "off"
  
  bootstrap:
    initdb:
      database: benchmark
      owner: benchmark
      secret:
        name: benchmark-postgres-credentials
      options:
        - "--data-checksums"
        - "--encoding=UTF8"
        - "--locale=en_US.UTF-8"
  
  storage:
    storageClass: openebs-hostpath
    size: 5Gi
    
  resources:
    requests:
      memory: "512Mi"
      cpu: "500m"
    limits:
      memory: "1Gi"
      cpu: "1000m"
---
apiVersion: v1
kind: Secret
metadata:
  name: benchmark-postgres-credentials
  namespace: benchmark
type: kubernetes.io/basic-auth
data:
  username: $(echo -n benchmark | base64)
  password: $(echo -n "benchmark123" | base64)
EOF
    
    # Wait for cluster to be ready
    log "   Waiting for benchmark cluster to be ready (up to 5 minutes)..."
    if ! kubectl wait --for=condition=Ready cluster/benchmark-postgres -n benchmark --timeout=300s; then
        error "Benchmark cluster failed to become ready"
        return 1
    fi
    
    log "   ✅ Benchmark cluster is ready!"
    
    # Set connection details for our new cluster
    POSTGRES_SERVICE="benchmark-postgres-rw"
    DB_USER="benchmark"
    DB_PASSWORD="benchmark123"
    DB_DATABASE="benchmark"
    
    log "   Using service: $POSTGRES_SERVICE"
    log "   Database: $DB_DATABASE"
    
    # Run pgbench benchmark
    cat << EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: pgbench-cnpg-$(date +%s)
  namespace: $CLUSTER_NAMESPACE
spec:
  activeDeadlineSeconds: 300
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: pgbench
        image: postgres:15-alpine
        env:
        - name: PGHOST
          value: "$POSTGRES_SERVICE"
        - name: PGPORT
          value: "5432"
        - name: PGDATABASE
          value: "$DB_DATABASE"
        - name: PGUSER
          value: "$DB_USER"
        - name: PGPASSWORD
          value: "$DB_PASSWORD"
        command:
        - /bin/sh
        - -c
        - |
          echo "=== CNPG PostgreSQL Comprehensive Benchmark ==="
          echo "Cluster: $CLUSTER_NAME"
          echo "Host: \$PGHOST"
          echo "Database: \$PGDATABASE"
          echo "User: \$PGUSER"
          echo "Node: $NODE_NAME ($CVM_TYPE VM)"
          echo ""
          
          # Wait for connection
          echo "Waiting for PostgreSQL connection..."
          for i in \$(seq 1 30); do
            if pg_isready -h \$PGHOST -p \$PGPORT -U \$PGUSER; then
              echo "✅ PostgreSQL is ready!"
              break
            fi
            echo "Waiting... (\$i/30)"
            sleep 2
          done
          
          # Test connection and show database info
          echo ""
          echo "📊 Database Information:"
          psql -c "SELECT version();" || exit 1
          psql -c "SHOW shared_buffers;"
          psql -c "SHOW work_mem;"
          psql -c "SHOW effective_cache_size;"
          
          echo ""
          echo "🔧 Initializing pgbench with comprehensive test data..."
          echo "   Scale factor 20 = ~2M rows in pgbench_accounts table"
          echo "   This creates realistic dataset for testing"
          
          # Initialize pgbench with larger scale for more realistic testing
          if pgbench -i -s 20 --foreign-keys --quiet; then
            echo "✅ pgbench initialized successfully with scale factor 20"
          else
            echo "❌ pgbench initialization failed, trying smaller scale..."
            if pgbench -i -s 10 --quiet; then
              echo "✅ pgbench initialized with scale factor 10"
            else
              echo "❌ pgbench initialization failed completely"
              exit 1
            fi
          fi
          
          # Show created tables and data sizes
          echo ""
          echo "📈 Generated Test Data:"
          psql -c "\\dt+ pgbench*"
          psql -c "SELECT 'pgbench_accounts' as table, count(*) as rows FROM pgbench_accounts 
                   UNION ALL SELECT 'pgbench_branches', count(*) FROM pgbench_branches 
                   UNION ALL SELECT 'pgbench_tellers', count(*) FROM pgbench_tellers 
                   UNION ALL SELECT 'pgbench_history', count(*) FROM pgbench_history;"
          
          echo ""
          echo "🚀 Running comprehensive pgbench benchmarks..."
          echo "   Each test runs for 60 seconds for accurate measurements"
          echo ""
          
          # Test 1: Single client baseline (measures raw database performance)
          echo "=== Test 1: Single Client Baseline (60 seconds) ==="
          echo "Purpose: Measure raw database performance without concurrency overhead"
          pgbench -c 1 -j 1 -T 60 -P 10 -r --aggregate-interval=10
          
          echo ""
          echo "=== Test 2: Low Concurrency (60 seconds) ==="
          echo "Purpose: Measure performance with moderate concurrent load"
          pgbench -c 5 -j 2 -T 60 -P 10 -r --aggregate-interval=10
          
          echo ""
          echo "=== Test 3: Medium Concurrency (60 seconds) ==="
          echo "Purpose: Measure performance under typical production load"
          pgbench -c 10 -j 4 -T 60 -P 10 -r --aggregate-interval=10
          
          echo ""
          echo "=== Test 4: High Concurrency (60 seconds) ==="
          echo "Purpose: Measure performance under high concurrent load"
          pgbench -c 20 -j 8 -T 60 -P 10 -r --aggregate-interval=10
          
          echo ""
          echo "=== Test 5: Read-Only Workload (60 seconds) ==="
          echo "Purpose: Measure SELECT-only performance (no locks/writes)"
          pgbench -c 10 -j 4 -T 60 -S -P 10 -r --aggregate-interval=10
          
          echo ""
          echo "=== Custom Query Performance Tests ==="
          echo "Purpose: Test specific query patterns and complex operations"
          
          echo ""
          echo "Test: Simple COUNT query"
          time psql -c "SELECT COUNT(*) FROM pgbench_accounts;" 2>/dev/null || echo "Query failed"
          
          echo ""
          echo "Test: JOIN with aggregation"
          time psql -c "SELECT b.bid, b.bbalance, COUNT(a.aid) as account_count, AVG(a.abalance) as avg_balance 
                        FROM pgbench_branches b 
                        JOIN pgbench_accounts a ON b.bid = a.bid 
                        GROUP BY b.bid, b.bbalance 
                        ORDER BY b.bid;" 2>/dev/null || echo "Query failed"
          
          echo ""
          echo "Test: Complex analytical query"
          time psql -c "SELECT 
                          bid,
                          COUNT(*) as total_accounts,
                          AVG(abalance) as avg_balance,
                          MIN(abalance) as min_balance,
                          MAX(abalance) as max_balance,
                          STDDEV(abalance) as stddev_balance,
                          COUNT(CASE WHEN abalance > 0 THEN 1 END) as positive_accounts,
                          COUNT(CASE WHEN abalance < 0 THEN 1 END) as negative_accounts
                        FROM pgbench_accounts 
                        GROUP BY bid 
                        ORDER BY avg_balance DESC;" 2>/dev/null || echo "Query failed"
          
          echo ""
          echo "Test: Index performance"
          time psql -c "SELECT * FROM pgbench_accounts WHERE aid BETWEEN 100000 AND 100100 ORDER BY abalance;" 2>/dev/null || echo "Query failed"
          
          echo ""
          echo "=== Database Statistics After Benchmark ==="
          psql -c "SELECT schemaname, tablename, n_tup_ins, n_tup_upd, n_tup_del, n_live_tup, n_dead_tup 
                   FROM pg_stat_user_tables 
                   WHERE tablename LIKE 'pgbench%';"
          
          echo ""
          echo "🎉 CNPG PostgreSQL comprehensive benchmark completed!"
          echo "   Tested: Single/Multi-client, Read-only, Complex queries"
          echo "   Data: Scale factor with realistic dataset size"
EOF

    JOB_NAME="pgbench-cnpg-$(date +%s)"
    
    # Wait for completion
    log "   Running pgbench tests (up to 5 minutes)..."
    if kubectl wait --for=condition=complete job/$JOB_NAME -n "$CLUSTER_NAMESPACE" --timeout=300s; then
        
        # Get results
        PGBENCH_OUTPUT=$(kubectl logs job/$JOB_NAME -n "$CLUSTER_NAMESPACE")
        
        # Parse comprehensive results
        TPS_1=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 1:" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
        TPS_5=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 2:" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
        TPS_10=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 3:" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
        TPS_20=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 4:" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
        TPS_READONLY=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 5:" | grep "excluding connections establishing" | awk '{print $1}' | head -1 || echo "0")
        
        # Get latency data
        LATENCY_1=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 1:" | grep "latency average" | awk '{print $4}' | head -1 || echo "0")
        LATENCY_5=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 2:" | grep "latency average" | awk '{print $4}' | head -1 || echo "0")
        LATENCY_10=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 3:" | grep "latency average" | awk '{print $4}' | head -1 || echo "0")
        LATENCY_20=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 4:" | grep "latency average" | awk '{print $4}' | head -1 || echo "0")
        LATENCY_READONLY=$(echo "$PGBENCH_OUTPUT" | grep -A20 "Test 5:" | grep "latency average" | awk '{print $4}' | head -1 || echo "0")
        
        # Extract scale factor used
        SCALE_FACTOR=$(echo "$PGBENCH_OUTPUT" | grep "scale factor" | awk '{print $NF}' | head -1 || echo "20")
        
        log "   ✅ CNPG Comprehensive Benchmark Results:"
        log "      Scale Factor: $SCALE_FACTOR ($(echo "$SCALE_FACTOR * 100000" | bc) accounts)"
        log "      1 client: ${TPS_1} TPS, ${LATENCY_1}ms latency"
        log "      5 clients: ${TPS_5} TPS, ${LATENCY_5}ms latency"
        log "      10 clients: ${TPS_10} TPS, ${LATENCY_10}ms latency"
        log "      20 clients: ${TPS_20} TPS, ${LATENCY_20}ms latency"
        log "      Read-only: ${TPS_READONLY} TPS, ${LATENCY_READONLY}ms latency"
        
        # Save results
        cat > "$RESULTS_DIR/cnpg_benchmark.json" << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "node_name": "$NODE_NAME",
    "cvm_type": "$CVM_TYPE",
    "cluster_info": {
        "name": "$CLUSTER_NAME",
        "namespace": "$CLUSTER_NAMESPACE",
        "service": "$POSTGRES_SERVICE",
        "created_for_benchmark": true,
        "scale_factor": $SCALE_FACTOR,
        "total_accounts": $(echo "$SCALE_FACTOR * 100000" | bc),
        "postgresql_version": "15",
        "storage_class": "openebs-hostpath",
        "storage_size": "5Gi"
    },
    "pgbench_results": [
        {
            "test_name": "single_client_baseline",
            "clients": 1,
            "jobs": 1,
            "duration_seconds": 60,
            "tps": $TPS_1,
            "latency_ms": $LATENCY_1,
            "purpose": "Raw database performance without concurrency"
        },
        {
            "test_name": "low_concurrency",
            "clients": 5,
            "jobs": 2,
            "duration_seconds": 60,
            "tps": $TPS_5,
            "latency_ms": $LATENCY_5,
            "purpose": "Moderate concurrent load"
        },
        {
            "test_name": "medium_concurrency",
            "clients": 10,
            "jobs": 4,
            "duration_seconds": 60,
            "tps": $TPS_10,
            "latency_ms": $LATENCY_10,
            "purpose": "Typical production load"
        },
        {
            "test_name": "high_concurrency",
            "clients": 20,
            "jobs": 8,
            "duration_seconds": 60,
            "tps": $TPS_20,
            "latency_ms": $LATENCY_20,
            "purpose": "High concurrent load stress test"
        },
        {
            "test_name": "read_only_workload",
            "clients": 10,
            "jobs": 4,
            "duration_seconds": 60,
            "tps": $TPS_READONLY,
            "latency_ms": $LATENCY_READONLY,
            "purpose": "SELECT-only performance (no locks/writes)",
            "workload_type": "read_only"
        }
    ],
    "performance_analysis": {
        "baseline_tps": $TPS_1,
        "peak_tps": $(echo "$TPS_1 $TPS_5 $TPS_10 $TPS_20" | tr ' ' '\n' | sort -n | tail -1),
        "read_vs_write_ratio": $(echo "scale=2; $TPS_READONLY / $TPS_10" | bc 2>/dev/null || echo "0"),
        "concurrency_scaling": {
            "5_clients_vs_1": $(echo "scale=2; $TPS_5 / $TPS_1" | bc 2>/dev/null || echo "0"),
            "10_clients_vs_1": $(echo "scale=2; $TPS_10 / $TPS_1" | bc 2>/dev/null || echo "0"),
            "20_clients_vs_1": $(echo "scale=2; $TPS_20 / $TPS_1" | bc 2>/dev/null || echo "0")
        }
    },
    "full_output": $(echo "$PGBENCH_OUTPUT" | jq -R -s .)
}
EOF
        
        # Save detailed log
        echo "$PGBENCH_OUTPUT" > "$RESULTS_DIR/pgbench_full_output.log"
        
        BENCHMARK_STATUS="success"
        
    else
        error "PostgreSQL benchmark timed out"
        BENCHMARK_STATUS="timeout"
        kubectl logs job/$JOB_NAME -n "$CLUSTER_NAMESPACE" > "$RESULTS_DIR/pgbench_error.log" 2>&1 || true
    fi
    
    # Cleanup
    kubectl delete job $JOB_NAME -n "$CLUSTER_NAMESPACE" --ignore-not-found=true
    
    # Always cleanup benchmark cluster when done
    log "   Cleaning up benchmark cluster..."
    kubectl delete cluster benchmark-postgres -n benchmark --ignore-not-found=true --wait=false
    kubectl delete namespace benchmark --ignore-not-found=true --wait=false
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo "🚀 CNPG PostgreSQL Benchmark for $NODE_NAME ($CVM_TYPE VM)"
    echo "=========================================================="
    
    run_cnpg_benchmark
    
    if [ -f "$RESULTS_DIR/cnpg_benchmark.json" ]; then
        echo ""
        log "🎉 Benchmark completed successfully!"
        log "📁 Results: $RESULTS_DIR/cnpg_benchmark.json"
        log "📋 Full output: $RESULTS_DIR/pgbench_full_output.log"
        
        echo ""
        echo "📊 Comprehensive Benchmark Summary:"
        jq -r '
        "🎯 Scale Factor: " + (.cluster_info.scale_factor|tostring) + " (" + (.cluster_info.total_accounts|tostring) + " accounts)",
        "",
        "📈 TPS Results:",
        (.pgbench_results[] | "  " + .test_name + ": " + (.tps|tostring) + " TPS (" + (.latency_ms|tostring) + "ms latency)"),
        "",
        "🔍 Performance Analysis:",
        "  Peak TPS: " + (.performance_analysis.peak_tps|tostring),
        "  Read vs Write ratio: " + (.performance_analysis.read_vs_write_ratio|tostring) + "x",
        "  5-client scaling: " + (.performance_analysis.concurrency_scaling."5_clients_vs_1"|tostring) + "x",
        "  10-client scaling: " + (.performance_analysis.concurrency_scaling."10_clients_vs_1"|tostring) + "x",
        "  20-client scaling: " + (.performance_analysis.concurrency_scaling."20_clients_vs_1"|tostring) + "x"
        ' "$RESULTS_DIR/cnpg_benchmark.json"
    else
        error "Benchmark failed - check logs in $RESULTS_DIR/"
    fi
}

main "$@"
