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
  exit 1
fi
echo "✅  CSIDriver registered"

node_count=$(oc get csinodes -o json | jq --arg p "$RBD_PROVISIONER" '[.items[].spec.drivers[]? | select(.name == $p)] | length')
if [[ "$node_count" -eq 0 ]]; then
  echo "❌  RBD CSI driver not registered on any node." >&2
  exit 1
fi
echo "✅  RBD CSI driver registered on $node_count node(s)"

echo ""
echo "Resilient pool (cephrbd-multizone-r):"
if oc get storageclass cephrbd-multizone-r &>/dev/null; then
  echo "  ✅  already created"
elif oc get storageclass ocs-storagecluster-ceph-rbd &>/dev/null; then
  echo "  ⚠️  not found — create with:"
  echo "     oc apply -f manifests/topology/storageclass-cephrbd-multizone-r.yaml"
else
  echo "  ❌  ocs-storagecluster-ceph-rbd missing"
fi

echo ""
echo "Non-resilient pool (cephrbd-multizone-nr):"
if oc get storageclass cephrbd-multizone-nr &>/dev/null; then
  echo "  ✅  already created"
elif oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd &>/dev/null; then
  echo "  ⚠️  not found — clone ODF SC:"
  echo "     oc get sc ocs-storagecluster-ceph-non-resilient-rbd -o yaml \\"
  echo "       | sed 's/name: ocs-storagecluster-ceph-non-resilient-rbd/name: cephrbd-multizone-nr/' \\"
  echo "       | oc apply -f -"
else
  echo "  ⚠️  not available — enable cephNonResilientPools (see ZONE-LOCAL-RBD.md)"
  echo ""
  echo "  Ceph block pools:"
  oc get cephblockpool -n "$CEPH_NS" 2>/dev/null || true
fi

echo ""
echo "See STORAGECLASS-RBD.md to create both pools."
