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

if oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd &>/dev/null; then
  echo "✅  Topology-aware class found: ocs-storagecluster-ceph-non-resilient-rbd"
  echo ""
  echo "→ Use Path B (topology) in STORAGECLASS-RBD.md"
  echo "  oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd -o yaml \\"
  echo "    | sed 's/name: ocs-storagecluster-ceph-non-resilient-rbd/name: cephrbd-multizone/' \\"
  echo "    | oc apply -f -"
  exit 0
fi

if oc get storageclass ocs-storagecluster-ceph-rbd &>/dev/null; then
  echo "✅  Found ODF RBD StorageClass: ocs-storagecluster-ceph-rbd"
  oc get storageclass ocs-storagecluster-ceph-rbd -o jsonpath='    clusterID={.parameters.clusterID}{"\n"}    pool={.parameters.pool}{"\n"}'
fi

echo ""
echo "Ceph block pools:"
oc get cephblockpool -n "$CEPH_NS" 2>/dev/null || echo "    (unable to list cephblockpool)"

zone_pools=$(oc get cephblockpool -n "$CEPH_NS" -o json 2>/dev/null \
  | jq -r '[.items[] | select(.spec.failureDomain // "" | test("zone"; "i"))] | length' || echo 0)

if [[ "$zone_pools" -gt 0 ]]; then
  echo ""
  echo "→ Zone-level block pools detected — use Path B (topology) in STORAGECLASS-RBD.md"
else
  echo ""
  echo "⚠️  No per-zone Ceph block pools (failureDomain is likely host-only)."
  echo "→ Use Path A (simple) in STORAGECLASS-RBD.md:"
  echo "  oc apply -f manifests/storageclass-cephrbd-multizone-simple.yaml"
  echo "  # or clone ocs-storagecluster-ceph-rbd → cephrbd-multizone"
fi
