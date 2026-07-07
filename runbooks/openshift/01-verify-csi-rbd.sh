#!/usr/bin/env bash
set -euo pipefail

CEPH_NS="${CEPH_NS:-openshift-storage}"
RBD_PROVISIONER="${RBD_PROVISIONER:-openshift-storage.rbd.csi.ceph.com}"

echo "🔍  Checking RBD CSI provisioner: $RBD_PROVISIONER"

if ! oc get namespace "$CEPH_NS" &>/dev/null; then
  echo "❌  Namespace '$CEPH_NS' not found." >&2
  exit 1
fi

if ! oc get csidriver "$RBD_PROVISIONER" &>/dev/null; then
  echo "❌  CSIDriver '$RBD_PROVISIONER' not found." >&2
  echo "    Install ODF with RBD enabled. Verify with: oc get csidrivers" >&2
  exit 1
fi
echo "✅  CSIDriver registered"

node_count=$(oc get csinodes -o json | jq --arg p "$RBD_PROVISIONER" '[.items[].spec.drivers[]? | select(.name == $p)] | length')
if [[ "$node_count" -eq 0 ]]; then
  echo "❌  RBD CSI driver not registered on any node." >&2
  exit 1
fi
echo "✅  RBD CSI driver registered on $node_count node(s)"

for sc in ocs-storagecluster-ceph-non-resilient-rbd ocs-storagecluster-ceph-rbd; do
  if oc get storageclass "$sc" &>/dev/null; then
    echo "✅  Found ODF RBD StorageClass: $sc"
    if [[ "$sc" == "ocs-storagecluster-ceph-non-resilient-rbd" ]]; then
      echo "    (topology-aware — good candidate to copy for cephrbd-multizone)"
    fi
  fi
done

echo ""
echo "Next: follow STORAGECLASS-RBD.md to create cephrbd-multizone manually."
