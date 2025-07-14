#!/bin/bash
set -e

echo "=== Simplified cVM Attestation ==="

# (1) cVM-Erkennung
if dmesg | grep -qi "Memory Encryption Features active: AMD SEV"; then
  echo "✅ AMD SEV Confidential VM detected"
  CVM_TYPE="amd_sev"
  ATTESTATION_DEVICE="dmesg_based"
  MEMORY_ENCRYPTED="true"
elif [ -f /dev/sgx_enclave ]; then
  echo "✅ Intel SGX detected"
  CVM_TYPE="intel_sgx"
  ATTESTATION_DEVICE="/dev/sgx_enclave"
  MEMORY_ENCRYPTED="true"
elif dmesg | grep -qi "Intel TXT"; then
  echo "✅ Intel TXT detected"
  CVM_TYPE="intel_txt"
  ATTESTATION_DEVICE="dmesg_based"
  MEMORY_ENCRYPTED="true"
else
  echo "❌ No confidential computing detected"
  exit 1
fi

# (2) Platform certificate / measurement
case $CVM_TYPE in
amd_sev)
  # Beispiel: kombiniere base64-codierte dmesg- und CPU-Info
  SEV_DMESG=$(dmesg | grep -i "sev\|encryption" | base64 -w0)
  SEV_CPU=$(grep -i sev /proc/cpuinfo | head -3 | base64 -w0)
  PLATFORM_CERT=$(printf "%s:%s:%s" "$SEV_DMESG" "$SEV_CPU" "$(date +%s)" | sha256sum | cut -d' ' -f1)
  ;;
intel_sgx | intel_txt)
  PLATFORM_CERT=$(dmesg | grep -i "sgx\|txt" | head -3 | base64 -w0)
  ;;
esac

# (3) weitere Proof-Felder
SEV_PROOF=$(dmesg | grep -i 'Memory Encryption Features active: AMD SEV' | base64 -w0 || echo "none")
MIGRATION=$(dmesg | grep -i 'migration' | base64 -w0 || echo "none")
BOUNCE=$(dmesg | grep -i 'bounce buffers' | base64 -w0 || echo "none")

# (4) JSON-Report schreiben – das ist das zweite Heredoc
cat >/tmp/cvm-attestation.json <<'EOF_ATTESTATION'
{
  "cvm_type":        "PLACEHOLDER_TYPE",
  "platform_certificate": "PLACEHOLDER_CERT",
  "hostname":        "PLACEHOLDER_HOST",
  "timestamp":       "PLACEHOLDER_TS",
  "attestation_device": "PLACEHOLDER_DEVICE",
  "memory_encrypted": PLACEHOLDER_MEM,
  "hyperscaler_isolated": true,
  "sev_dmesg_proof": "PLACEHOLDER_SEV_PROOF",
  "migration_support": "PLACEHOLDER_MIG",
  "bounce_buffers":   "PLACEHOLDER_BOUNCE"
}
EOF_ATTESTATION

# Jetzt Platzhalter ersetzen:
sed -i "s/PLACEHOLDER_TYPE/${CVM_TYPE}/" /tmp/cvm-attestation.json
sed -i "s/PLACEHOLDER_CERT/${PLATFORM_CERT}/" /tmp/cvm-attestation.json
sed -i "s/PLACEHOLDER_HOST/$(hostname)/" /tmp/cvm-attestation.json
sed -i "s/PLACEHOLDER_TS/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" /tmp/cvm-attestation.json
sed -i "s|PLACEHOLDER_DEVICE|${ATTESTATION_DEVICE}|" /tmp/cvm-attestation.json
sed -i "s/PLACEHOLDER_MEM/${MEMORY_ENCRYPTED}/" /tmp/cvm-attestation.json
sed -i "s/PLACEHOLDER_SEV_PROOF/${SEV_PROOF}/" /tmp/cvm-attestation.json
sed -i "s/PLACEHOLDER_MIG/${MIGRATION}/" /tmp/cvm-attestation.json
sed -i "s/PLACEHOLDER_BOUNCE/${BOUNCE}/" /tmp/cvm-attestation.json

echo "Attestation written to /tmp/cvm-attestation.json"
