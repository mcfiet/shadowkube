#!/usr/bin/env bash
set -euo pipefail

OPENEBS_NAMESPACE="openebs"
LOCAL_PATH="/var/openebs/local"
HELM_SCRIPT_URL="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"

log() { echo -e "\n==> $*"; }
die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

# --- 1. Local PV Pfad anlegen ---
prepare_local_path() {
  log "Erstelle lokalen Pfad für OpenEBS: $LOCAL_PATH"
  mkdir -p "$LOCAL_PATH"
  chown -R 1000:1000 "$(dirname "$LOCAL_PATH")"
}

# --- 2. Helm installieren / erkennen ---
install_helm() {
  # Stelle sicher, dass /usr/local/bin im PATH ist (für sudo-Umgebungen)
  export PATH="/usr/local/bin:$PATH"

  if command -v helm >/dev/null 2>&1; then
    log "Helm bereits installiert unter: $(command -v helm)"
  else
    log "Helm nicht gefunden – lade Installationsskript"
    curl -fsSL -o get_helm.sh "$HELM_SCRIPT_URL"
    chmod +x get_helm.sh
    log "Installiere Helm nach /usr/local/bin"
    ./get_helm.sh
    rm -f get_helm.sh

    # Erneut PATH setzen, falls nötig
    export PATH="/usr/local/bin:$PATH"

    if ! command -v helm >/dev/null 2>&1; then
      die "Helm-Installation fehlgeschlagen: helm nicht im PATH"
    fi

    log "Helm erfolgreich installiert: $(command -v helm)"
  fi
}

# --- 3. OpenEBS via Helm deployen ---
install_openebs() {
  log "Füge OpenEBS Helm-Repo hinzu"
  helm repo add openebs https://openebs.github.io/openebs
  helm repo update

  read -p "Replicated Storage (Mayastor) deaktivieren? (y/N): " DISABLE_REPL
  if [[ "$DISABLE_REPL" =~ ^[Yy]$ ]]; then
    REPL_OPT="--set engines.replicated.mayastor.enabled=false"
  else
    REPL_OPT=""
  fi

  read -p "CSI VolumeSnapshots-CRDs überspringen? (y/N): " SKIP_SNAP
  if [[ "$SKIP_SNAP" =~ ^[Yy]$ ]]; then
    SNAP_OPT="--set openebs-crds.csi.volumeSnapshots.enabled=false"
  else
    SNAP_OPT=""
  fi

  log "Installiere OpenEBS im Namespace '$OPENEBS_NAMESPACE'"
  helm install openebs \
    --namespace "$OPENEBS_NAMESPACE" \
    openebs/openebs \
    --create-namespace \
    $REPL_OPT $SNAP_OPT
}

# --- 5. Warte bis OpenEBS-Pods laufen ---
wait_for_pods() {
  log "Warte auf Ready-Status aller Pods im Namespace '$OPENEBS_NAMESPACE' (bis 5 Minuten)"
  kubectl -n "$OPENEBS_NAMESPACE" wait \
    --for=condition=Ready pods --all --timeout=300s
}

# --- 6. Zusammenfassung ausgeben ---
print_summary() {
  echo -e "\n=== OpenEBS Installation abgeschlossen ==="
  echo "Local PV Pfad:         $LOCAL_PATH"
  echo "OpenEBS Namespace:     $OPENEBS_NAMESPACE"
  echo "StorageClass Name:     openebs-hostpath"
  echo "Replicated Storage:    ${DISABLE_REPL:-no}"
  echo "Snapshots CRDs skip:   ${SKIP_SNAP:-no}"
  echo
  echo "Status prüfen mit:"
  echo "  kubectl -n $OPENEBS_NAMESPACE get pods"
  echo
  echo "Test-PVC & Pod wie folgt deployen:"
  echo "  kubectl apply -f pvc.yaml"
  echo "  kubectl apply -f pod.yaml"
}

# --- Main ---
[[ $EUID -eq 0 ]] || die "Bitte als root oder via sudo ausführen."

prepare_local_path
install_helm
install_openebs
wait_for_pods
print_summary
