PREFIX ?= /usr/local
SCRIPTS := \
  simple-cvm-attestation.sh \
  vhsm-cvm-auth-enhanced.sh \
  configure-wireguard-enhanced.sh \
  configure-rke2-enhanced.sh \
  setup-cvm-enhanced.sh \
  vault-token-persistence.sh \
  cvm-autostart.sh

SYSTEMD_UNITS := \
  cvm-secrets-enhanced.service \
  cvm-storage.service \
  cvm-autostart.service

override_dir := override

install:
	@echo "→ Installing scripts to $(PREFIX)/bin"
	install -d $(PREFIX)/bin
	@for s in $(SCRIPTS); do \
	  install -m 755 scripts/$$s $(PREFIX)/bin/$$s; \
	done

	@echo "→ Installing systemd unit files"
	install -d /etc/systemd/system
	@for u in $(SYSTEMD_UNITS); do \
	  install -m 644 systemd/$$u /etc/systemd/system/$$u; \
	done

	@echo "→ Installing systemd override snippets"
	install -d /etc/systemd/system/rke2-agent.service.d
	install -d /etc/systemd/system/rke2-server.service.d
	install -d /etc/systemd/system/wg-quick@wg0.service.d
	install -m 644 systemd/override/rke2-agent.conf  /etc/systemd/system/rke2-agent.service.d/override.conf
	install -m 644 systemd/override/rke2-server.conf /etc/systemd/system/rke2-server.service.d/override.conf
	install -m 644 systemd/override/wg-quick@wg0.conf /etc/systemd/system/wg-quick@wg0.service.d/override.conf

	@echo "→ Reloading systemd"
	systemctl daemon-reload
	@echo "✅ Installation complete"

uninstall:
	@echo "→ Removing scripts"
	@for s in $(SCRIPTS); do rm -f $(PREFIX)/bin/$$s; done

	@echo "→ Removing systemd units"
	@for u in $(SYSTEMD_UNITS); do rm -f /etc/systemd/system/$$u; done

	@echo "→ Removing override snippets"
	rm -rf /etc/systemd/system/rke2-agent.service.d
	rm -rf /etc/systemd/system/rke2-server.service.d
	rm -rf /etc/systemd/system/wg-quick@wg0.service.d

	@echo "→ Reloading systemd"
	systemctl daemon-reload
	@echo "✅ Uninstallation complete"

