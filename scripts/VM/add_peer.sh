#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
WG_PORT=51820

log() {
  echo -e "\n==> $*"
}
die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

# Prüfe root
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."

# Prüfe, ob WireGuard-Config existiert
[[ -f "$WG_CONF" ]] || die "Config $WG_CONF nicht gefunden. Führe zuerst das Basis-Setup aus."

# Eingabe Peer-Details
read -p "Peer PublicKey: " PEER_PUBKEY
read -p "Peer Public IP: " PEER_IP
read -p "Peer internes Suffix (z.B. 2): " PEER_SUFFIX
PEER_SUFFIX=${PEER_SUFFIX:-2}

# Anhängen der Peer-Definition
cat >>"$WG_CONF" <<EOF

[Peer]
PublicKey = ${PEER_PUBKEY}
Endpoint = ${PEER_IP}:${WG_PORT}
AllowedIPs = 10.100.0.${PEER_SUFFIX}/32
PersistentKeepalive = 25
EOF

# Neustart
log "Neustarte WireGuard Interface ${WG_IF}"
systemctl restart wg-quick@"${WG_IF}"

# Zusammenfassung
echo -e "\n=== Neuer Peer hinzugefügt ==="
echo "Peer PublicKey:    ${PEER_PUBKEY}"
echo "Peer Public IP:    ${PEER_IP}"
echo "Peer interne IP:   10.100.0.${PEER_SUFFIX}"
echo "Interface:         ${WG_IF}"
echo "Config-Datei:      ${WG_CONF}"
