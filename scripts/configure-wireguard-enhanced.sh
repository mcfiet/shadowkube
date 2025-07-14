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

if [ "$NODE_ROLE" = "master" ]; then
  WG_IP="10.0.0.1/24"
else
  NODE_NUM=$(echo $HOSTNAME | grep -o '[0-9]\+$' || echo "99")
  WG_IP="10.0.0.$NODE_NUM/24"
fi

echo "Wireguard IP: $WG_IP"
echo "Public Key: $WG_PUBLIC_KEY"

export VAULT_ADDR=https://vhsm.enclaive.cloud/
vault write -namespace=team-msc cubbyhole/cluster-nodes/$HOSTNAME-wg \
  public_key="$WG_PUBLIC_KEY" wireguard_ip="$WG_IP" node_ip="$NODE_IP" updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat >/etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = $WG_PRIVATE_KEY
Address = $WG_IP
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

WGEOF
echo "# Auto-discovered peers:" >>/etc/wireguard/wg0.conf

echo "Discovering active cluster nodes..."
DISCOVERED_PEERS=$(vault list -namespace=team-msc cubbyhole/cluster-nodes/ 2>/dev/null | grep -E '^[a-zA-Z0-9-]+$' | grep -v "$HOSTNAME" || true)

if [ -n "$DISCOVERED_PEERS" ]; then
  for peer in $DISCOVERED_PEERS; do
    PEER_INFO=$(vault read -namespace=team-msc -format=json cubbyhole/cluster-nodes/$peer-wg 2>/dev/null || echo "{}")
    if [ "$(echo $PEER_INFO | jq -r '.data')" != "null" ]; then
      KEY=$(echo $PEER_INFO | jq -r '.data.public_key')
      IP=$(echo $PEER_INFO | jq -r '.data.wireguard_ip' | cut -d'/' -f1)
      END=$(echo $PEER_INFO | jq -r '.data.node_ip')
      if [ "$KEY" != "null" ] && [ "$IP" != "null" ] && [ "$END" != "null" ]; then
        cat >>/etc/wireguard/wg0.conf <<PEEREOF
[Peer]
PublicKey = $KEY
AllowedIPs = $IP/32
Endpoint = $END:51820
PersistentKeepalive = 25

PEEREOF
      fi
    fi
  done
fi

chmod 600 /etc/wireguard/wg0.conf
echo "✅ Wireguard configured successfully"
