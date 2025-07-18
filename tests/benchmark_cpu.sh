#!/bin/bash
set -e

# =============================================================================
# CPU and Memory Benchmark Script with VHSM Integration
# Tests: CPU performance, Memory throughput, Context switching
# For CVM vs Regular VM comparison research
# =============================================================================

# VHSM Environment
export VAULT_ADDR=https://vhsm.enclaive.cloud/

NODE_NAME=$(hostname)
CVM_TYPE="regular"
if sudo dmesg 2>/dev/null | grep -qi "Memory Encryption"; then
    CVM_TYPE="confidential"
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING: $1${NC}"; }
error() { echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}"; }
info() { echo -e "${BLUE}[$(date +'%H:%M:%S')] INFO: $1${NC}"; }

# System information
CPU_CORES=$(nproc)
MEMORY_GB=$(free -g | awk 'NR==2{printf "%.1f", $2}')
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)

echo "🚀 CPU and Memory Benchmark Suite"
echo "=================================="
echo "Node: $NODE_NAME ($CVM_TYPE VM)"
echo "CPU: $CPU_MODEL ($CPU_CORES cores)"
echo "Memory: ${MEMORY_GB}GB"
echo ""

# Check VHSM connection
if command -v vault >/dev/null 2>&1 && vault token lookup >/dev/null 2>&1; then
    VHSM_AVAILABLE=true
    log "✅ VHSM connection verified"
else
    VHSM_AVAILABLE=false
    warn "VHSM not available - results will be stored locally only"
fi

# =============================================================================
# Install sysbench if needed
# =============================================================================

install_sysbench() {
    if ! command -v sysbench >/dev/null 2>&1; then
        log "📦 Installing sysbench..."
        if [ -f /etc/suse-release ] || [ -f /etc/SUSE-brand ]; then
            sudo zypper install -y sysbench
        elif [ -f /etc/debian_version ]; then
            sudo apt-get update && sudo apt-get install -y sysbench
        elif [ -f /etc/redhat-release ]; then
            sudo yum install -y epel-release && sudo yum install -y sysbench
        else
            error "Unsupported OS for sysbench installation"
            return 1
        fi
    fi
    log "✅ sysbench available"
}

# =============================================================================
# CPU Benchmarks
# =============================================================================

