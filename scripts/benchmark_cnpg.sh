#!/bin/bash
set -e

NODE_NAME=$(hostname)
CVM_TYPE="regular"
if sudo dmesg 2>/dev/null | grep -qi "Memory Encryption"; then
    CVM_TYPE="confidential"
fi

echo "🚀 Smart PostgreSQL Benchmark - $NODE_NAME ($CVM_TYPE)"

# Smart namespace handling
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

# Create simple cluster
cat << EOF | kubectl apply -f -
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
  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "500m"
EOF

echo "⏳ Waiting for PostgreSQL (3 minutes max)..."
if ! kubectl wait --for=condition=Ready cluster/postgres -n $NAMESPACE --timeout=180s; then
    echo "❌ PostgreSQL cluster failed to start"
    kubectl get events -n $NAMESPACE
    exit 1
fi

echo "✅ PostgreSQL ready!"

# Get password
PGPASSWORD=$(kubectl get secret postgres-superuser -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

# Create and run benchmark job
cat << EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: benchmark
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
          value: postgres-rw
        - name: PGUSER
          value: postgres
        - name: PGPASSWORD
          value: "$PGPASSWORD"
        - name: PGDATABASE
          value: postgres
        command:
        - bash
        - -c
        - |
          echo "🔗 Connecting to PostgreSQL..."
          for i in {1..30}; do
            if pg_isready; then
              echo "✅ Connected!"
              break
            fi
            sleep 2
          done
          
          echo "🗄️ Setting up benchmark database..."
          createdb benchmark || true
          export PGDATABASE=benchmark
          
          echo "📊 Initializing pgbench (scale 5)..."
          pgbench -i -s 5 -q
          
          echo ""
          echo "🚀 Running benchmarks..."
          echo ""
          
          echo "=== Single Client (20 seconds) ==="
          pgbench -c 1 -T 20 -P 5
          
          echo ""
          echo "=== 5 Clients (20 seconds) ==="
          pgbench -c 5 -T 20 -P 5
          
          echo ""
          echo "=== 10 Clients (20 seconds) ==="
          pgbench -c 10 -T 20 -P 5
          
          echo ""
          echo "✅ Benchmark completed!"
EOF

echo "🏃 Running benchmark job..."
kubectl wait --for=condition=complete job/benchmark -n $NAMESPACE --timeout=180s

echo ""
echo "📊 Results:"
kubectl logs job/benchmark -n $NAMESPACE

# Extract TPS results for summary
echo ""
echo "📈 Summary:"
RESULTS=$(kubectl logs job/benchmark -n $NAMESPACE)
TPS_1=$(echo "$RESULTS" | grep -A5 "Single Client" | grep "tps =" | awk '{print $3}' || echo "N/A")
TPS_5=$(echo "$RESULTS" | grep -A5 "5 Clients" | grep "tps =" | awk '{print $3}' || echo "N/A")
TPS_10=$(echo "$RESULTS" | grep -A5 "10 Clients" | grep "tps =" | awk '{print $3}' || echo "N/A")

echo "  1 client:  $TPS_1 TPS"
echo "  5 clients: $TPS_5 TPS"
echo "  10 clients: $TPS_10 TPS"

# Save results
mkdir -p results
cat > results/pgbench-$NODE_NAME-$(date +%H%M%S).json << RESULT_EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "node": "$NODE_NAME",
  "vm_type": "$CVM_TYPE",
  "results": {
    "1_client_tps": "$TPS_1",
    "5_client_tps": "$TPS_5",
    "10_client_tps": "$TPS_10"
  }
}
RESULT_EOF

echo ""
echo "💾 Results saved to: results/pgbench-$NODE_NAME-$(date +%H%M%S).json"
echo "✅ Benchmark complete!"
