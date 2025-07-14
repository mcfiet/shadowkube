#!/bin/bash
set -e

# Simple Benchmark Runner - finds and runs all benchmark_*.sh scripts
REPO_OWNER="mcfiet"
REPO_NAME="shadowkube"
TESTS_PATH="tests"
RAW_BASE="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/$TESTS_PATH"

echo "🚀 Running all benchmark_*.sh scripts from repository"
echo "Node: $(hostname)"

# Get list of benchmark scripts (simple method)
if command -v curl >/dev/null && command -v jq >/dev/null; then
    SCRIPTS=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$TESTS_PATH" | jq -r '.[] | select(.name | startswith("benchmark_") and endswith(".sh")) | .name')
else
    # Fallback: try common names
    SCRIPTS="benchmark_cpu.sh benchmark_network.sh benchmark_cnpg.sh"
fi

# Run each script with timeout
for script in $SCRIPTS; do
    echo ""
    echo "▶️  Running $script..."
    
    # Download and run with 20 minute timeout
    if timeout 1200 bash -c "curl -fsSL '$RAW_BASE/$script' | bash"; then
        echo "✅ $script completed"
    else
        echo "❌ $script failed or timed out"
    fi
done

echo ""
echo "🎉 All benchmark scripts completed!"
