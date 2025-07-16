#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_DIR="/etc/wireguard"
WG_PORT=51820

log() { echo -e "\n==> $*"; }
die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

# --- Public IP per Azure Metadata ---
get_public_ip() {
  curl "https://ipinfo.io/ip" ||
    die "Konnte Public IP nicht ermitteln"
}
SELF_PUBLIC_IP=$(get_public_ip)

install_wireguard() {
  log "Installiere wireguard-tools..."
  zypper -n install wireguard-tools
}

ensure_keys() {
  mkdir -p "$WG_DIR"
  umask 077
  [[ -f "$WG_DIR/privatekey" ]] || wg genkey | tee "$WG_DIR/privatekey" | wg pubkey >"$WG_DIR/publickey"
  PRIVKEY=$(<"$WG_DIR/privatekey")
  PUBKEY=$(<"$WG_DIR/publickey")
}

init_interface() {
  install_wireguard
  read -p "Interner Suffix für diesen Node (z.B. 1): " SUF
  SUF=${SUF:-1}
  ensure_keys
  NODE_IP="10.100.0.${SUF}"
  cat >"$WG_DIR/$WG_IF.conf" <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $NODE_IP/24
ListenPort = $WG_PORT
EOF
  systemctl enable wg-quick@"$WG_IF"
  systemctl restart wg-quick@"$WG_IF"
  log "Interface $WG_IF mit $NODE_IP eingerichtet"
}

add_peer() {
  read -p "Peer PublicKey: " PUB
  read -p "Peer Public IP: " IP
  read -p "Peer internes Suffix (z.B. 2): " PSUF
  PSUF=${PSUF:-2}
  cat >>"$WG_DIR/$WG_IF.conf" <<EOF

[Peer]
PublicKey = $PUB
Endpoint = $IP:$WG_PORT
AllowedIPs = 10.100.0.${PSUF}/32
PersistentKeepalive = 25
EOF
  systemctl restart wg-quick@"$WG_IF"
  log "Peer $IP (10.100.0.${PSUF}) eingetragen"
}

# --- Main ---
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."

init_interface

echo -n "Möchtest du Peers hinzufügen? (y/N): "
read -r ADD
if [[ "$ADD" =~ ^[Yy]$ ]]; then
  while true; do
    add_peer
    echo -n "Noch einen Peer? (y/N): "
    read -r MORE
    [[ "$MORE" =~ ^[Yy]$ ]] || break
  done
fi

# --- Zusammenfassung ---
echo -e "\n=== WireGuard Zusammenfassung ==="
echo "Server Public IP:   $SELF_PUBLIC_IP"
echo "Server interne IP:  $NODE_IP"
echo "WireGuard PublicKey: $PUBKEY"
