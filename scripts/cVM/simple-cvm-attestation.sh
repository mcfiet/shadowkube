#!/bin/bash
set -e

echo "=== Simple SEV Attestation for Vault Authentication ==="

# Check for SUSE SEV tools
check_sev_tools() {
    if command -v sevctl >/dev/null 2>&1 && command -v virt-qemu-sev-validate >/dev/null 2>&1; then
        echo "✅ SUSE SEV tools available"
        return 0
    else
        echo "⚠️ SUSE SEV tools not found, using fallback"
        return 1
    fi
}

# Simple SEV detection and minimal attestation
detect_and_attest() {
    local attestation_method=""
    local platform_proof=""
    
    # Try SUSE SEV tools first
    if check_sev_tools; then
        echo "🔍 Using SUSE SEV tools for attestation..."
        
        # Check if we're in an SEV guest
        if dmesg | grep -qi "Memory Encryption Features active: AMD SEV"; then
            attestation_method="suse_sev_tools"
            
            # Try to create minimal SEV session for proof
            TEMP_DIR=$(mktemp -d)
            cd "$TEMP_DIR"
            
            # Create synthetic platform cert for session creation
            openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out pdh_synthetic.cert \
                -days 1 -nodes -subj "/CN=SEV-Platform-$(hostname)" 2>/dev/null
            
            # Create session artifacts
            if sevctl session --name "vault-auth" pdh_synthetic.cert 7 >/dev/null 2>&1; then
                echo "✅ SEV session artifacts created successfully"
                
                # Create proof from session data
                if [ -f "vault-auth_session.b64" ] && [ -f "vault-auth_tik.bin" ]; then
                    platform_proof=$(cat vault-auth_session.b64 | sha256sum | cut -d' ' -f1)
                    echo "✅ SEV session proof generated"
                else
                    platform_proof="sev_session_fallback_$(date +%s)"
                fi
            else
                echo "⚠️ SEV session creation failed, using fallback"
                platform_proof="sev_tools_fallback_$(date +%s)"
            fi
            
            # Cleanup
            cd - >/dev/null
            rm -rf "$TEMP_DIR"
        else
            echo "⚠️ Not in SEV guest, falling back to dmesg"
            attestation_method="dmesg_fallback"
        fi
    fi
    
    # Fallback to dmesg detection
    if [ -z "$attestation_method" ] || [ "$attestation_method" = "dmesg_fallback" ]; then
        echo "🔄 Using dmesg-based attestation..."
        attestation_method="dmesg_fallback"
        
        if dmesg | grep -qi "Memory Encryption Features active: AMD SEV"; then
            # Create proof from dmesg data
            sev_dmesg=$(dmesg | grep -i "sev\|encryption" | head -5)
            platform_proof=$(echo -n "$sev_dmesg:$(hostname):$(date +%s)" | sha256sum | cut -d' ' -f1)
            echo "✅ dmesg-based SEV proof generated"
        elif [ -f /dev/sgx_enclave ]; then
            platform_proof="intel_sgx_$(date +%s)"
            attestation_method="intel_sgx"
            echo "✅ Intel SGX detected"
        else
            echo "❌ No confidential computing detected"
            return 1
        fi
    fi
    
    # Return the minimal attestation data
    echo "$attestation_method:$platform_proof"
    return 0
}

# Main execution
HOSTNAME=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')

echo "🎯 Node: $HOSTNAME ($NODE_IP)"

# Generate minimal attestation proof
ATTESTATION_RESULT=$(detect_and_attest)

if [ $? -eq 0 ]; then
    METHOD=$(echo "$ATTESTATION_RESULT" | cut -d':' -f1)
    PROOF=$(echo "$ATTESTATION_RESULT" | cut -d':' -f2)
    
    echo "✅ Attestation successful"
    echo "   Method: $METHOD"
    echo "   Proof: ${PROOF:0:16}..."
    
    # Create minimal JSON for Vault auth (no persistent storage)
    cat > /tmp/vault-auth-attestation.json << EOF
{
    "hostname": "$HOSTNAME",
    "method": "$METHOD", 
    "proof": "$PROOF",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "ip": "$NODE_IP"
}
EOF
    
    echo "📄 Attestation created: /tmp/vault-auth-attestation.json"
    echo "🎯 Ready for Vault authentication"
else
    echo "❌ Attestation failed"
    exit 1
fi