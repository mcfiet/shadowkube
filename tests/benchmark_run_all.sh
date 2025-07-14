#!/bin/bash
set -e

echo "🚀 Running Complete Benchmark Suite from Repository"
echo "=================================================="

NODE_NAME=$(hostname)
CVM_TYPE="regular"
if sudo dmesg 2>/dev/null | grep -qi "Memory Encryption"; then
    CVM_TYPE="confidential"
fi

echo "Node: $NODE_NAME ($CVM_TYPE VM)"
echo "Time: $(date)"
echo ""

REPO_BASE="https://raw.githubusercontent.com/mcfiet/shadowkube/main/tests"

# Create results directory
RESULTS_DIR="complete-benchmark-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Function to run script and capture output
run_benchmark() {
    local script_name="$1"
    local description="$2"
    
    echo "🔄 Running $description..."
    echo "   Script: $script_name"
    
    # Download and run
    if curl -fsSL "$REPO_BASE/$script_name" | bash 2>&1 | tee "$RESULTS_DIR/${script_name%.sh}.log"; then
        echo "✅ $description completed"
    else
        echo "❌ $description failed"
    fi
    echo ""
}

# Run all benchmarks
run_benchmark "cpu_benchmark.sh" "CPU and Memory Benchmark"
run_benchmark "network_benchmark.sh" "Network Latency Benchmark" 
run_benchmark "postgres_benchmark.sh" "PostgreSQL CNPG Benchmark"

# Summary
echo "🎉 Complete benchmark suite finished!"
echo "📁 All results saved in: $RESULTS_DIR/"
echo "📊 Summary logs:"
ls -la "$RESULTS_DIR/"

# Optional: Create combined summary
echo ""
echo "📈 Combined Summary for $NODE_NAME ($CVM_TYPE VM):"
echo "   CPU Benchmark: $(grep -h "CPU Events/sec" "$RESULTS_DIR"/*.log | tail -1 || echo "See CPU log")"
echo "   Network: $(grep -h "Average.*latency" "$RESULTS_DIR"/*.log | tail -1 || echo "See Network log")"  
echo "   PostgreSQL: $(grep -h "TPS" "$RESULTS_DIR"/*.log | tail -1 || echo "See PostgreSQL log")"

# Store in VHSM if available
if command -v vault >/dev/null 2>&1; then
    export VAULT_ADDR=https://vhsm.enclaive.cloud/
    if vault token lookup >/dev/null 2>&1; then
        echo ""
        echo "💾 Storing combined results in VHSM..."
        vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-complete-$(date +%s) \
            timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            node_name="$NODE_NAME" \
            vm_type="$CVM_TYPE" \
            benchmark_suite="complete" \
            status="completed" \
            results_directory="$RESULTS_DIR"
        echo "✅ Combined results stored in VHSM"
    fi
fi
