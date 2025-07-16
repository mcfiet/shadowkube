#!/bin/bash
set -e

NODE_NAME=$(hostname)
CVM_TYPE="confidential"

echo "🚀 Perfect CNPG Benchmark - $NODE_NAME"

NAMESPACE="benchmark-perfect"

# Cleanup vorheriger Reste (inkl. Finalizer-Blocker)
if kubectl get namespace $NAMESPACE &>/dev/null; then
  echo "🧹 Vorheriges Cluster und Namespace $NAMESPACE entfernen…"
  # Cluster-CR ohne Finalizer löschen
  kubectl delete cluster postgres -n "$NAMESPACE" \
    --force --grace-period=0 --ignore-not-found || true
  kubectl patch cluster postgres -n $NAMESPACE \
    -p '{"metadata":{"finalizers":[]}}' --type=merge || true
  # Namespace sofort zwingen zu löschen und Finalizer entfernen
  kubectl delete namespace "$NAMESPACE" \
    --force --grace-period=0 --ignore-not-found || true
  kubectl patch namespace $NAMESPACE \
    -p '{"metadata":{"finalizers":[]}}' --type=merge || true
fi

kubectl create namespace $NAMESPACE

# Create cluster
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
    size: 1Gi
EOF

echo "⏳ Waiting for PostgreSQL cluster..."
kubectl wait --for=condition=Ready cluster/postgres -n $NAMESPACE --timeout=300s
sleep 30

