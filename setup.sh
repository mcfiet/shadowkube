#!/bin/bash
set -e
echo "🏗️ Start initial setup"
cp scripts/cVM/*.sh /usr/local/bin/
chmod +x /usr/local/bin/*.sh

cp systemd/*.service /etc/systemd/system/
cp systemd/*.override.conf /etc/systemd/system/rke2-agent.service.d/ 2>/dev/null || true
cp systemd/*.override.conf /etc/systemd/system/rke2-server.service.d/ 2>/dev/null || true
cp systemd/*.override.conf /etc/systemd/system/wg-quick@wg0.service.d/ 2>/dev/null || true

systemctl daemon-reexec
systemctl daemon-reload

echo "✅ Base setup completed. Now start:"
echo "sudo ./scripts/cVM/setup-cVM.sh master <VAULT-TOKEN>"
echo "or"
echo "sudo ./scripts/cVM/setup-cVM.sh worker <VAULT-TOKEN>"
