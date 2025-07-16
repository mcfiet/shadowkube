#!/usr/bin/env bash
set -euo pipefail

CNPG_VERSION="release-1.26"
CNPG_YAML_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-1.26.0.yaml"

log() { echo -e "\n==> $*"; }
die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

# Prüft, ob kubectl konfiguriert ist
kubectl version --client &>/dev/null || die "kubectl nicht gefunden oder nicht konfiguriert."

# 1. Installiere die CRDs und Controller
install_cnpg() {
  log "Installiere CloudNativePG (${CNPG_VERSION}) CRDs und Controller"
  kubectl apply --server-side -f "$CNPG_YAML_URL"

  log "Warte auf den cnpg-controller-manager im Namespace cnpg-system"
  # Warte bis das Deployment bereit ist
  kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=180s
  # Optional: Warte auf alle Pods im System-Namespace
  kubectl -n cnpg-system wait --for=condition=Ready pods --all --timeout=180s
}

# 2. Namespace erstellen
create_namespace() {
  if kubectl get ns "$NS" &>/dev/null; then
    log "Namespace '$NS' existiert bereits"
  else
    log "Erstelle Namespace '$NS'"
    kubectl create namespace "$NS"
  fi
}

# 3. Erzeuge cluster.yaml und apply
create_cluster() {
  log "Erzeuge cluster.yaml"
  cat >cluster.yaml <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NS}
spec:
  instances: ${INSTANCES}
  storage:
    storageClass: ${STORAGE_CLASS}
    size: ${SIZE}
EOF

  log "Apply cluster.yaml"
  kubectl apply -f cluster.yaml
}

# 4. Optional: cnpg-plugin installieren
install_plugin() {
  read -p "CloudNativePG kubectl-Plugin installieren? (y/N): " PLUG
  if [[ "$PLUG" =~ ^[Yy]$ ]]; then
    log "Installiere cnpg-Plugin"
    curl -sSfL \
      https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh |
      sudo sh -s -- -b /usr/local/bin
  fi
}

# 5. Auf Running warten
wait_for_pods() {
  log "Warte auf Running-Status der Pods im Namespace '$NS'"
  kubectl -n "$NS" wait --for=condition=Ready pods --all --timeout=600s
}

# 6. Zusammenfassung
print_summary() {
  echo -e "\n=== CloudNativePG Zusammenfassung ==="
  echo "Cluster-Name:     $CLUSTER_NAME"
  echo "Namespace:        $NS"
  echo "Instanzen:        $INSTANCES"
  echo "StorageClass:     $STORAGE_CLASS"
  echo "Volumengröße:     $SIZE"
  echo
  echo "Prüfe Status mit:"
  echo "  kubectl get cluster -n $NS"
  echo "  kubectl get pods -n $NS"
  echo "  kubectl get pvc -n $NS"
  echo
  echo "Optional Benchmark mit pgbench:"
  echo "  kubectl cnpg pgbench --job-name pgbench-init $CLUSTER_NAME -- --initialize --scale 10"
}

# --- Main ---
echo "=== CloudNativePG Installer ==="
read -p "Cluster-Name [cluster-example]: " CLUSTER_NAME
CLUSTER_NAME=${CLUSTER_NAME:-cluster-example}
read -p "Namespace [postgresql]: " NS
NS=${NS:-postgresql}
read -p "Anzahl Instanzen [3]: " INSTANCES
INSTANCES=${INSTANCES:-3}
read -p "StorageClass [openebs-hostpath]: " STORAGE_CLASS
STORAGE_CLASS=${STORAGE_CLASS:-openebs-hostpath}
read -p "Volumengröße [1Gi]: " SIZE
SIZE=${SIZE:-1Gi}

install_cnpg
create_namespace
create_cluster
install_plugin
wait_for_pods
print_summary