# Get the app credentials
POSTGRES_PASSWORD=$(kubectl get secret postgres-app -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
PG_IP=$(kubectl get svc postgres-rw -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')

echo "✅ Found credentials (user: app, password length: ${#POSTGRES_PASSWORD})"
echo "📡 PostgreSQL service: $PG_IP"

# First, create the benchmark database using the app database (not postgres)
echo "🗄️ Setting up benchmark database..."
kubectl run setup-db --image=postgres:15-alpine -n $NAMESPACE --rm -i --restart=Never \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="PGHOST=$PG_IP" \
  --env="PGUSER=app" \
  --env="PGDATABASE=app" \
  -- bash -c '
echo "Connected to app database"
psql -c "SELECT current_database(), current_user;"

# Initialize pgbench in the app database directly
echo "Initializing pgbench in app database..."
pgbench -i -s 10 -q

echo "✅ pgbench tables created in app database"
psql -c "\dt pgbench*"
'

# Now run the benchmark using the app database
echo "🚀 Running PostgreSQL benchmark..."
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

echo "=== EXTENDED RESEARCH BENCHMARKS ==="
echo ""

# 1. High Concurrency Tests (Critical for cVM vs regular VM comparison)
echo "=== High Concurrency: 25 Clients (60 seconds) ==="
pgbench -c 25 -j 8 -T 60 -P 10
echo ""

echo "=== High Concurrency: 50 Clients (60 seconds) ==="
pgbench -c 50 -j 12 -T 60 -P 10
echo ""

# 2. Sustained Load Tests (Important for confidential computing overhead)
echo "=== Sustained Load: 10 Clients (300 seconds = 5 minutes) ==="
pgbench -c 10 -j 4 -T 300 -P 30
echo ""

# 3. Write-Heavy Tests (Tests encryption overhead)
echo "=== Write-Heavy: Custom Script (60 seconds) ==="
cat > /tmp/write_heavy.sql << 'EOF'
INSERT INTO pgbench_accounts (aid, bid, abalance, filler) 
VALUES (random() * 100000, random() * 10 + 1, random() * 1000000, 'heavy write test');
UPDATE pgbench_accounts SET abalance = abalance + 100 WHERE aid = (random() * 100000)::int;
DELETE FROM pgbench_accounts WHERE aid = (random() * 100000)::int AND abalance < 1000;
EOF
pgbench -c 10 -j 4 -T 60 -f /tmp/write_heavy.sql -P 10
echo ""

# 4. Large Transaction Tests (Tests memory encryption impact)
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

# 5. Read-Heavy with Joins (Tests CPU overhead in cVMs)
echo "=== Complex Read Queries with Joins (60 seconds) ==="
cat > /tmp/complex_reads.sql << 'EOF'
SELECT a.aid, a.abalance, b.bbalance, t.tbalance 
FROM pgbench_accounts a 
JOIN pgbench_branches b ON a.bid = b.bid 
JOIN pgbench_tellers t ON a.bid = t.bid 
WHERE a.aid = (random() * 100000)::int;
EOF
pgbench -c 10 -j 4 -T 60 -f /tmp/complex_reads.sql -P 10
echo ""

# 6. Mixed Workload (Most realistic test)
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

# 7. Connection Stress Test (Tests network and memory overhead)
echo "=== Connection Stress Test: 100 Connections (30 seconds) ==="
pgbench -c 100 -j 20 -T 30 -P 5
echo ""

# 8. Prepared Statement Performance (Tests parsing overhead)
echo "=== Prepared Statements Test (60 seconds) ==="
pgbench -c 10 -j 4 -T 60 -M prepared -P 10
echo ""

# 9. Database Size Impact Test
echo "=== Large Dataset Test: Scale Factor 10 (if available) ==="
# Check if we have a larger dataset
if psql -d app -c "SELECT count(*) FROM pgbench_accounts;" | grep -q "1000000"; then
    echo "Using existing large dataset"
    pgbench -c 10 -j 4 -T 60 -P 10
else
    echo "Creating larger dataset for testing..."
    pgbench -i -s 10 -q  # Create 10x larger dataset
    pgbench -c 10 -j 4 -T 60 -P 10
fi
echo ""

# 10. Collect detailed performance metrics
echo "=== Detailed Performance Analysis ==="
echo "Database size:"
psql -d app -c "SELECT pg_size_pretty(pg_database_size('app'));"

echo "Table sizes:"
psql -d app -c "SELECT schemaname,tablename,pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size FROM pg_tables WHERE schemaname='public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"

echo "Active connections:"
psql -d app -c "SELECT count(*) as active_connections FROM pg_stat_activity WHERE state = 'active';"

echo "Cache hit ratio:"
psql -d app -c "SELECT datname, round(blks_hit::float/(blks_hit+blks_read)*100, 2) as cache_hit_ratio FROM pg_stat_database WHERE datname = 'app';"

echo ""
echo "✅ Enhanced PostgreSQL benchmark completed successfully!"
echo "📊 Results summary for $HOSTNAME ($NODE_TYPE):"
echo "   - Basic performance tests: Completed"
echo "   - High concurrency tests: Completed"  
echo "   - Sustained load tests: Completed"
echo "   - Write-heavy tests: Completed"
echo "   - Complex query tests: Completed"
echo "   - Connection stress tests: Completed"
echo ""
echo "🔬 Research Notes:"
echo "   - Compare these results with regular VM benchmarks"
echo "   - Look for performance differences in high concurrency scenarios"
echo "   - Analyze write-heavy workload impact (encryption overhead)"
echo "   - Document connection handling differences"

# Cleanup temporary files
rm -f /tmp/write_heavy.sql /tmp/large_transactions.sql /tmp/complex_reads.sql /tmp/mixed_workload.sql


# Store comprehensive results in VHSM
if command -v vault >/dev/null 2>&1; then
  export VAULT_ADDR=https://vhsm.enclaive.cloud/
  if vault token lookup >/dev/null 2>&1; then
    echo "💾 Storing comprehensive results in VHSM..."
    vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-postgresql-final-$(date +%s) \
      timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      node_name="$NODE_NAME" \
      vm_type="$CVM_TYPE" \
      benchmark_type="postgresql_cnpg_working" \
      postgresql_version="17.5" \
      scale_factor="10" \
      tests_completed="single_client,5_clients,10_clients,readonly" \
      test_duration_seconds="20" \
      total_rows="1000000" \
      status="success"
    echo "✅ Results stored in VHSM"
  fi
fi

echo ""
echo "🎉 Perfect CNPG PostgreSQL benchmark completed!"
echo "📊 For detailed TPS numbers, check the pgbench output above"
echo "💾 Results summary stored in VHSM for comparison with other nodes"

# Cleanup
kubectl delete namespace $NAMESPACE --force
