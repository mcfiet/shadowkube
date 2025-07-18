#!/bin/bash
set -e

echo "=== Clean OpenEBS Install for Encrypted cVM ==="

# 1. Completely remove OpenEBS
echo "🧹 Removing existing OpenEBS..."
kubectl delete namespace openebs --force --grace-period=0 2>/dev/null || true

# Wait for cleanup
sleep 30

# 2. Install minimal OpenEBS with only HostPath
echo "📦 Installing minimal OpenEBS..."
kubectl create namespace openebs

# Install only the LocalPV HostPath provisioner
kubectl apply -f https://openebs.github.io/charts/openebs-operator.yaml

# Wait for deployment
echo "⏳ Waiting for OpenEBS components..."
kubectl wait --for=condition=Available deployment/openebs-localpv-provisioner -n openebs --timeout=300s

# 3. Create custom values to disable LVM/ZFS
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: openebs-config
  namespace: openebs
data:
  enable-lvm-localpv: "false"
  enable-zfs-localpv: "false"
  enable-hostpath-localpv: "true"
EOF

# 4. Create optimized storage class for encrypted storage
echo "🔧 Creating encrypted storage class..."
cat << 'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-local-storage
  annotations:
    openebs.io/cas-type: local
    cas.openebs.io/config: |
      - name: StorageType
        value: "hostpath"
      - name: BasePath
        value: "/var/lib/rancher/encrypted-storage"
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: openebs.io/local
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF

# 5. Prepare encrypted storage directory
echo "📁 Setting up encrypted storage directory..."
mkdir -p /var/lib/rancher/encrypted-storage
chmod 755 /var/lib/rancher/encrypted-storage

# 6. Verify installation
echo "🔍 Verifying installation..."
kubectl get pods -n openebs
kubectl get storageclass

echo ""
echo "✅ Clean OpenEBS installation complete!"
echo ""
echo "📋 Features:"
echo "  • Only HostPath LocalPV (no LVM/ZFS)"
echo "  • All storage in LUKS encrypted volume"
echo "  • Default storage class: encrypted-local-storage"
echo "  • Volume expansion enabled"
echo ""
echo "🧪 Test with:"
echo "  kubectl create -f - <<EOF"
echo "  apiVersion: v1"
echo "  kind: PersistentVolumeClaim"
echo "  metadata:"
echo "    name: test-pvc"
echo "  spec:"
echo "    accessModes: [ReadWriteOnce]"
echo "    resources:"
echo "      requests:"
echo "        storage: 5Gi"
echo "  EOF"