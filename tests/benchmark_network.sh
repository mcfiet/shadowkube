#!/bin/bash
set -e

# =============================================================================
# Network Latency Benchmark Script with Multi-Cloud Testing
# Tests: Inter-node latency, External connectivity, Bandwidth
# For multi-cloud Kubernetes cluster analysis
# =============================================================================

# VHSM Environment
export VAULT_ADDR=https://vhsm.enclaive.cloud/

NODE_NAME=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')

# Detect CVM type
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

echo "🌐 Network Latency Benchmark Suite"
echo "=================================="
echo "Node: $NODE_NAME ($CVM_TYPE VM)"
echo "IP: $NODE_IP"
echo ""

# Check VHSM connection
if command -v vault >/dev/null 2>&1 && vault token lookup >/dev/null 2>&1; then
    VHSM_AVAILABLE=true
    log "✅ VHSM connection verified"
else
    VHSM_AVAILABLE=false
    warn "VHSM not available - results will be stored locally only"
fi

# Cloud provider detection
detect_cloud_provider() {
    CLOUD_PROVIDER="unknown"
    CLOUD_REGION="unknown"
    
    if curl -s --max-time 3 http://169.254.169.254/metadata/instance >/dev/null 2>&1; then
        CLOUD_PROVIDER="azure"
        CLOUD_REGION=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01" 2>/dev/null || echo "unknown")
    elif curl -s --max-time 3 http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
        CLOUD_PROVIDER="aws"
        CLOUD_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "unknown")
    elif curl -s --max-time 3 http://metadata.google.internal/computeMetadata/v1/ -H "Metadata-Flavor: Google" >/dev/null 2>&1; then
        CLOUD_PROVIDER="gcp"
        CLOUD_REGION=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null | cut -d'/' -f4 || echo "unknown")
    fi
    
    log "☁️  Cloud Provider: $CLOUD_PROVIDER ($CLOUD_REGION)"
}

# =============================================================================
# Kubernetes Cluster Node Discovery
# =============================================================================

discover_cluster_nodes() {
    log "🔍 Discovering Kubernetes cluster nodes..."
    
    CLUSTER_NODES=""
    K8S_AVAILABLE=false
    
    if command -v kubectl >/dev/null 2>&1; then
        # Get all cluster nodes
        CLUSTER_NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
        
        if [ -n "$CLUSTER_NODES" ]; then
            K8S_AVAILABLE=true
            NODE_COUNT=$(echo $CLUSTER_NODES | wc -w)
            log "✅ Found $NODE_COUNT cluster nodes: $CLUSTER_NODES"
            
            # Get node details
            kubectl get nodes -o wide >/dev/null 2>&1 && {
                info "   Cluster node details:"
                kubectl get nodes -o custom-columns="NAME:.metadata.name,IP:.status.addresses[0].address,ROLE:.metadata.labels.node-role\.kubernetes\.io/master,PROVIDER:.spec.providerID" --no-headers | while read line; do
                    info "     $line"
                done
            }
        else
            warn "Kubernetes available but no nodes found"
        fi
    else
        warn "kubectl not available - skipping cluster node discovery"
    fi
}

# =============================================================================
# Inter-Node Latency Testing
# =============================================================================

