#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_DIR="/etc/wireguard"
WG_PORT=51820
RKE2_DIR="/etc/rancher/rke2"
CNI="calico"

log() { echo -e "\n==> $*"; }
die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

# Azure-Metadata-IP
get_public_ip() {
  curl -fs -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" ||
    die "Public IP konnte nicht ermittelt werden"
}

install_wireguard() {
  log "Installiere wireguard-tools..."
  zypper -n install wireguard-tools
}

install_rke2() {
  log "Installiere RKE2..."
  curl -sfL https://get.rke2.io | sh -
}

ensure_keys() {
  mkdir -p "$WG_DIR"
  umask 077
  [[ -f "$WG_DIR/privatekey" ]] || wg genkey | tee "$WG_DIR/privatekey" | wg pubkey >"$WG_DIR/publickey"
  PRIVKEY=$(<"$WG_DIR/privatekey")
  PUBKEY=$(<"$WG_DIR/publickey")
}

init_wg() {
  install_wireguard
  local SUF=$1
  NODE_IP="10.100.0.${SUF}"
  ensure_keys
  cat >"$WG_DIR/$WG_IF.conf" <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $NODE_IP/24
ListenPort = $WG_PORT
EOF
  systemctl enable wg-quick@"$WG_IF"
  systemctl restart wg-quick@"$WG_IF"
  log "WireGuard-Interface $WG_IF mit $NODE_IP eingerichtet"
}

add_peer() {
  local PUB=$1 IP=$2 SUF=$3
  cat >>"$WG_DIR/$WG_IF.conf" <<EOF

[Peer]
PublicKey = $PUB
Endpoint = $IP:$WG_PORT
AllowedIPs = 10.100.0.${SUF}/32
PersistentKeepalive = 25
EOF
  systemctl restart wg-quick@"$WG_IF"
  log "Peer $IP (10.100.0.${SUF}) eingetragen"
}

setup_master() {
  read -p "Master public IP (leer für Azure-Metadata): " MASTER_IP
  MASTER_IP=${MASTER_IP:-$(get_public_ip)}
  read -p "Interner Suffix für Master [1]: " MSUF
  MSUF=${MSUF:-1}

  init_wg "$MSUF"

  install_rke2
  mkdir -p "$RKE2_DIR"
  cat >"$RKE2_DIR/config.yaml" <<EOF
node-name: pos-${MSUF}
tls-san:
  - ${MASTER_IP}
node-ip: 10.100.0.${MSUF}
advertise-address: 10.100.0.${MSUF}
cni: ${CNI}
EOF

  systemctl enable rke2-server && systemctl restart rke2-server
  ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
  mkdir -p ~/.kube && ln -sf /etc/rancher/rke2/rke2.yaml ~/.kube/config
  chown $(id -u):$(id -g) ~/.kube/config

  log "Master fertig. Jetzt Worker hinzufügen? (y/N)"
  read -r ADD
  [[ "$ADD" =~ ^[Yy]$ ]] || {
    log "Abbruch – Master bereit."
    return
  }

  while true; do
    read -p "Worker-Name (z.B. pos-2): " WNAME
    read -p "Worker public IP: " WIP
    read -p "Worker WireGuard PublicKey: " WPUB
    read -p "Worker internes Suffix (z.B. 2): " WSUF

    add_peer "$WPUB" "$WIP" "$WSUF"

    echo -n "Noch einen Worker? (y/N): "
    read -r MORE
    [[ "$MORE" =~ ^[Yy]$ ]] || break
  done

  log "Master-Setup abgeschlossen. Prüfe mit: kubectl get nodes"
}

setup_worker() {
  read -p "Master public IP: " MASTER_IP
  read -p "Master WireGuard PublicKey: " MPUB
  read -p "Interner Suffix Master [1]: " MSUF
  MSUF=${MSUF:-1}
  read -p "Eigenes internes Suffix (z.B. 2): " USUF
  USUF=${USUF:-2}
  read -p "RKE2-Token vom Master: " TOKEN

  init_wg "$USUF"

  add_peer "$MPUB" "$MASTER_IP" "$MSUF"

  install_rke2
  mkdir -p "$RKE2_DIR"
  cat >"$RKE2_DIR/config.yaml" <<EOF
server: https://${MASTER_IP}:9345
token: ${TOKEN}
node-name: pos-${USUF}
node-ip: 10.100.0.${USUF}
cni: ${CNI}
EOF

  systemctl enable rke2-agent && systemctl restart rke2-agent

  log "Worker fertig. Füge bitte auf dem Master folgende Zeilen in /etc/wireguard/${WG_IF}.conf ein und anschl. wg-quick restart:"
  cat <<EOP

# --- Peer für Worker pos-${USUF} ---
[Peer]
PublicKey = ${PUBKEY}
Endpoint = $(get_public_ip):${WG_PORT}
AllowedIPs = 10.100.0.${USUF}/32
PersistentKeepalive = 25
# -------------------------------
EOP

  log "Prüfe auf Master mit: kubectl get nodes"
}

# Haupt
[[ $EUID -eq 0 ]] || die "Bitte als root oder via sudo starten."
echo "Modus wählen: (1) Master  (2) Worker"
read -p "Eingabe [1/2]: " M
case "$M" in
1) setup_master ;;
2) setup_worker ;;
*) die "Ungültige Auswahl." ;;
esac
