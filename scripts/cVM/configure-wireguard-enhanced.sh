#!/usr/bin/env bash
set -euo pipefail

echo "=== Enhanced Wireguard Configuration with POS Discovery ==="

# Configuration
WG_IF="wg0"
WG_DIR="/etc/wireguard"
WG_PORT=51820

# Logging functions
log() { echo -e "\n==> $*"; }
die() {
    echo -e "\n[ERROR] $*" >&2
    exit 1
}

# Check prerequisites
check_prerequisites() {
    # Check if we have required secrets
    if [ ! -f /run/cvm-secrets/wg.key ]; then
        die "Wireguard key not found in /run/cvm-secrets/wg.key"
    fi
    
    if [ ! -f /run/cvm-secrets/node.role ]; then
        die "Node role not found in /run/cvm-secrets/node.role"
    fi
    
    # Check if encrypted storage is mounted
    if ! mountpoint -q /var/lib/rancher >/dev/null 2>&1; then
        die "Encrypted storage not mounted. Run cvm-storage service first."
    fi
    
    # Check Vault access
    export VAULT_ADDR=https://vhsm.enclaive.cloud/
    if ! vault token lookup >/dev/null 2>&1; then
        die "Vault authentication failed. Please login first."
    fi
    
    log "Prerequisites check passed"
}

# Install Wireguard if needed
install_wireguard() {
    if command -v wg >/dev/null 2>&1; then
        log "Wireguard already installed, skipping installation"
        return 0
    fi
    
    log "Installing wireguard-tools..."
    zypper -n install wireguard-tools || die "Failed to install wireguard-tools"
    
    log "Wireguard installed successfully"
}

# Get network configuration
get_network_config() {
    HOSTNAME=$(hostname)
    NODE_ROLE=$(cat /run/cvm-secrets/node.role)
    NODE_IP=$(hostname -I | awk '{print $1}')
    
    # Try to get external IP
    EXTERNAL_IP=$(curl -s --connect-timeout 5 "https://ipinfo.io/ip" 2>/dev/null || echo "$NODE_IP")
    
    log "Network configuration:"
    log "  Hostname: $HOSTNAME"
    log "  Role: $NODE_ROLE"
    log "  Internal IP: $NODE_IP"
    log "  External IP: $EXTERNAL_IP"
}

# Get or assign POS name
get_pos_assignment() {
    log "Determining POS assignment..."
    
    # Check if this node already has a POS assignment
    EXISTING_POS=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$HOSTNAME 2>/dev/null | jq -r '.data.pos_name // "null"' 2>/dev/null || echo "null")
    
    if [ "$EXISTING_POS" != "null" ] && [ "$EXISTING_POS" != "" ]; then
        POS_NAME="$EXISTING_POS"
        log "Found existing POS assignment: $POS_NAME"
    else
        log "No existing POS assignment found, determining new POS number..."
        
        # Get all existing POS assignments
        ALL_NODES=$(vault list -namespace=team-msc cubbyhole/cluster-nodes/ 2>/dev/null | grep -E '^[a-zA-Z0-9-]+$' || true)
        
        # Extract all currently used POS numbers
        USED_POS_NUMBERS=""
        for node in $ALL_NODES; do
            NODE_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$node 2>/dev/null || echo "{}")
            if [ "$(echo $NODE_INFO | jq -r '.data')" != "null" ]; then
                NODE_POS=$(echo $NODE_INFO | jq -r '.data.pos_name // "null"' 2>/dev/null || echo "null")
                if [ "$NODE_POS" != "null" ] && [ "$NODE_POS" != "" ]; then
                    # Extract number from POS-X
                    POS_NUM=$(echo $NODE_POS | grep -o '[0-9]\+$' 2>/dev/null || echo "")
                    if [ "$POS_NUM" != "" ]; then
                        USED_POS_NUMBERS="$USED_POS_NUMBERS $POS_NUM"
                    fi
                fi
            fi
        done
        
        # Find the next available POS number
        if [ "$NODE_ROLE" = "master" ]; then
            # Master always gets POS-1
            POS_NAME="POS-1"
            log "Assigning master node: $POS_NAME"
        else
            # For workers, find the next available number starting from 2
            NEXT_POS=2
            while echo " $USED_POS_NUMBERS " | grep -q " $NEXT_POS "; do
                NEXT_POS=$((NEXT_POS + 1))
            done
            POS_NAME="POS-$NEXT_POS"
            log "Assigning worker node: $POS_NAME (used numbers: $USED_POS_NUMBERS)"
        fi
    fi
    
    # Extract POS number for IP assignment
    POS_NUM=$(echo $POS_NAME | grep -o '[0-9]\+$')
    
    # Validate POS number is reasonable for IP assignment (1-254)
    if [ "$POS_NUM" -gt 254 ]; then
        die "POS number $POS_NUM too high for IP assignment (max 254)"
    fi
    
    WG_IP="10.0.0.$POS_NUM/24"
    
    log "POS Assignment: $POS_NAME"
    log "Wireguard IP: $WG_IP"
}

