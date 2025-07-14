#!/bin/bash
set -e

echo "=== cVM Auto-Start After Reboot ==="

# 1) Warten auf Netzwerk
echo "Waiting for network connectivity..."
for i in {1..30}; do
  if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "✅ Network available"
    break
  fi
  sleep 2
done

# 2) Vault-Token prüfen
export VAULT_ADDR=https://vhsm.enclaive.cloud/
echo "Checking VAULT authentication..."
if ! vault token lookup >/dev/null 2>&1; then
  echo "❌ VAULT token invalid or missing!"
  echo "Manual intervention required:"
  echo " 1) vault login -address=https://vhsm.enclaive.cloud/"
  echo " 2) sudo systemctl restart cvm-secrets-enhanced"
  exit 1
fi
echo "✅ VAULT token valid"

# 3) Core‐Services starten
echo "Starting core cVM services..."
sudo systemctl start cvm-secrets-enhanced.service
sudo systemctl start cvm-storage.service

# Kurz warten
sleep 5

# 4) Netzwerk neu konfigurieren
echo "Reconfiguring Wireguard..."
sudo /usr/local/bin/configure-wireguard-enhanced.sh

# 5) RKE2‐Konfiguration prüfen
echo "Checking RKE2 configuration..."
if [ -f /run/cvm-secrets/node.role ]; then
  NODE_ROLE=$(cat /run/cvm-secrets/node.role)

  if [ "$NODE_ROLE" = "worker" ]; then
    CURRENT_MASTER=$(grep "server:" /etc/rancher/rke2/config.yaml | cut -d'/' -f3 | cut -d':' -f1 2>/dev/null || echo "unknown")
    NEW_MASTER=$(cat /run/cvm-secrets/master.ip 2>/dev/null || echo "unknown")
    if [ "$CURRENT_MASTER" != "$NEW_MASTER" ] && [ "$NEW_MASTER" != "unknown" ]; then
      echo "Master IP changed: $CURRENT_MASTER -> $NEW_MASTER"
      sudo /usr/local/bin/configure-rke2-enhanced.sh
    fi
  fi
fi

# 6) Wireguard starten
echo "Starting Wireguard..."
sudo systemctl start wg-quick@wg0

# 7) Kubernetes starten
echo "Starting Kubernetes..."
if [ "$NODE_ROLE" = "master" ]; then
  sudo systemctl start rke2-server.service 2>/dev/null || echo "RKE2 server not available"
else
  sudo systemctl start rke2-agent.service 2>/dev/null || echo "RKE2 agent not available"
fi

echo "✅ cVM auto-start completed"
