#!/usr/bin/env bash
set -euo pipefail

CEPH_NS="${CEPH_NS:-openshift-storage}"
CEPHFS_PROVISIONER="${CEPHFS_PROVISIONER:-openshift-storage.cephfs.csi.ceph.com}"

echo "🔍  Checking CSI provisioner: $CEPHFS_PROVISIONER"

if ! oc get namespace "$CEPH_NS" &>/dev/null; then
  echo "❌  Namespace '$CEPH_NS' not found." >&2
  echo "    Set CEPH_NS to the namespace where OCS/ODF is installed." >&2
  exit 1
fi

if ! oc get csidriver "$CEPHFS_PROVISIONER" &>/dev/null; then
  echo "❌  CSIDriver '$CEPHFS_PROVISIONER' not found." >&2
  echo "    Install ODF with CephFS enabled. Verify with: oc get csidrivers" >&2
  exit 1
fi
echo "✅  CSIDriver registered"

node_count=$(oc get csinodes -o json | jq --arg p "$CEPHFS_PROVISIONER" '[.items[].spec.drivers[]? | select(.name == $p)] | length')
if [[ "$node_count" -eq 0 ]]; then
  echo "❌  CSI driver '$CEPHFS_PROVISIONER' is not registered on any node." >&2
  exit 1
fi
echo "✅  CSI driver registered on $node_count node(s)"

if oc get storageclass ocs-storagecluster-cephfs &>/dev/null; then
  echo "✅  ODF default CephFS StorageClass found (use it to copy parameters)"
  oc get storageclass ocs-storagecluster-cephfs -o jsonpath='    clusterID={.parameters.clusterID}{"\n"}    fsName={.parameters.fsName}{"\n"}    pool={.parameters.pool}{"\n"}'
else
  echo "⚠️  ocs-storagecluster-cephfs not found — check: oc get sc"
fi

echo ""
echo "Next: follow STORAGECLASS.md to create cephfs-multizone manually."
