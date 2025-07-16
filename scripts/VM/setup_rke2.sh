#!/usr/bin/env bash
set -euo pipefail

RKE2_DIR="/etc/rancher/rke2"
CNI="calico"

log() { echo -e "\n==> $*"; }
die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

# Public IP per Azure Metadata
get_public_ip() {
  curl "https://ipinfo.io/ip" ||
    die "Konnte Public IP nicht ermitteln"
}
SELF_PUBLIC_IP=$(get_public_ip)

install_rke2() {
  log "Installiere RKE2..."
  curl -sfL https://get.rke2.io | sh -
}

setup_master() {
  read -p "Interner Suffix Master [1]: " MSUF
  MSUF=${MSUF:-1}

  install_rke2
  mkdir -p "$RKE2_DIR"
  cat >"$RKE2_DIR/config.yaml" <<EOF
node-name: pos-${MSUF}
tls-san:
  - ${SELF_PUBLIC_IP}
node-ip: 10.100.0.${MSUF}
advertise-address: 10.100.0.${MSUF}
cni: ${CNI}
EOF

  systemctl enable rke2-server
  systemctl restart rke2-server

  log "kubectl permanent einrichten"
  mkdir -p ~/.kube
  sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
  sudo chown $(id -u):$(id -g) ~/.kube/config

  # Token auslesen
  RKE2_TOKEN=$(cat /var/lib/rancher/rke2/server/node-token)

  # Zusammenfassung
  echo -e "\n=== RKE2 Master Zusammenfassung ==="
  echo "Server Public IP:    $SELF_PUBLIC_IP"
  echo "Server interne IP:   10.100.0.${MSUF}"
  echo "RKE2 Server Token:   $RKE2_TOKEN"
  echo "kubectl ready – versuche: kubectl get nodes"
}

setup_worker() {
  read -p "Master interne IP (10.100.0.<MSUF>): " MIP
  read -p "RKE2-Token vom Master: " TOKEN
  read -p "Eigenes internes Suffix (z.B. 2): " USUF
  USUF=${USUF:-2}

  install_rke2
  mkdir -p "$RKE2_DIR"
  cat >"$RKE2_DIR/config.yaml" <<EOF
server: https://${MIP}:9345
token: ${TOKEN}
node-name: pos-${USUF}
node-ip: 10.100.0.${USUF}
cni: ${CNI}
EOF

  systemctl enable rke2-agent
  systemctl restart rke2-agent

  # Zusammenfassung
  echo -e "\n=== RKE2 Worker Zusammenfassung ==="
  echo "Dieser Node Public IP:  $SELF_PUBLIC_IP"
  echo "Dieser Node interne IP: 10.100.0.${USUF}"
  echo "Master interne IP:       ${MIP}"
  echo "RKE2 Token (used):       ${TOKEN}"
}

# --- Main ---
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."

echo "RKE2: Modus wählen: (1) Master  (2) Worker"
read -p "Eingabe [1/2]: " M
case "$M" in
1) setup_master ;;
2) setup_worker ;;
*) die "Ungültige Auswahl." ;;
esac