test_cluster_latency() {
    log "🔗 Testing inter-node latency..."
    
    if [ "$K8S_AVAILABLE" = "false" ]; then
        warn "Kubernetes not available - skipping cluster latency tests"
        CLUSTER_LATENCY_RESULTS="[]"
        return
    fi
    
    CLUSTER_LATENCY_RESULTS="["
    FIRST=true
    
    for target_ip in $CLUSTER_NODES; do
        if [ "$target_ip" = "$NODE_IP" ]; then
            continue  # Skip self
        fi
        
        info "   Testing latency to cluster node $target_ip..."
        
        # Ping test with detailed statistics
        PING_RESULT=$(timeout 15 ping -c 10 -W 2 "$target_ip" 2>/dev/null || echo "")
        
        if [ -n "$PING_RESULT" ] && echo "$PING_RESULT" | grep -q "avg"; then
            PING_AVG=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' 2>/dev/null || echo "999")
            PING_MIN=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $4}' 2>/dev/null || echo "999")
            PING_MAX=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $6}' 2>/dev/null || echo "999")
            PING_STDDEV=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $7}' 2>/dev/null || echo "999")
            PACKET_LOSS=$(echo "$PING_RESULT" | grep "packet loss" | awk '{print $6}' | sed 's/%//' 2>/dev/null || echo "0")
        else
            PING_AVG="999"
            PING_MIN="999"
            PING_MAX="999"
            PING_STDDEV="999"
            PACKET_LOSS="100"
        fi
        
        # TCP connectivity test (port 22 - SSH, or 80/443)
        TCP_22_TEST="failed"
        TCP_80_TEST="failed"
        TCP_443_TEST="failed"
        
        if timeout 3 bash -c "</dev/tcp/$target_ip/22" 2>/dev/null; then
            TCP_22_TEST="success"
        fi
        if timeout 3 bash -c "</dev/tcp/$target_ip/80" 2>/dev/null; then
            TCP_80_TEST="success"
        fi
        if timeout 3 bash -c "</dev/tcp/$target_ip/443" 2>/dev/null; then
            TCP_443_TEST="success"
        fi
        
        # Get node name if possible
        NODE_NAME_TARGET=$(kubectl get nodes -o wide | grep "$target_ip" | awk '{print $1}' 2>/dev/null || echo "unknown")
        
        if [ "$FIRST" = "false" ]; then
            CLUSTER_LATENCY_RESULTS="$CLUSTER_LATENCY_RESULTS,"
        fi
        FIRST=false
        
        CLUSTER_LATENCY_RESULTS="$CLUSTER_LATENCY_RESULTS{\"target_ip\":\"$target_ip\",\"target_node\":\"$NODE_NAME_TARGET\",\"ping_avg_ms\":$PING_AVG,\"ping_min_ms\":$PING_MIN,\"ping_max_ms\":$PING_MAX,\"ping_stddev_ms\":$PING_STDDEV,\"packet_loss_percent\":$PACKET_LOSS,\"tcp_22\":\"$TCP_22_TEST\",\"tcp_80\":\"$TCP_80_TEST\",\"tcp_443\":\"$TCP_443_TEST\"}"
        
        log "     $NODE_NAME_TARGET ($target_ip): ${PING_AVG}ms avg, ${PACKET_LOSS}% loss"
    done
    
    CLUSTER_LATENCY_RESULTS="$CLUSTER_LATENCY_RESULTS]"
    
    log "✅ Cluster latency tests completed"
}

# =============================================================================
# External Connectivity Testing
# =============================================================================

test_external_connectivity() {
    log "🌍 Testing external connectivity..."
    
    # Define test targets by region/provider
    EXTERNAL_TARGETS=(
        "8.8.8.8:Google_DNS_Global"
        "1.1.1.1:Cloudflare_DNS_Global"
        "208.67.222.222:OpenDNS_Global"
        "9.9.9.9:Quad9_DNS_Global"
        "1.0.0.1:Cloudflare_Secondary"
    )
    
    # Add cloud-specific targets based on detected provider
    case $CLOUD_PROVIDER in
        "azure")
            EXTERNAL_TARGETS+=(
                "13.107.42.14:Microsoft_Global"
                "40.76.4.15:Azure_DNS"
            )
            ;;
        "aws")
            EXTERNAL_TARGETS+=(
                "205.251.242.103:AWS_Route53"
                "54.239.28.85:AWS_Global"
            )
            ;;
        "gcp")
            EXTERNAL_TARGETS+=(
                "216.239.32.10:Google_Public_DNS"
                "142.250.191.14:Google_Global"
            )
            ;;
    esac
    
    EXTERNAL_LATENCY_RESULTS="["
    FIRST=true
    
    for target_entry in "${EXTERNAL_TARGETS[@]}"; do
        IFS=':' read -r target_ip target_desc <<< "$target_entry"
        
        info "   Testing connectivity to $target_desc ($target_ip)..."
        
        # Ping test
        PING_RESULT=$(timeout 10 ping -c 5 -W 2
