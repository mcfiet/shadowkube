#!/bin/bash
set -e

# Enable perf access FIRST
if [ "$EUID" -eq 0 ]; then
    echo 1 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
    echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true
else
    echo "⚠️  Running without root - perf measurements may be limited"
fi

# Install perf if needed
if ! command -v perf >/dev/null 2>&1; then
    echo "📦 Installing perf..."
    if [ -f /etc/suse-release ]; then
        zypper install -y perf 2>/dev/null || true
    fi
fi

export PATH="/var/lib/rancher/rke2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

export PATH="/var/lib/rancher/rke2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
NODE_NAME=$(hostname)

# Simple VM type detection (handle dmesg permission issues)
if dmesg 2>/dev/null | grep -qi "Memory Encryption Features active: AMD SEV" 2>/dev/null; then
    CVM_TYPE="confidential"
elif dmesg 2>/dev/null | grep -qi "AMD Memory Encryption" 2>/dev/null; then
    CVM_TYPE="confidential"
else
    CVM_TYPE="regular"
fi

echo "🚀 Perfect CNPG Benchmark - $NODE_NAME ($CVM_TYPE VM)"

NAMESPACE="benchmark-perfect"

# Cleanup - exactly like your original
if kubectl get namespace $NAMESPACE &>/dev/null; then
  echo "🧹 Vorheriges Cluster und Namespace $NAMESPACE entfernen…"
  kubectl delete cluster postgres -n "$NAMESPACE" \
    --force --grace-period=0 --ignore-not-found || true
  kubectl patch cluster postgres -n $NAMESPACE \
    -p '{"metadata":{"finalizers":[]}}' --type=merge || true
  kubectl delete namespace "$NAMESPACE" \
    --force --grace-period=0 --ignore-not-found || true
  kubectl patch namespace $NAMESPACE \
    -p '{"metadata":{"finalizers":[]}}' --type=merge || true
fi

kubectl create namespace $NAMESPACE

# Create cluster - exactly like your original
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  instances: 3
  storage:
    storageClass: openebs-hostpath
    size: 1Gi
  bootstrap:
    initdb:
      database: app
      owner: app
EOF

echo "⏳ Waiting for PostgreSQL cluster..."
kubectl wait --for=condition=Ready cluster/postgres -n $NAMESPACE --timeout=300s
sleep 30

