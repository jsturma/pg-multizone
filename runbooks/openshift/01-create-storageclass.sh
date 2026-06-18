#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CEPH_NS="${CEPH_NS:-openshift-storage}"
CEPHFS_PROVISIONER="${CEPHFS_PROVISIONER:-openshift-storage.cephfs.csi.ceph.com}"

ensure_csi_provisioner() {
  local provisioner="$1"
  local namespace="$2"

  echo "🔍  Checking CSI provisioner: $provisioner"

  if ! oc get namespace "$namespace" &>/dev/null; then
    echo "❌  Namespace '$namespace' not found." >&2
    echo "    Set CEPH_NS to the namespace where OCS/ODF is installed." >&2
    exit 1
  fi

  if ! oc get csidriver "$provisioner" &>/dev/null; then
    echo "❌  CSIDriver '$provisioner' not found." >&2
    echo "    Install OpenShift Container Storage (OCS) / OpenShift Data Foundation (ODF) with CephFS enabled." >&2
    echo "    Verify with: oc get csidrivers" >&2
    exit 1
  fi
  echo "✅  CSIDriver registered"

  local node_count
  node_count=$(oc get csinodes -o json | jq --arg p "$provisioner" '[.items[].spec.drivers[]? | select(.name == $p)] | length')
  if [[ "$node_count" -eq 0 ]]; then
    echo "❌  CSI driver '$provisioner' is not registered on any node (CSINode)." >&2
    echo "    Verify with: oc get csinodes -o yaml" >&2
    exit 1
  fi
  echo "✅  CSI driver registered on $node_count node(s)"

  mapfile -t csi_pods < <(
    oc get pods -n "$namespace" -l 'app in (csi-cephfsplugin, csi-cephfsplugin-provisioner)' \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
  )
  if [[ ${#csi_pods[@]} -eq 0 ]]; then
    mapfile -t csi_pods < <(
      oc get pods -n "$namespace" --no-headers 2>/dev/null \
        | awk '$2 ~ /^[0-9]+\/[0-9]+$/ && $3 == "Running" && /cephfs/ && /csi/ {print $1}'
    )
  fi
  if [[ ${#csi_pods[@]} -eq 0 ]]; then
    echo "❌  No Running CephFS CSI pods found in namespace '$namespace'." >&2
    echo "    Verify with: oc get pods -n $namespace | grep -i cephfs" >&2
    exit 1
  fi
  echo "✅  CephFS CSI pods running in $namespace: ${csi_pods[*]}"
}

ensure_csi_provisioner "$CEPHFS_PROVISIONER" "$CEPH_NS"

mkdir -p "${GENERATED_DIR}"

TOOLBOX=$(oc -n "$CEPH_NS" get pods -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$TOOLBOX" ]]; then
  echo "⚙️  Toolbox missing – creating a rook-ceph-tools pod …"
  oc -n "$CEPH_NS" apply -f "${MANIFESTS_DIR}/rook-ceph-tools.yaml"
  echo "⏳  Waiting for toolbox pod …"
  oc -n "$CEPH_NS" wait --for=condition=Ready pod -l app=rook-ceph-tools --timeout=120s
  TOOLBOX=$(oc -n "$CEPH_NS" get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')
fi

echo "✅  Toolbox available: $TOOLBOX"

CLUSTER_ID=$(oc -n "$CEPH_NS" exec "$TOOLBOX" -- ceph status -f json-pretty | jq -r '.monmap.fsid')
FS_NAME=$(oc -n "$CEPH_NS" exec "$TOOLBOX" -- ceph fs ls -f json-pretty | jq -r '.[0].name')
POOL=$(oc -n "$CEPH_NS" exec "$TOOLBOX" -- ceph fs data ls -f json-pretty | jq -r '.[0].data_pool_name')

echo "🔑  clusterID = $CLUSTER_ID"
echo "📂  fsName = $FS_NAME"
echo "💾  pool = $POOL"

SC_FILE="${GENERATED_DIR}/cephfs-multizone.yaml"
cat > "$SC_FILE" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cephfs-multizone
provisioner: ${CEPHFS_PROVISIONER}
parameters:
  clusterID: $CLUSTER_ID
  fsName: $FS_NAME
  pool: $POOL
  topologyConstrained: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
  - matchLabelExpressions:
      - key: topology.kubernetes.io/zone
        values:
          - zone-a
          - zone-b
          - zone-c
EOF

echo "🗂️  StorageClass manifest created → $SC_FILE"
oc apply -f "$SC_FILE"
oc get sc cephfs-multizone -o yaml
