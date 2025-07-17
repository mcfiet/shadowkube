#!/bin/bash
set -e
echo "🏗️ Starte initiales Setup"
cp scripts/cVM/*.sh /usr/local/bin/
chmod +x /usr/local/bin/*.sh

cp systemd/*.service /etc/systemd/system/
cp systemd/*.override.conf /etc/systemd/system/rke2-agent.service.d/ 2>/dev/null || true
cp systemd/*.override.conf /etc/systemd/system/rke2-server.service.d/ 2>/dev/null || true
cp systemd/*.override.conf /etc/systemd/system/wg-quick@wg0.service.d/ 2>/dev/null || true

systemctl daemon-reexec
systemctl daemon-reload

echo "✅ Basis-Setup abgeschlossen. Starte nun:"
echo "sudo /usr/local/bin/setup-cvm-enhanced.sh master|worker"