run_cpu_benchmarks() {
    log "🧮 Running CPU benchmarks with cycles measurement..."
    
    install_sysbench || { error "Could not install sysbench"; return 1; }
    
    # Enable perf access
    echo 1 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || true
    
    # CPU Test 1: Prime number calculation with cycles
    info "   Test 1: CPU Prime Calculation (60 seconds) + Cycles"
    PERF_RESULT=$(perf stat -e cycles,instructions,cache-references,cache-misses,context-switches -x ',' \
        sysbench cpu --cpu-max-prime=20000 --threads="$CPU_CORES" --time=60 run 2>&1)
    
    # Parse sysbench output
    CPU_RESULT=$(echo "$PERF_RESULT" | grep -A 20 "sysbench")
    if echo "$CPU_RESULT" | grep -q "events per second"; then
        CPU_EVENTS=$(echo "$CPU_RESULT" | grep "events per second" | awk '{print $4}')
        CPU_LATENCY_AVG=$(echo "$CPU_RESULT" | grep "avg:" | awk '{print $2}' | sed 's/ms//')
        CPU_LATENCY_95TH=$(echo "$CPU_RESULT" | grep "95th percentile:" | awk '{print $3}' | sed 's/ms//')
        CPU_LATENCY_MAX=$(echo "$CPU_RESULT" | grep "max:" | awk '{print $2}' | sed 's/ms//')
    else
        CPU_EVENTS="0"
        CPU_LATENCY_AVG="999"
        CPU_LATENCY_95TH="999"
        CPU_LATENCY_MAX="999"
    fi
    
    # Parse perf cycles output
    CPU_CYCLES=$(echo "$PERF_RESULT" | grep 'cycles' | head -1 | cut -d',' -f1 | tr -d ' ')
    CPU_INSTRUCTIONS=$(echo "$PERF_RESULT" | grep 'instructions' | cut -d',' -f1 | tr -d ' ')
    CPU_CACHE_REFS=$(echo "$PERF_RESULT" | grep 'cache-references' | cut -d',' -f1 | tr -d ' ')
    CPU_CACHE_MISSES=$(echo "$PERF_RESULT" | grep 'cache-misses' | cut -d',' -f1 | tr -d ' ')
    CPU_CONTEXT_SWITCHES=$(echo "$PERF_RESULT" | grep 'context-switches' | cut -d',' -f1 | tr -d ' ')
    
    # Calculate cycles metrics
    CPU_CYCLES_PER_EVENT=$((CPU_CYCLES / CPU_EVENTS))
    CPU_IPC=$(echo "scale=3; $CPU_INSTRUCTIONS / $CPU_CYCLES" | bc -l 2>/dev/null || echo "0")
    CPU_CACHE_MISS_RATE=$(echo "scale=3; $CPU_CACHE_MISSES * 100 / $CPU_CACHE_REFS" | bc -l 2>/dev/null || echo "0")
    
    # CPU Test 2: Intensive calculation with cycles
    info "   Test 2: CPU Intensive Calculation (30 seconds) + Cycles"
    PERF_INTENSIVE_RESULT=$(perf stat -e cycles,instructions -x ',' \
        sysbench cpu --cpu-max-prime=10000 --threads="$CPU_CORES" --time=30 run 2>&1)
    
    CPU_INTENSIVE_RESULT=$(echo "$PERF_INTENSIVE_RESULT" | grep -A 10 "sysbench")
    if echo "$CPU_INTENSIVE_RESULT" | grep -q "events per second"; then
        CPU_INTENSIVE_EVENTS=$(echo "$CPU_INTENSIVE_RESULT" | grep "events per second" | awk '{print $4}')
    else
        CPU_INTENSIVE_EVENTS="0"
    fi
    
    CPU_INTENSIVE_CYCLES=$(echo "$PERF_INTENSIVE_RESULT" | grep 'cycles' | cut -d',' -f1 | tr -d ' ')
    CPU_INTENSIVE_CYCLES_PER_EVENT=$((CPU_INTENSIVE_CYCLES / CPU_INTENSIVE_EVENTS))
    
    log "✅ CPU Benchmark Results:"
    log "   Prime calc: $CPU_EVENTS events/sec, $CPU_CYCLES_PER_EVENT cycles/event"
    log "   Prime IPC: $CPU_IPC, Cache miss rate: ${CPU_CACHE_MISS_RATE}%"
    log "   Intensive: $CPU_INTENSIVE_EVENTS events/sec, $CPU_INTENSIVE_CYCLES_PER_EVENT cycles/event"
    log "   Context switches: $CPU_CONTEXT_SWITCHES"
}

# =============================================================================
# Memory Benchmarks
# =============================================================================

