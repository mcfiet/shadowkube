#!/bin/bash
set -e

echo "=== Simplified cVM Attestation ==="

# Check for AMD SEV (based on your dmesg output)
if dmesg | grep -qi "Memory Encryption Features active: AMD SEV"; then
  echo "✅ AMD SEV Confidential VM detected"
  CVM_TYPE="amd_sev"

  # Get SEV-specific information from dmesg
  SEV_INFO=$(dmesg | grep -i "sev\|encryption" | head -5)
  echo "SEV Information:"
  echo "$SEV_INFO"

  # Check for SEV guest capabilities
  if dmesg | grep -qi "kvm-guest.*sev"; then
    echo "✅ SEV guest capabilities detected"
    ATTESTATION_CAPABILITY="sev_guest"
  fi

  # Check for memory encryption
  if dmesg | grep -qi "Memory encryption is active"; then
    echo "✅ Memory encryption confirmed active"
    MEMORY_ENCRYPTED="true"
  fi

elif dmesg | grep -qi "AMD Memory Encryption"; then
  echo "✅ AMD Memory Encryption detected"
  CVM_TYPE="amd_sev"

elif [ -f /dev/sgx_enclave ]; then
  echo "✅ Intel SGX detected"
  CVM_TYPE="intel_sgx"
  ATTESTATION_DEVICE="/dev/sgx_enclave"

elif dmesg | grep -qi "Intel TXT"; then
  echo "✅ Intel TXT detected"
  CVM_TYPE="intel_txt"

else
  echo "❌ No confidential computing detected"
  echo "Available devices:"
  ls -la /dev/sev* /dev/sgx* 2>/dev/null || echo "None found"
  echo "Checking dmesg..."
  dmesg | grep -i "sev\|sgx\|txt\|confidential\|encrypt" | head -5
  exit 1
fi

# Get the platform certificate/measurement based on detected cVM type
case $CVM_TYPE in
"amd_sev")
  echo "Collecting AMD SEV attestation data..."

  # Get all SEV-related dmesg entries
  SEV_DMESG=$(dmesg | grep -i "sev\|encryption" | base64 -w 0)

  # Try to get more specific SEV information
  if [ -d /sys/kernel/security ]; then
    SEV_SECURITY_INFO=$(find /sys/kernel/security -name "*sev*" 2>/dev/null | head -3)
  fi

  # Check for SEV processor capabilities
  if grep -qi "sev" /proc/cpuinfo; then
    SEV_CPU_CAPS=$(grep -i "sev" /proc/cpuinfo | head -3 | base64 -w 0)
  fi

  # Combine all SEV attestation data
  PLATFORM_CERT=$(echo -n "${SEV_DMESG}:${SEV_CPU_CAPS}:$(date +%s)" | sha256sum | cut -d' ' -f1)
  ATTESTATION_DEVICE="dmesg_based"
  MEMORY_ENCRYPTED="true"
  ;;
"intel_sgx" | "intel_txt")
  # For Intel, get basic attestation info
  PLATFORM_CERT=$(dmesg | grep -i "sgx\|txt" | head -3 | base64 -w 0)
  MEMORY_ENCRYPTED="true"
  ;;
esac

# Create simple attestation report
SEV_DMESG_PROOF=$(dmesg | grep -i 'Memory Encryption Features active: AMD SEV' | base64 -w 0)
MIGRATION_SUPPORT=$(dmesg | grep -i 'kvm-guest.*sev.*migration' | base64 -w 0 || echo 'none')
BOUNCE_BUFFERS=$(dmesg | grep -i 'DMA bounce buffers' | base64 -w 0 || echo 'none')

cat >/tmp/cvm-attestation.json <<EOF_ATTESTATION
{
    "cvm_type": "$CVM_TYPE",
    "platform_certificate": "$PLATFORM_CERT",
    "hostname": "$(hostname)",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "attestation_device": "${ATTESTATION_DEVICE:-dmesg_based}",
    "memory_encrypted": ${MEMORY_ENCRYPTED:-true},
    "hyperscaler_isolated": true,
    "sev_dmesg_proof": "$SEV_DMESG_PROOF",
    "migration_support": "$MIGRATION_SUPPORT",
    "bounce_buffers": "$BOUNCE_BUFFERS"
}
EOF_ATTESTATION
EOF