# Setup Wireguard keys and configuration
setup_wireguard_config() {
    log "Setting up Wireguard configuration..."
    
    # Read private key from secrets
    WG_PRIVATE_KEY=$(cat /run/cvm-secrets/wg.key)
    WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)
    
    log "Wireguard Public Key: $WG_PUBLIC_KEY"
    
    # Create Wireguard directory (in encrypted storage via bind mount)
    mkdir -p "$WG_DIR"
    umask 077
    
    # Create base Wireguard configuration
    cat > "$WG_DIR/$WG_IF.conf" << EOF
[Interface]
PrivateKey = $WG_PRIVATE_KEY
Address = $WG_IP
ListenPort = $WG_PORT

# Firewall rules for forwarding
PostUp = iptables -A FORWARD -i $WG_IF -j ACCEPT; iptables -A FORWARD -o $WG_IF -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_IF -j ACCEPT; iptables -D FORWARD -o $WG_IF -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

EOF
    
    chmod 600 "$WG_DIR/$WG_IF.conf"
    
    log "Base Wireguard configuration created"
}

# Update Vault with our information
update_vault_registry() {
    log "Updating Vault registry..."
    
    # Update main node entry with POS assignment
    vault write -namespace=team-msc cubbyhole/cluster-nodes/$HOSTNAME \
        role="$NODE_ROLE" \
        internal_ip="$NODE_IP" \
        external_ip="$EXTERNAL_IP" \
        pos_name="$POS_NAME" \
        status="verified" \
        join_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    
    # Store Wireguard-specific info
    vault write -namespace=team-msc cubbyhole/cluster-nodes/$HOSTNAME-wg \
        public_key="$WG_PUBLIC_KEY" \
        wireguard_ip="$WG_IP" \
        node_ip="$NODE_IP" \
        pos_name="$POS_NAME" \
        updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    
    # Store under POS name for easy lookup
    vault write -namespace=team-msc cubbyhole/cluster-pos/$POS_NAME \
        hostname="$HOSTNAME" \
        public_key="$WG_PUBLIC_KEY" \
        wireguard_ip="$WG_IP" \
        node_ip="$NODE_IP" \
        role="$NODE_ROLE" \
        updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    
    log "Vault registry updated successfully"
}

# Discover and add peers
discover_and_add_peers() {
    log "Discovering and adding peers..."
    
    echo "# Auto-discovered peers (POS-based discovery):" >> "$WG_DIR/$WG_IF.conf"
    
    # Get all POS entries
    POS_ENTRIES=$(vault list -namespace=team-msc cubbyhole/cluster-pos/ 2>/dev/null || true)
    
    if [ -z "$POS_ENTRIES" ]; then
        log "No other POS nodes discovered yet"
        return 0
    fi
    
    log "Found POS entries: $(echo $POS_ENTRIES | tr '\n' ' ')"
    
    PEER_COUNT=0
    
    # Process each POS entry
    for pos_entry in $POS_ENTRIES; do
        # Skip our own POS entry
        if [ "$pos_entry" = "$POS_NAME" ]; then
            continue
        fi
        
        PEER_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-pos/$pos_entry 2>/dev/null || echo "{}")
        
        if [ "$(echo $PEER_INFO | jq -r '.data')" != "null" ]; then
            PEER_HOSTNAME=$(echo $PEER_INFO | jq -r '.data.hostname')
            PEER_PUBLIC_KEY=$(echo $PEER_INFO | jq -r '.data.public_key')
            PEER_WG_IP=$(echo $PEER_INFO | jq -r '.data.wireguard_ip' | cut -d'/' -f1)
            PEER_NODE_IP=$(echo $PEER_INFO | jq -r '.data.node_ip')
            PEER_ROLE=$(echo $PEER_INFO | jq -r '.data.role')
            
            # Validate that we got valid data
            if [ "$PEER_PUBLIC_KEY" != "null" ] && [ "$PEER_WG_IP" != "null" ] && [ "$PEER_NODE_IP" != "null" ]; then
                log "Adding peer: $pos_entry ($PEER_HOSTNAME) - $PEER_ROLE at $PEER_NODE_IP -> $PEER_WG_IP"
                
                cat >> "$WG_DIR/$WG_IF.conf" << EOF
[Peer]
# $pos_entry: $PEER_HOSTNAME ($PEER_ROLE)
PublicKey = $PEER_PUBLIC_KEY
AllowedIPs = $PEER_WG_IP/32
Endpoint = $PEER_NODE_IP:$WG_PORT
PersistentKeepalive = 25