run_memory_benchmarks() {
    log "🧠 Running memory benchmarks..."
    
    # Memory Test 1: Sequential Write
    info "   Test 1: Memory Sequential Write (30 seconds)"
    MEMORY_WRITE_RESULT=$(timeout 60 sysbench memory --memory-block-size=1K --memory-total-size=2G --memory-oper=write --threads="$CPU_CORES" --time=30 run 2>&1 || echo "Memory write test failed")
    
    if echo "$MEMORY_WRITE_RESULT" | grep -q "transferred"; then
        MEMORY_WRITE_THROUGHPUT=$(echo "$MEMORY_WRITE_RESULT" | grep "transferred" | awk '{print $3" "$4}')
        MEMORY_WRITE_LATENCY=$(echo "$MEMORY_WRITE_RESULT" | grep "avg:" | awk '{print $2}' | sed 's/ms//')
    else
        MEMORY_WRITE_THROUGHPUT="unknown"
        MEMORY_WRITE_LATENCY="999"
    fi
    
    # Memory Test 2: Sequential Read
    info "   Test 2: Memory Sequential Read (30 seconds)"
    MEMORY_READ_RESULT=$(timeout 60 sysbench memory --memory-block-size=1K --memory-total-size=2G --memory-oper=read --threads="$CPU_CORES" --time=30 run 2>&1 || echo "Memory read test failed")
    
    if echo "$MEMORY_READ_RESULT" | grep -q "transferred"; then
        MEMORY_READ_THROUGHPUT=$(echo "$MEMORY_READ_RESULT" | grep "transferred" | awk '{print $3" "$4}')
        MEMORY_READ_LATENCY=$(echo "$MEMORY_READ_RESULT" | grep "avg:" | awk '{print $2}' | sed 's/ms//')
    else
        MEMORY_READ_THROUGHPUT="unknown"
        MEMORY_READ_LATENCY="999"
    fi
    
    # Memory Test 3: Random Access
    info "   Test 3: Memory Random Access (30 seconds)"
    MEMORY_RANDOM_RESULT=$(timeout 60 sysbench memory --memory-block-size=1K --memory-total-size=1G --memory-oper=write --memory-access-mode=rnd --threads="$CPU_CORES" --time=30 run 2>&1 || echo "Memory random test failed")
    
    if echo "$MEMORY_RANDOM_RESULT" | grep -q "transferred"; then
        MEMORY_RANDOM_THROUGHPUT=$(echo "$MEMORY_RANDOM_RESULT" | grep "transferred" | awk '{print $3" "$4}')
    else
        MEMORY_RANDOM_THROUGHPUT="unknown"
    fi
    
    log "✅ Memory Benchmark Results:"
    log "   Write: $MEMORY_WRITE_THROUGHPUT (${MEMORY_WRITE_LATENCY}ms latency)"
    log "   Read: $MEMORY_READ_THROUGHPUT (${MEMORY_READ_LATENCY}ms latency)"
    log "   Random: $MEMORY_RANDOM_THROUGHPUT"
}

# =============================================================================
# Context Switching and Threading Benchmarks
# =============================================================================

run_context_switching_benchmarks() {
    log "🔄 Running context switching benchmarks..."
    
    # Context Switch Test 1: Thread synchronization
    info "   Test 1: Thread Context Switching (30 seconds)"
    CONTEXT_RESULT=$(timeout 60 sysbench threads --thread-yields=100 --thread-locks=2 --threads="$CPU_CORES" --time=30 run 2>&1 || echo "Context switch test failed")
    
    if echo "$CONTEXT_RESULT" | grep -q "events per second"; then
        CONTEXT_SWITCHES=$(echo "$CONTEXT_RESULT" | grep "events per second" | awk '{print $4}')
        CONTEXT_LATENCY=$(echo "$CONTEXT_RESULT" | grep "avg:" | awk '{print $2}' | sed 's/ms//')
    else
        CONTEXT_SWITCHES="0"
        CONTEXT_LATENCY="999"
    fi
    
    # Context Switch Test 2: High concurrency
    info "   Test 2: High Concurrency Threading (30 seconds)"
    MUTEX_RESULT=$(timeout 60 sysbench mutex --mutex-num=1024 --mutex-locks=10000 --mutex-loops=5000 --threads="$CPU_CORES" --time=30 run 2>&1 || echo "Mutex test failed")
    
    if echo "$MUTEX_RESULT" | grep -q "events per second"; then
        MUTEX_EVENTS=$(echo "$MUTEX_RESULT" | grep "events per second" | awk '{print $4}')
    else
        MUTEX_EVENTS="0"
    fi
    
    log "✅ Context Switching Results:"
    log "   Context switches: $CONTEXT_SWITCHES/sec (${CONTEXT_LATENCY}ms latency)"
    log "   Mutex operations: $MUTEX_EVENTS/sec"
}

# =============================================================================
# File I/O Performance (as CPU/storage interaction measure)
# =============================================================================

