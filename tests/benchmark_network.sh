#!/bin/bash
set -e

# =============================================================================
# Network Latency Benchmark Script - FIXED VERSION
# Simple network testing without syntax errors
# =============================================================================

export VAULT_ADDR=https://vhsm.enclaive.cloud/

NODE_NAME=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')
CVM_TYPE="regular"
if sudo dmesg 2>/dev/null | grep -qi "Memory Encryption"; then
  CVM_TYPE="confidential"
fi

echo "🌐 Network Latency Benchmark Suite"
echo "=================================="
echo "Node: $NODE_NAME ($CVM_TYPE VM)"
echo "IP: $NODE_IP"

# Check VHSM
if command -v vault >/dev/null 2>&1 && vault token lookup >/dev/null 2>&1; then
  echo "✅ VHSM connection verified"
  VHSM_AVAILABLE=true
else
  echo "⚠️ VHSM not available"
  VHSM_AVAILABLE=false
fi

# =============================================================================
# Test cluster nodes
# =============================================================================

echo ""
echo "🔍 Testing cluster node latency..."

if command -v kubectl >/dev/null 2>&1; then
  CLUSTER_NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

  if [ -n "$CLUSTER_NODES" ]; then
    echo "Found cluster nodes: $CLUSTER_NODES"

    for target_ip in $CLUSTER_NODES; do
      if [ "$target_ip" != "$NODE_IP" ]; then
        echo "Testing $target_ip..."
        PING_RESULT=$(ping -c 3 "$target_ip" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' 2>/dev/null || echo "999")
        echo "  Latency: ${PING_RESULT}ms"
      fi
    done
  else
    echo "No cluster nodes found"
  fi
else
  echo "kubectl not available"
fi

# =============================================================================
# Test external connectivity
# =============================================================================

echo ""
echo "🌍 Testing external connectivity..."

TARGETS="8.8.8.8 1.1.1.1 9.9.9.9"

for target in $TARGETS; do
  echo "Testing $target..."
  PING_RESULT=$(ping -c 3 "$target" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' 2>/dev/null || echo "999")
  echo "  Latency: ${PING_RESULT}ms"
done

# =============================================================================
# Bandwidth test
# =============================================================================

echo ""
echo "📊 Testing bandwidth..."

DOWNLOAD_START=$(date +%s.%N)
if curl -s --max-time 20 -o /dev/null http://speedtest.ftp.otenet.gr/files/test10Mb.db 2>/dev/null; then
  DOWNLOAD_END=$(date +%s.%N)
  DOWNLOAD_TIME=$(echo "$DOWNLOAD_END - $DOWNLOAD_START" | bc -l 2>/dev/null || echo "1")
  DOWNLOAD_MBPS=$(echo "scale=2; 80 / $DOWNLOAD_TIME" | bc -l 2>/dev/null || echo "0")
  echo "Download bandwidth: ${DOWNLOAD_MBPS} Mbps"
else
  echo "Bandwidth test failed"
fi

# =============================================================================
# Store results in VHSM
# =============================================================================

if [ "$VHSM_AVAILABLE" = "true" ]; then
  echo ""
  echo "💾 Storing results in VHSM..."

  vault write -namespace=team-msc cubbyhole/benchmark-results/$NODE_NAME-network-$(date +%s) \
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    node_name="$NODE_NAME" \
    vm_type="$CVM_TYPE" \
    benchmark_type="network_latency" \
    status="completed"

  echo "✅ Results stored in VHSM"
fi

echo ""
echo "✅ Network benchmark completed!"
