#!/bin/bash
set -e

echo "Configuring Wireguard with dynamic peer discovery..."

if [ ! -f /run/cvm-secrets/wg.key ]; then
  echo "❌ Wireguard key not found"
  exit 1
fi

HOSTNAME=$(hostname)
NODE_ROLE=$(cat /run/cvm-secrets/node.role 2>/dev/null || echo "unknown")
WG_PRIVATE_KEY=$(cat /run/cvm-secrets/wg.key)
WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)
NODE_IP=$(hostname -I | awk '{print $1}')

# Determine Wireguard IP based on role and hostname
if [ "$NODE_ROLE" = "master" ]; then
  WG_IP="10.0.0.1/24"
else
  # Extract number from hostname (pos-2 -> 2, pos-3 -> 3, etc.) - NO +1!
  NODE_NUM=$(echo $HOSTNAME | grep -o '[0-9]\+$' || echo "99")
  # Use the actual node number directly for IP assignment
  WG_IP="10.0.0.$NODE_NUM/24"
fi

echo "Wireguard IP: $WG_IP"
echo "Public Key: $WG_PUBLIC_KEY"

# Store our public key in VHSM for other nodes
export VAULT_ADDR=https://vhsm.enclaive.cloud/
vault write -namespace=team-msc cubbyhole/cluster-nodes/$HOSTNAME-wg \
  public_key="$WG_PUBLIC_KEY" \
  wireguard_ip="$WG_IP" \
  node_ip="$NODE_IP" \
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

echo "# Auto-discovered peers:" >>/etc/wireguard/wg0.conf

# Professional dynamic peer discovery
echo "Discovering active cluster nodes..."

# Get list of all registered cluster nodes dynamically
DISCOVERED_PEERS=$(vault list -namespace=team-msc cubbyhole/cluster-nodes/ 2>/dev/null | grep -E '^[a-zA-Z0-9-]+$' | grep -v "$HOSTNAME" || true)

if [ -z "$DISCOVERED_PEERS" ]; then
  echo "No other cluster nodes discovered yet"
else
  echo "Found cluster nodes: $(echo $DISCOVERED_PEERS | tr '\n' ' ')"

  # Process each discovered node
  for peer_hostname in $DISCOVERED_PEERS; do
    # Check if this node has Wireguard info
    PEER_WG_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$peer_hostname-wg 2>/dev/null || echo "{}")

    if [ "$(echo $PEER_WG_INFO | jq -r '.data')" != "null" ]; then
      PEER_PUBLIC_KEY=$(echo $PEER_WG_INFO | jq -r '.data.public_key')
      PEER_WG_IP=$(echo $PEER_WG_INFO | jq -r '.data.wireguard_ip' | cut -d'/' -f1)
      PEER_NODE_IP=$(echo $PEER_WG_INFO | jq -r '.data.node_ip')

      # Validate that we got valid data
      if [ "$PEER_PUBLIC_KEY" != "null" ] && [ "$PEER_WG_IP" != "null" ] && [ "$PEER_NODE_IP" != "null" ]; then
        echo "Adding peer: $peer_hostname ($PEER_NODE_IP -> $PEER_WG_IP)"

        cat >>/etc/wireguard/wg0.conf <<PEEREOF
[Peer]
# Node: $peer_hostname
PublicKey = $PEER_PUBLIC_KEY
AllowedIPs = $PEER_WG_IP/32
Endpoint = $PEER_NODE_IP:51820
PersistentKeepalive = 25

PEEREOF
      else
        echo "Skipping $peer_hostname - incomplete Wireguard data"
      fi
    else
      echo "Skipping $peer_hostname - no Wireguard configuration found"
    fi
  done
fi

# Also check for nodes that might have been registered with -wg suffix directly
echo "Checking for additional Wireguard nodes..."
WG_NODES=$(vault list -namespace=team-msc cubbyhole/cluster-nodes/ 2>/dev/null | grep '\-wg$' | sed 's/-wg$//' | grep -v "$HOSTNAME" || true)

for wg_node in $WG_NODES; do
  # Skip if we already processed this node
  if echo "$DISCOVERED_PEERS" | grep -q "^$wg_node$"; then
    continue
  fi

  PEER_WG_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$wg_node-wg 2>/dev/null || echo "{}")

  if [ "$(echo $PEER_WG_INFO | jq -r '.data')" != "null" ]; then
    PEER_PUBLIC_KEY=$(echo $PEER_WG_INFO | jq -r '.data.public_key')
    PEER_WG_IP=$(echo $PEER_WG_INFO | jq -r '.data.wireguard_ip' | cut -d'/' -f1)
    PEER_NODE_IP=$(echo $PEER_WG_INFO | jq -r '.data.node_ip')

    if [ "$PEER_PUBLIC_KEY" != "null" ] && [ "$PEER_WG_IP" != "null" ] && [ "$PEER_NODE_IP" != "null" ]; then
      echo "Adding additional WG peer: $wg_node ($PEER_NODE_IP -> $PEER_WG_IP)"

      cat >>/etc/wireguard/wg0.conf <<PEEREOF
[Peer]
# Node: $wg_node (additional)
PublicKey = $PEER_PUBLIC_KEY
AllowedIPs = $PEER_WG_IP/32
Endpoint = $PEER_NODE_IP:51820
PersistentKeepalive = 25

PEEREOF
    fi
  fi
done

chmod 600 /etc/wireguard/wg0.conf

# Show summary
PEER_COUNT=$(grep -c "^PublicKey" /etc/wireguard/wg0.conf || echo "0")
echo "✅ Wireguard configured successfully"
echo "   Our hostname: $HOSTNAME"
echo "   Our role: $NODE_ROLE"
echo "   Our public key: $WG_PUBLIC_KEY"
echo "   Our Wireguard IP: $WG_IP"
echo "   Discovered peers: $PEER_COUNT"

# Optional: Show the final config (without private key)
echo
echo "=== Wireguard Configuration Summary ==="
grep -v "PrivateKey" /etc/wireguard/wg0.conf || true
EOF
