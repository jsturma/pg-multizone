#!/usr/bin/env bash
# Verify OpenShift/Kubernetes external-Ceph resources are removed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSHIFT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=zones.env
source "${SCRIPT_DIR}/zones.env"

KUBE="${KUBE_CMD:-oc}"
SC_NAME="${SC_NAME:-ceph-external-zone-nr}"
CSI_NS="${CSI_NS:-external-ceph-csi}"
NAMESPACE="${NAMESPACE:-pg-multizone}"
CHECK_CSIDRIVER="${CHECK_CSIDRIVER:-false}"
CHECK_ZONE_LABELS="${CHECK_ZONE_LABELS:-false}"

failures=0

fail() {
  echo "❌  $*" >&2
  failures=$((failures + 1))
}

ok() {
  echo "✅  $*"
}

echo "Kubernetes/OpenShift cleanup verification"

for ns in "$NAMESPACE" sc-test "$CSI_NS"; do
  if $KUBE get namespace "$ns" &>/dev/null; then
    fail "Namespace still exists: ${ns}"
  else
    ok "Namespace absent: ${ns}"
  fi
done

if $KUBE get storageclass "$SC_NAME" &>/dev/null; then
  fail "StorageClass still exists: ${SC_NAME}"
else
  ok "StorageClass absent: ${SC_NAME}"
fi

mapfile -t pvcs < <(
  $KUBE get pvc -A -o json 2>/dev/null \
    | jq -r --arg sc "$SC_NAME" \
      '.items[] | select(.spec.storageClassName == $sc) | "\(.metadata.namespace)/\(.metadata.name)"' \
    || true
)
if [[ ${#pvcs[@]} -gt 0 ]]; then
  fail "PVCs still using ${SC_NAME}: ${pvcs[*]}"
else
  ok "No PVCs reference ${SC_NAME}"
fi

if [[ "$CHECK_CSIDRIVER" == "true" ]]; then
  if $KUBE get csidriver rbd.csi.ceph.com &>/dev/null; then
    fail "CSIDriver rbd.csi.ceph.com still registered"
  else
    ok "CSIDriver absent"
  fi
fi

if [[ "$CHECK_ZONE_LABELS" == "true" ]]; then
  mapfile -t labeled < <(
    $KUBE get nodes -o json 2>/dev/null \
      | jq -r --arg key "${K8S_ZONE_LABEL}" \
        '.items[] | select(.metadata.labels[$key] != null) | .metadata.name' \
      || true
  )
  if [[ ${#labeled[@]} -gt 0 ]]; then
    fail "Nodes still have ${K8S_ZONE_LABEL}: ${labeled[*]}"
  else
    ok "No ${K8S_ZONE_LABEL} labels on nodes"
  fi
fi

echo ""
if [[ "$failures" -gt 0 ]]; then
  echo "❌  ${failures} Kubernetes resource(s) remain — re-run ./06-cleanup-external-ceph.sh" >&2
  exit 1
fi
echo "✅  Kubernetes/OpenShift external-Ceph layer is clean"
