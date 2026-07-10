#!/usr/bin/env bash
# Full OpenShift/Kubernetes cleanup for Option D (external Ceph + ceph-external-zone-nr).
# Run BEFORE reset-ceph-zones.sh on the Ceph admin node.
#
# Usage:
#   CONFIRM=yes ./06-cleanup-external-ceph.sh
#   CONFIRM=yes FULL=true ./06-cleanup-external-ceph.sh
#
# FULL=true enables: DELETE_CSIDRIVER, STRIP_ZONE_LABELS, DELETE_CSI_CLUSTER_RBACS
#
# Environment:
#   KUBE_CMD=oc|kubectl
#   NAMESPACE, SC_NAME, CSI_NS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=topology/zones.env
source "${SCRIPT_DIR}/topology/zones.env"

KUBE="${KUBE_CMD:-oc}"
NAMESPACE="${NAMESPACE:-pg-multizone}"
SC_NAME="${SC_NAME:-ceph-external-zone-nr}"
CSI_NS="${CSI_NS:-external-ceph-csi}"
FULL="${FULL:-false}"
DELETE_CSIDRIVER="${DELETE_CSIDRIVER:-false}"
STRIP_ZONE_LABELS="${STRIP_ZONE_LABELS:-false}"
DELETE_CSI_CLUSTER_RBACS="${DELETE_CSI_CLUSTER_RBACS:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

if [[ "$FULL" == "true" ]]; then
  DELETE_CSIDRIVER=true
  STRIP_ZONE_LABELS=true
  DELETE_CSI_CLUSTER_RBACS=true
fi

if [[ "${CONFIRM:-}" != "yes" ]]; then
  echo "❌  Refusing to run without CONFIRM=yes" >&2
  echo "    This deletes namespaces, PVCs, StorageClass, and optional CSI cluster objects." >&2
  echo "    Example: CONFIRM=yes FULL=true ./06-cleanup-external-ceph.sh" >&2
  exit 1
fi

echo "🧹  Kubernetes/OpenShift external-Ceph cleanup (FULL=${FULL})"

# --- PVCs using our StorageClass (any namespace) ---
mapfile -t PVC_LINES < <(
  $KUBE get pvc -A -o json 2>/dev/null \
    | jq -r --arg sc "$SC_NAME" \
      '.items[] | select(.spec.storageClassName == $sc) | "\(.metadata.namespace) \(.metadata.name)"' \
    || true
)

if [[ ${#PVC_LINES[@]} -gt 0 ]]; then
  echo "🗑️  Deleting PVCs bound to ${SC_NAME}..."
  for line in "${PVC_LINES[@]}"; do
    [[ -z "$line" ]] && continue
    ns=$(awk '{print $1}' <<<"$line")
    name=$(awk '{print $2}' <<<"$line")
    echo "    ${ns}/${name}"
    $KUBE delete pvc -n "$ns" "$name" --timeout="${WAIT_TIMEOUT}s" --ignore-not-found
  done
fi

# --- Workload namespaces ---
for ns in "$NAMESPACE" sc-test; do
  if $KUBE get namespace "$ns" &>/dev/null; then
    echo "🗑️  Deleting namespace ${ns}..."
    $KUBE delete namespace "$ns" --timeout="${WAIT_TIMEOUT}s" --ignore-not-found
  fi
done

# --- StorageClass (after PVCs) ---
if $KUBE get storageclass "$SC_NAME" &>/dev/null; then
  echo "🗑️  Deleting StorageClass ${SC_NAME}..."
  $KUBE delete storageclass "$SC_NAME" --ignore-not-found
fi

# --- CSI namespace (Deployment, DaemonSet, secrets, ConfigMap, PSA labels) ---
if $KUBE get namespace "$CSI_NS" &>/dev/null; then
  echo "🗑️  Deleting namespace ${CSI_NS} (CSI workloads, secrets, ceph-csi-config)..."
  $KUBE delete namespace "$CSI_NS" --timeout="${WAIT_TIMEOUT}s" --ignore-not-found
fi

# --- Orphan PVs (Released / Available) from our SC ---
mapfile -t ORPHAN_PVS < <(
  $KUBE get pv -o json 2>/dev/null \
    | jq -r --arg sc "$SC_NAME" \
      '.items[] | select(.spec.storageClassName == $sc) | select(.status.phase == "Released" or .status.phase == "Available") | .metadata.name' \
    || true
)
for pv in "${ORPHAN_PVS[@]}"; do
  [[ -z "$pv" ]] && continue
  echo "🗑️  Deleting orphan PV ${pv}..."
  $KUBE delete pv "$pv" --ignore-not-found
done

# --- Cluster-scoped CSI RBAC (upstream Ceph-CSI names) ---
if [[ "$DELETE_CSI_CLUSTER_RBACS" == "true" ]]; then
  echo "🗑️  Removing Ceph-CSI cluster RBAC (if present)..."
  for crb in \
    rbd-external-provisioner-runner \
    rbd-external-nodeplugin-runner \
    rbd-csi-nodeplugin-role-cfg \
    rbd-csi-provisioner-role-cfg
  do
    $KUBE delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
  done
  for cr in \
    rbd-external-provisioner-runner \
    rbd-external-nodeplugin-runner \
    rbd-csi-provisioner-role \
    rbd-csi-nodeplugin-role
  do
    $KUBE delete clusterrole "$cr" --ignore-not-found 2>/dev/null || true
  done
  echo "✅  Cluster RBAC cleanup attempted"
fi

# --- CSIDriver ---
if [[ "$DELETE_CSIDRIVER" == "true" ]]; then
  if $KUBE get csidriver rbd.csi.ceph.com &>/dev/null; then
    echo "🗑️  Deleting CSIDriver rbd.csi.ceph.com..."
    $KUBE delete csidriver rbd.csi.ceph.com --ignore-not-found
  fi
else
  echo "ℹ️  Keeping CSIDriver rbd.csi.ceph.com (FULL=true or DELETE_CSIDRIVER=true to remove)"
fi

# --- Node zone labels ---
if [[ "$STRIP_ZONE_LABELS" == "true" ]]; then
  echo "🏷️  Removing ${K8S_ZONE_LABEL} from all nodes..."
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    $KUBE label node "$node" "${K8S_ZONE_LABEL}-" --overwrite 2>/dev/null || true
  done < <($KUBE get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  echo "✅  Zone labels removed"
else
  echo "ℹ️  Keeping node zone labels (FULL=true or STRIP_ZONE_LABELS=true to remove)"
fi

# --- OpenShift SCC (best-effort; bindings may already be gone with namespace) ---
if command -v oc &>/dev/null && [[ "$KUBE" == "oc" ]]; then
  for sa in rbd-csi-provisioner rbd-csi-nodeplugin; do
    oc adm policy remove-scc-from-user privileged -z "$sa" -n "$CSI_NS" 2>/dev/null || true
  done
fi

echo ""
echo "🔍  Verifying Kubernetes cleanup..."
CHECK_CSIDRIVER="$DELETE_CSIDRIVER" \
CHECK_ZONE_LABELS="$STRIP_ZONE_LABELS" \
  "${SCRIPT_DIR}/topology/verify-k8s-clean.sh"

echo ""
echo "✅  Kubernetes/OpenShift cleanup complete."
echo "    Next on Ceph admin node:"
echo "      CONFIRM=yes ${SCRIPT_DIR}/topology/reset-ceph-zones.sh --with-csi-user --with-orch-labels"
