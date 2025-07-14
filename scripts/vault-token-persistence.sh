#!/bin/bash
set -e

export VAULT_ADDR=https://vhsm.enclaive.cloud/

# Check if token exists and is valid
if [ -f /root/.vault-token ]; then
  if vault token lookup >/dev/null 2>&1; then
    echo "✅ Vault token is valid"
    exit 0
  else
    echo "⚠️ Vault token expired"
  fi
else
  echo "⚠️ No vault token found"
fi

echo "❌ Vault re-authentication required!"
echo "Please run: vault login -address https://vhsm.enclaive.cloud/"
echo "Then restart services: sudo systemctl restart cvm-secrets-enhanced"
exit 1
