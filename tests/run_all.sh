#!/bin/bash
set -e

# Enhanced Benchmark Runner with proper execution handling
REPO_OWNER="mcfiet"
REPO_NAME="shadowkube"
TESTS_PATH="tests"
RAW_BASE="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/$TESTS_PATH"
RESULTS_DIR="/tmp/benchmark-results-$(date +%Y%m%d-%H%M%S)"

echo "🚀 Running all benchmark_*.sh scripts from repository"
echo "Node: $(hostname)"
echo "Results directory: $RESULTS_DIR"

# Create results directory
mkdir -p "$RESULTS_DIR"

# Get list of benchmark scripts
if command -v curl >/dev/null && command -v jq >/dev/null; then
    echo "📋 Fetching script list from GitHub API..."
    SCRIPTS=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$TESTS_PATH" | jq -r '.[] | select(.name | startswith("benchmark_") and endswith(".sh")) | .name' 2>/dev/null || echo "")
else
    SCRIPTS=""
fi

# Fallback if API fails
if [ -z "$SCRIPTS" ]; then
    echo "⚠️  API failed, using fallback script list..."
    SCRIPTS="benchmark_cpu.sh benchmark_network.sh benchmark_cnpg.sh"
fi

echo "📝 Scripts to run: $SCRIPTS"

# Function to run a single script with proper logging
run_script() {
    local script="$1"
    local output_file="$RESULTS_DIR/${script%.sh}.log"
    local start_time=$(date +%s)
    
    echo ""
    echo "▶️  Running $script..."
    echo "📁 Output: $output_file"
    
    # Download script first, then execute
    local temp_script="/tmp/${script}"
    
    if ! curl -fsSL "$RAW_BASE/$script" -o "$temp_script"; then
        echo "❌ Failed to download $script"
        return 1
    fi
    
    chmod +x "$temp_script"
    
    # Run script with extended timeout and proper logging
    local timeout_duration=1800  # 30 minutes
    
    if [ "$script" = "benchmark_cnpg.sh" ]; then
        timeout_duration=2400  # 40 minutes for database benchmarks
    fi
    
    echo "⏱️  Running with ${timeout_duration}s timeout..."
    
    # Execute with timeout and capture both stdout and stderr
    if timeout "$timeout_duration" bash -c "
        set -e
        cd /tmp
        exec '$temp_script' 2>&1
    " | tee "$output_file"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "✅ $script completed successfully in ${duration}s"
        
        # Extract key metrics if available
        if [ "$script" = "benchmark_cnpg.sh" ]; then
            echo "📊 Extracting database benchmark metrics..."
            grep -E "tps = |latency average|transaction type:" "$output_file" | head -20 || echo "No TPS data found"
        fi
        
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "❌ $script failed or timed out after ${duration}s"
        
        # Check if it was a timeout
        if [ $duration -ge $timeout_duration ]; then
            echo "⏰ Script timed out - this may be normal for long-running benchmarks"
        fi
        
        return 1
    fi
}

# Run each script
TOTAL_SCRIPTS=0
SUCCESSFUL_SCRIPTS=0

for script in $SCRIPTS; do
    TOTAL_SCRIPTS=$((TOTAL_SCRIPTS + 1))
    
    if run_script "$script"; then
        SUCCESSFUL_SCRIPTS=$((SUCCESSFUL_SCRIPTS + 1))
    fi
    
    # Clean up temp script
    rm -f "/tmp/$script"
done

echo ""
echo "🎉 Benchmark execution completed!"
echo "📊 Results: $SUCCESSFUL_SCRIPTS/$TOTAL_SCRIPTS scripts completed successfully"
echo "📁 All logs saved to: $RESULTS_DIR"

# Show results summary
echo ""
echo "📋 Results Summary:"
for script in $SCRIPTS; do
    local log_file="$RESULTS_DIR/${script%.sh}.log"
    if [ -f "$log_file" ]; then
        local file_size=$(du -h "$log_file" | cut -f1)
        local lines=$(wc -l < "$log_file")
        echo "   ${script}: ${file_size} (${lines} lines)"
        
        # Show last few lines for quick status check
        echo "   └── $(tail -1 "$log_file")"
    else
        echo "   ${script}: No output file"
    fi
done

echo ""
echo "🔍 To view detailed results:"
echo "   ls -la $RESULTS_DIR/"
echo "   cat $RESULTS_DIR/benchmark_cnpg.log  # Database benchmark"
echo "   cat $RESULTS_DIR/benchmark_cpu.log   # CPU benchmark"
echo "   cat $RESULTS_DIR/benchmark_network.log # Network benchmark"

# If benchmark_cnpg.log exists, show key metrics
if [ -f "$RESULTS_DIR/benchmark_cnpg.log" ]; then
    echo ""
    echo "🎯 Quick Database Benchmark Summary:"
    echo "----------------------------------------"
    grep -E "Node:|tps =|latency average =|High Concurrency|Sustained Load|Write-Heavy" "$RESULTS_DIR/benchmark_cnpg.log" | head -10 || echo "No summary data found"
fi