run_fileio_benchmarks() {
    log "💾 Running file I/O benchmarks..."
    
    # Create test directory
    TEST_DIR="/var/openebs/benchmark-test-$$"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # File I/O Test 1: Random read/write
    info "   Test 1: Random Read/Write I/O (30 seconds)"
    sysbench fileio --file-total-size=1G prepare >/dev/null 2>&1
    
    FILEIO_RESULT=$(timeout 60 sysbench fileio --file-total-size=1G --file-test-mode=rndrw --threads="$CPU_CORES" --time=30 run 2>&1 || echo "File I/O test failed")
    
    if echo "$FILEIO_RESULT" | grep -q "reads/s:"; then
        FILEIO_READS=$(echo "$FILEIO_RESULT" | grep "reads/s:" | awk '{print $2}')
        FILEIO_WRITES=$(echo "$FILEIO_RESULT" | grep "writes/s:" | awk '{print $2}')
        FILEIO_THROUGHPUT=$(echo "$FILEIO_RESULT" | grep "Throughput:" | awk '{print $2" "$3}')
        FILEIO_LATENCY=$(echo "$FILEIO_RESULT" | grep "avg:" | awk '{print $2}' | sed 's/ms//')
    else
        FILEIO_READS="0"
        FILEIO_WRITES="0"
        FILEIO_THROUGHPUT="unknown"
        FILEIO_LATENCY="999"
    fi
    
    # Cleanup
    sysbench fileio --file-total-size=1G cleanup >/dev/null 2>&1
    cd - >/dev/null
    rm -rf "$TEST_DIR"
    
    log "✅ File I/O Results:"
    log "   Reads: $FILEIO_READS/sec, Writes: $FILEIO_WRITES/sec"
    log "   Throughput: $FILEIO_THROUGHPUT, Latency: ${FILEIO_LATENCY}ms"
}

# =============================================================================
# Results Storage and Analysis
# =============================================================================