EOF
                PEER_COUNT=$((PEER_COUNT + 1))
            else
                log "Skipping $pos_entry - incomplete data"
            fi
        else
            log "Skipping $pos_entry - no data found"
        fi
    done
    
    # Fallback: check for legacy hostname-based nodes
    log "Checking for legacy hostname-based nodes..."
    LEGACY_NODES=$(vault list -namespace=team-msc cubbyhole/cluster-nodes/ 2>/dev/null | grep -E '^[a-zA-Z0-9-]+$' | grep -v "$HOSTNAME" || true)
    
    for legacy_node in $LEGACY_NODES; do
        # Check if this node has Wireguard info but no POS assignment
        NODE_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$legacy_node 2>/dev/null || echo "{}")
        
        if [ "$(echo $NODE_INFO | jq -r '.data')" != "null" ]; then
            NODE_POS=$(echo $NODE_INFO | jq -r '.data.pos_name // "null"' 2>/dev/null || echo "null")
            
            # Skip if already has POS assignment (already processed above)
            if [ "$NODE_POS" != "null" ] && [ "$NODE_POS" != "" ]; then
                continue
            fi
            
            # Try to get Wireguard info for legacy node
            PEER_WG_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$legacy_node-wg 2>/dev/null || echo "{}")
            
            if [ "$(echo $PEER_WG_INFO | jq -r '.data')" != "null" ]; then
                PEER_PUBLIC_KEY=$(echo $PEER_WG_INFO | jq -r '.data.public_key')
                PEER_WG_IP=$(echo $PEER_WG_INFO | jq -r '.data.wireguard_ip' | cut -d'/' -f1)
                PEER_NODE_IP=$(echo $PEER_WG_INFO | jq -r '.data.node_ip')
                
                if [ "$PEER_PUBLIC_KEY" != "null" ] && [ "$PEER_WG_IP" != "null" ] && [ "$PEER_NODE_IP" != "null" ]; then
                    log "Adding legacy peer: $legacy_node (no POS) at $PEER_NODE_IP -> $PEER_WG_IP"
                    
                    cat >> "$WG_DIR/$WG_IF.conf" << EOF
[Peer]
# Legacy: $legacy_node (no POS assignment)
PublicKey = $PEER_PUBLIC_KEY
AllowedIPs = $PEER_WG_IP/32
Endpoint = $PEER_NODE_IP:$WG_PORT
PersistentKeepalive = 25

EOF
                    PEER_COUNT=$((PEER_COUNT + 1))
                fi
            fi
        fi
    done
    
    log "Added $PEER_COUNT peers to configuration"
}

# Enable and start Wireguard
start_wireguard() {
    log "Enabling and starting Wireguard..."
    
    # Enable Wireguard service
    systemctl enable wg-quick@$WG_IF.service
    
    # Start Wireguard
    systemctl restart wg-quick@$WG_IF.service
    
    # Wait a moment and check status
    sleep 2
    
    if systemctl is-active --quiet wg-quick@$WG_IF.service; then
        log "Wireguard started successfully"
    else
        die "Failed to start Wireguard service"
    fi
}

# Show summary and status
show_summary() {
    PEER_COUNT=$(grep -c "^PublicKey" "$WG_DIR/$WG_IF.conf" || echo "0")
    
    echo -e "\n=== Wireguard Configuration Complete ==="
    echo "🎯 Hostname: $HOSTNAME"
    echo "🏷️  POS Name: $POS_NAME"
    echo "🔧 Role: $NODE_ROLE"
    echo "🌐 External IP: $EXTERNAL_IP"
    echo "🔗 Wireguard IP: $WG_IP"
    echo "🔑 Public Key: $WG_PUBLIC_KEY"
    echo "👥 Discovered peers: $PEER_COUNT"
    echo "📁 Config stored in encrypted storage"
    
    # Show Wireguard status
    echo -e "\n=== Wireguard Status ==="
    wg show 2>/dev/null || echo "Wireguard not running or no peers connected yet"
    
    # Show POS registry
    echo -e "\n=== POS Registry Status ==="
    echo "Current POS assignments:"
    vault list -namespace=team-msc cubbyhole/cluster-pos/ 2>/dev/null | while read pos; do
        if [ "$pos" != "" ]; then
            INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-pos/$pos 2>/dev/null || echo "{}")
            if [ "$(echo $INFO | jq -r '.data')" != "null" ]; then
                HOSTNAME_INFO=$(echo $INFO | jq -r '.data.hostname')
                ROLE_INFO=$(echo $INFO | jq -r '.data.role')
                IP_INFO=$(echo $INFO | jq -r '.data.wireguard_ip')
                echo "  $pos: $HOSTNAME_INFO ($ROLE_INFO) -> $IP_INFO"
            fi
        fi
    done || echo "No POS assignments found"
    
    echo -e "\n💡 Next steps:"
    echo "  • Test connectivity: ping 10.0.0.1 (if master exists)"
    echo "  • Check peers: wg show"
    echo "  • View logs: journalctl -fu wg-quick@$WG_IF"
}

# Main execution
main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        die "Please run as root"
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Install Wireguard
    install_wireguard
    
    # Get network configuration
    get_network_config
    
    # Get or assign POS name
    get_pos_assignment
    
    # Setup Wireguard configuration
    setup_wireguard_config
    
    # Update Vault registry
    update_vault_registry
    
    # Discover and add peers
    discover_and_add_peers
    
    # Start Wireguard
    start_wireguard
    
    # Show summary
    show_summary
    
    log "Wireguard configuration complete!"
}

# Run main function
main "$@"