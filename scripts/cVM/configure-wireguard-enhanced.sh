#!/bin/bash
set -e

echo "Configuring Wireguard with smart POS naming..."

if [ ! -f /run/cvm-secrets/wg.key ]; then
  echo "❌ Wireguard key not found"
  exit 1
fi

HOSTNAME=$(hostname)
NODE_ROLE=$(cat /run/cvm-secrets/node.role 2>/dev/null || echo "unknown")
WG_PRIVATE_KEY=$(cat /run/cvm-secrets/wg.key)
WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)
NODE_IP=$(hostname -I | awk '{print $1}')

export VAULT_ADDR=https://vhsm.enclaive.cloud/

# Smart POS naming: find the next available POS number
echo "Determining POS name for this node..."

# Check if this node already has a POS assignment
EXISTING_POS=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$HOSTNAME 2>/dev/null | jq -r '.data.pos_name // "null"' 2>/dev/null || echo "null")

if [ "$EXISTING_POS" != "null" ] && [ "$EXISTING_POS" != "" ]; then
    POS_NAME="$EXISTING_POS"
    echo "Found existing POS assignment: $POS_NAME"
else
    echo "No existing POS assignment found, determining new POS number..."
    
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
    NEXT_POS=1
    if [ "$NODE_ROLE" = "master" ]; then
        # Master always gets POS-1
        NEXT_POS=1
        POS_NAME="POS-1"
        echo "Assigning master node: $POS_NAME"
    else
        # For workers, find the next available number starting from 2
        NEXT_POS=2
        while echo " $USED_POS_NUMBERS " | grep -q " $NEXT_POS "; do
            NEXT_POS=$((NEXT_POS + 1))
        done
        POS_NAME="POS-$NEXT_POS"
        echo "Assigning worker node: $POS_NAME (next available after: $USED_POS_NUMBERS)"
    fi
fi

# Extract POS number for IP assignment
POS_NUM=$(echo $POS_NAME | grep -o '[0-9]\+$')

# Validate POS number is reasonable for IP assignment (1-254)
if [ "$POS_NUM" -gt 254 ]; then
    echo "❌ POS number $POS_NUM too high for IP assignment (max 254)"
    exit 1
fi

WG_IP="10.0.0.$POS_NUM/24"

echo "POS Assignment: $POS_NAME"
echo "Wireguard IP: $WG_IP"
echo "Public Key: $WG_PUBLIC_KEY"

# Store our information with POS assignment
vault write -namespace=team-msc cubbyhole/cluster-nodes/$HOSTNAME \
    attestation="$(cat /tmp/cvm-attestation.json 2>/dev/null || echo '{}')" \
    role="$NODE_ROLE" \
    internal_ip="$NODE_IP" \
    external_ip="$NODE_IP" \
    pos_name="$POS_NAME" \
    status="verified" \
    join_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Store Wireguard-specific info with POS name
vault write -namespace=team-msc cubbyhole/cluster-nodes/$HOSTNAME-wg \
    public_key="$WG_PUBLIC_KEY" \
    wireguard_ip="$WG_IP" \
    node_ip="$NODE_IP" \
    pos_name="$POS_NAME" \
    updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Also store under POS name for easy lookup
vault write -namespace=team-msc cubbyhole/cluster-pos/$POS_NAME \
    hostname="$HOSTNAME" \
    public_key="$WG_PUBLIC_KEY" \
    wireguard_ip="$WG_IP" \
    node_ip="$NODE_IP" \
    role="$NODE_ROLE" \
    updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Create base Wireguard config
cat >/etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = $WG_PRIVATE_KEY
Address = $WG_IP
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

WGEOF

echo "# Auto-discovered peers (POS-based discovery):" >>/etc/wireguard/wg0.conf

# Professional dynamic peer discovery using POS naming
echo "Discovering active cluster nodes via POS registry..."

# Get all POS entries
POS_ENTRIES=$(vault list -namespace=team-msc cubbyhole/cluster-pos/ 2>/dev/null || true)

if [ -z "$POS_ENTRIES" ]; then
    echo "No other POS nodes discovered yet"
else
    echo "Found POS entries: $(echo $POS_ENTRIES | tr '\n' ' ')"
    
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
                echo "Adding peer: $pos_entry ($PEER_HOSTNAME) - $PEER_ROLE at $PEER_NODE_IP -> $PEER_WG_IP"
                
                cat >>/etc/wireguard/wg0.conf <<PEEREOF
[Peer]
# $pos_entry: $PEER_HOSTNAME ($PEER_ROLE)
PublicKey = $PEER_PUBLIC_KEY
AllowedIPs = $PEER_WG_IP/32
Endpoint = $PEER_NODE_IP:51820
PersistentKeepalive = 25

PEEREOF
            else
                echo "Skipping $pos_entry - incomplete data"
            fi
        else
            echo "Skipping $pos_entry - no data found"
        fi
    done
fi

# Fallback: also check traditional hostname-based discovery for backwards compatibility
echo "Checking for legacy hostname-based nodes..."
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
                echo "Adding legacy peer: $legacy_node (no POS) at $PEER_NODE_IP -> $PEER_WG_IP"
                
                cat >>/etc/wireguard/wg0.conf <<PEEREOF
[Peer]
# Legacy: $legacy_node (no POS assignment)
PublicKey = $PEER_PUBLIC_KEY
AllowedIPs = $PEER_WG_IP/32
Endpoint = $PEER_NODE_IP:51820
PersistentKeepalive = 25

PEEREOF
            fi
        fi
    fi
done

chmod 600 /etc/wireguard/wg0.conf

# Show summary
PEER_COUNT=$(grep -c "^PublicKey" /etc/wireguard/wg0.conf || echo "0")
echo "✅ Wireguard configured successfully"
echo "   Hostname: $HOSTNAME"
echo "   POS Name: $POS_NAME"
echo "   Role: $NODE_ROLE" 
echo "   Public Key: $WG_PUBLIC_KEY"
echo "   Wireguard IP: $WG_IP"
echo "   Discovered peers: $PEER_COUNT"

# Optional: Show the final config (without private key)
echo
echo "=== Wireguard Configuration Summary ==="
grep -v "PrivateKey" /etc/wireguard/wg0.conf || true

echo
echo "=== POS Registry Status ==="
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