store_results() {
    log "📊 Storing benchmark results..."
    
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    RESULTS_FILE="cpu-memory-results-$NODE_NAME-$(date +%H%M%S).json"
    
    # Create comprehensive JSON results
    cat > "$RESULTS_FILE" << EOF
{
    "benchmark_metadata": {
        "timestamp": "$TIMESTAMP",
        "node_name": "$NODE_NAME",
        "vm_type": "$CVM_TYPE",
        "benchmark_type": "cpu_memory_performance",
        "duration_seconds": $(($(date +%s) - START_TIME))
    },
    "system_info": {
        "cpu_model": "$CPU_MODEL",
        "cpu_cores": $CPU_CORES,
        "memory_gb": $MEMORY_GB,
        "kernel": "$(uname -r)",
        "os": "$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    },
    "cpu_benchmarks": {
        "prime_calculation": {
            "events_per_second": $CPU_EVENTS,
            "cycles_per_event": $CPU_CYCLES_PER_EVENT,
            "instructions_per_cycle": $CPU_IPC,
            "cache_miss_rate_percent": $CPU_CACHE_MISS_RATE,
            "context_switches": $CPU_CONTEXT_SWITCHES,
            "latency_avg_ms": $CPU_LATENCY_AVG,
            "latency_95th_ms": $CPU_LATENCY_95TH,
            "latency_max_ms": $CPU_LATENCY_MAX,
            "test_duration_seconds": 60
        },
        "intensive_calculation": {
            "events_per_second": $CPU_INTENSIVE_EVENTS,
            "cycles_per_event": $CPU_INTENSIVE_CYCLES_PER_EVENT,
            "test_duration_seconds": 30
        }
    },
    "memory_benchmarks": {
        "sequential_write": {
            "throughput": "$MEMORY_WRITE_THROUGHPUT",
            "latency_avg_ms": $MEMORY_WRITE_LATENCY
        },
        "sequential_read": {
            "throughput": "$MEMORY_READ_THROUGHPUT",
            "latency_avg_ms": $MEMORY_READ_LATENCY
        },
        "random_access": {
            "throughput": "$MEMORY_RANDOM_THROUGHPUT"
        }
    },
    "context_switching": {
        "switches_per_second": $CONTEXT_SWITCHES,
        "latency_avg_ms": $CONTEXT_LATENCY,
        "mutex_operations_per_second": $MUTEX_EVENTS
    },
    "file_io": {
        "reads_per_second": $FILEIO_READS,
        "writes_per_second": $FILEIO_WRITES,
        "throughput": "$FILEIO_THROUGHPUT",
        "latency_avg_ms": $FILEIO_LATENCY
    },
    "performance_analysis": {
        "cpu_performance_index": $(echo "scale=2; $CPU_EVENTS / $CPU_CORES" | bc -l 2>/dev/null || echo "0"),
        "memory_bandwidth_ratio": "$(echo "$MEMORY_READ_THROUGHPUT" | awk '{print $1}'):$(echo "$MEMORY_WRITE_THROUGHPUT" | awk '{print $1}')",
        "context_switch_efficiency": $(echo "scale=2; $CONTEXT_SWITCHES / 1000" | bc -l 2>/dev/null || echo "0")
    }
}
EOF

    # Store in VHSM if available
    if [ "$VHSM_AVAILABLE" = "true" ]; then
        log "💾 Storing results in VHSM..."
        vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-cpu-memory-$(date +%Y%m%d-%H%M%S) \
            timestamp="$TIMESTAMP" \
            node_name="$NODE_NAME" \
            vm_type="$CVM_TYPE" \
            benchmark_type="cpu_memory_performance" \
            cpu_events_per_second="$CPU_EVENTS" \
            cpu_latency_avg_ms="$CPU_LATENCY_AVG" \
            cpu_intensive_events="$CPU_INTENSIVE_EVENTS" \
            memory_write_throughput="$MEMORY_WRITE_THROUGHPUT" \
            memory_read_throughput="$MEMORY_READ_THROUGHPUT" \
            memory_random_throughput="$MEMORY_RANDOM_THROUGHPUT" \
            context_switches_per_second="$CONTEXT_SWITCHES" \
            mutex_events_per_second="$MUTEX_EVENTS" \
            fileio_reads_per_second="$FILEIO_READS" \
            fileio_writes_per_second="$FILEIO_WRITES" \
            cpu_cores="$CPU_CORES" \
            memory_gb="$MEMORY_GB"
        log "✅ Results stored in VHSM"
    fi
    
    log "📁 Local results saved: $RESULTS_FILE"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    START_TIME=$(date +%s)
    
    # Check if running with appropriate privileges
    if [ "$EUID" -ne 0 ]; then
        warn "Some benchmarks may require root privileges for optimal results"
        warn "Consider running: sudo $0"
    fi
    
    # Run all benchmark suites
    run_cpu_benchmarks
    echo ""
    run_memory_benchmarks
    echo ""
    run_context_switching_benchmarks
    echo ""
    run_fileio_benchmarks
    echo ""
    store_results
    
    TOTAL_TIME=$(($(date +%s) - START_TIME))
    
    echo ""
    log "🎉 CPU and Memory benchmark suite completed!"
    log "⏱️  Total time: ${TOTAL_TIME} seconds"
    
    # Summary for research
    echo ""
    echo "📊 Research Summary for $NODE_NAME ($CVM_TYPE VM):"
    echo "   CPU Performance: $CPU_EVENTS events/sec (${CPU_LATENCY_AVG}ms avg latency)"
    echo "   Memory Write: $MEMORY_WRITE_THROUGHPUT"
    echo "   Memory Read: $MEMORY_READ_THROUGHPUT"
    echo "   Context Switches: $CONTEXT_SWITCHES/sec"
    echo "   File I/O: $FILEIO_READS reads/sec, $FILEIO_WRITES writes/sec"
    
    if [ "$CVM_TYPE" = "regular" ]; then
        echo ""
        warn "💡 NEXT STEP: Run this same script on a confidential VM to compare performance!"
        warn "    The JSON results can be directly compared for your research paper."
    else
        echo ""
        log "🔒 Confidential VM benchmarked!"
        log "   Compare these results with regular VM benchmarks for your paper."
        log "   Look for performance overhead in CPU events/sec and memory throughput."
    fi
}

# Run main function
main "$@"