# Get the app credentials - exactly like your original
POSTGRES_PASSWORD=$(kubectl get secret postgres-app -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
PG_IP=$(kubectl get svc postgres-rw -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')

echo "✅ Found credentials (user: app, password length: ${#POSTGRES_PASSWORD})"
echo "📡 PostgreSQL service: $PG_IP"

# Setup database - exactly like your original
echo "🗄️ Setting up benchmark database..."
kubectl run setup-db --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
  -- bash -c '
echo "Connected to app database"
psql -c "SELECT current_database(), current_user;"

echo "Initializing pgbench in app database..."
pgbench -i -s 10 -q

echo "✅ pgbench tables created in app database"
psql -c "\dt pgbench*"
'

# Run benchmark - your original with the fixed write-heavy test
echo "🚀 Running PostgreSQL benchmark..."
echo "🚀 Running PostgreSQL benchmark with cycles measurement..."

# Start system-wide perf monitoring
perf stat -e cycles,instructions,cache-references,cache-misses,context-switches \
  -x ',' -o /tmp/pgbench_cycles.log -a -d sleep 600 &
PERF_PID=$!

kubectl run pgbench-perfect --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
  -- bash -c '
echo "=== PostgreSQL Performance Benchmark ==="
echo "Node: '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
echo "Host: $PGHOST"
echo "Database: $PGDATABASE"
echo "User: $PGUSER"
echo ""

echo "🚀 Running benchmark tests..."

echo "=== Single Client Test (20 seconds) ==="
pgbench -c 1 -j 1 -T 20 -P 5
echo ""  
echo "=== 5 Clients Test (20 seconds) ==="
pgbench -c 5 -j 2 -T 20 -P 5
echo ""
echo "=== 10 Clients Test (20 seconds) ==="
pgbench -c 10 -j 4 -T 20 -P 5
echo ""
echo "=== Read-Only Test (20 seconds) ==="
pgbench -c 10 -j 4 -T 20 -S -P 5
echo ""

echo "=== EXTENDED RESEARCH BENCHMARKS ==="
echo ""

echo "=== High Concurrency: 25 Clients (60 seconds) ==="
pgbench -c 25 -j 8 -T 60 -P 10
echo ""

echo "=== High Concurrency: 50 Clients (60 seconds) ==="
pgbench -c 50 -j 12 -T 60 -P 10
echo ""

echo "=== Sustained Load: 10 Clients (300 seconds) ==="
pgbench -c 10 -j 4 -T 300 -P 30
echo ""

# FIXED Write-heavy test (the only change needed)
echo "=== Write-Heavy: Fixed Custom Script (60 seconds) ==="
cat > /tmp/write_heavy_fixed.sql << 'EOF'
UPDATE pgbench_accounts SET abalance = abalance + 100 WHERE aid = (random() * 100000)::int + 1;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES 
    ((random() * 10)::int + 1, (random() * 10)::int + 1, (random() * 100000)::int + 1, (random() * 1000)::int, CURRENT_TIMESTAMP);
UPDATE pgbench_tellers SET tbalance = tbalance + (random() * 100)::int WHERE tid = (random() * 10)::int + 1;
EOF
pgbench -c 10 -j 4 -T 60 -f /tmp/write_heavy_fixed.sql -P 10
echo ""

echo "=== Large Transactions: Batch Updates (60 seconds) ==="
cat > /tmp/large_transactions.sql << 'EOF'
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid BETWEEN 1 AND 1000;
UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid BETWEEN 1001 AND 2000;
UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid BETWEEN 2001 AND 3000;
COMMIT;
EOF
pgbench -c 5 -j 2 -T 60 -f /tmp/large_transactions.sql -P 10
echo ""

echo "=== Complex Read Queries with Joins (60 seconds) ==="
cat > /tmp/complex_reads.sql << 'EOF'
SELECT a.aid, a.abalance, b.bbalance, t.tbalance 
FROM pgbench_accounts a 
JOIN pgbench_branches b ON a.bid = b.bid 
JOIN pgbench_tellers t ON a.bid = t.bid 
WHERE a.aid = (random() * 100000)::int + 1;
EOF
pgbench -c 10 -j 4 -T 60 -f /tmp/complex_reads.sql -P 10
echo ""

echo "=== Mixed Workload: 70% Read, 30% Write (120 seconds) ==="
cat > /tmp/mixed_workload.sql << 'EOF'
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
pgbench -c 15 -j 6 -T 120 -f /tmp/mixed_workload.sql -P 20
echo ""

echo "=== Connection Stress Test: 100 Connections (30 seconds) ==="
pgbench -c 100 -j 20 -T 30 -P 5
echo ""

echo "=== Prepared Statements Test (60 seconds) ==="
pgbench -c 10 -j 4 -T 60 -M prepared -P 10
echo ""

echo "=== Detailed Performance Analysis ==="
echo "Database size:"
psql -c "SELECT pg_size_pretty(pg_database_size('"'"'app'"'"'));"

echo "Table sizes:"
psql -c "SELECT schemaname,tablename,pg_size_pretty(pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename)) as size FROM pg_tables WHERE schemaname='"'"'public'"'"' ORDER BY pg_total_relation_size(schemaname||'"'"'.'"'"'||tablename) DESC;"

echo "Cache hit ratio:"
psql -c "SELECT datname, CASE WHEN blks_hit+blks_read > 0 THEN CAST(blks_hit*100.0/(blks_hit+blks_read) AS DECIMAL(5,2)) ELSE 0 END as cache_hit_ratio FROM pg_stat_database WHERE datname = 'app';"

rm -f /tmp/write_heavy_fixed.sql /tmp/large_transactions.sql /tmp/complex_reads.sql /tmp/mixed_workload.sql

echo ""
echo "✅ Enhanced PostgreSQL benchmark completed successfully!"
echo "📊 All tests completed on '"$NODE_NAME"' ('"$CVM_TYPE"' VM)"
'

echo ""
echo "🧹 Cleaning up resources..."
# Stop perf monitoring and analyze cycles
kill $PERF_PID 2>/dev/null || true
sleep 2

if [ -f /tmp/pgbench_cycles.log ]; then
    echo ""
    echo "📊 PostgreSQL Cycles Analysis:"
    
    # Parse perf output more robustly
    if [ -s /tmp/pgbench_cycles.log ]; then
        TOTAL_CYCLES=$(grep 'cycles' /tmp/pgbench_cycles.log | tail -1 | cut -d',' -f1 | tr -d ' ' | sed 's/[^0-9]//g' || echo "0")
        TOTAL_INSTRUCTIONS=$(grep 'instructions' /tmp/pgbench_cycles.log | tail -1 | cut -d',' -f1 | tr -d ' ' | sed 's/[^0-9]//g' || echo "0")
        TOTAL_CACHE_MISSES=$(grep 'cache-misses' /tmp/pgbench_cycles.log | tail -1 | cut -d',' -f1 | tr -d ' ' | sed 's/[^0-9]//g' || echo "0")
        TOTAL_CONTEXT_SWITCHES=$(grep 'context-switches' /tmp/pgbench_cycles.log | tail -1 | cut -d',' -f1 | tr -d ' ' | sed 's/[^0-9]//g' || echo "0")
        
        # Calculate IPC only if we have valid data
        if [ "$TOTAL_CYCLES" -gt 0 ] && [ "$TOTAL_INSTRUCTIONS" -gt 0 ]; then
            DATABASE_IPC=$(echo "scale=3; $TOTAL_INSTRUCTIONS / $TOTAL_CYCLES" | bc -l 2>/dev/null || echo "0")
        else
            DATABASE_IPC="0"
        fi
        
        echo "   Total cycles: $TOTAL_CYCLES"
        echo "   Instructions per cycle: $DATABASE_IPC"
        echo "   Cache misses: $TOTAL_CACHE_MISSES"
        echo "   Context switches: $TOTAL_CONTEXT_SWITCHES"
        
        if [ "$TOTAL_CYCLES" -gt 0 ]; then
            echo ""
            echo "🎯 KEY RESEARCH METRIC: Database IPC = $DATABASE_IPC"
            echo "   Compare this IPC value between regular and confidential VMs!"
        else
            echo ""
            echo "⚠️  No perf data collected - check perf permissions"
            echo "   Try: sudo sysctl kernel.perf_event_paranoid=1"
        fi
    else
        echo "   No perf data collected"
    fi
    
    # Show raw perf log for debugging
    echo ""
    echo "📋 Raw perf log (first 5 lines):"
    head -5 /tmp/pgbench_cycles.log 2>/dev/null || echo "   No perf log found"
    
    rm -f /tmp/pgbench_cycles.log
else
    echo "⚠️  Perf monitoring file not found"
fi

echo ""
kubectl delete namespace $NAMESPACE --force
echo "🎉 Perfect CNPG PostgreSQL benchmark completed!"
echo "📊 For detailed TPS numbers, check the pgbench output above"
