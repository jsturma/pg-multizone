#!/usr/bin/env bash
# Verify OpenShift topology labels match canonical zones.env and external-Ceph manifests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSHIFT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=zones.env
source "${SCRIPT_DIR}/zones.env"

EXTERNAL_SC="ceph-external-zone-nr"
MANIFEST_SC="${OPENSHIFT_DIR}/manifests/topology/storageclass-ceph-external-zone-nr.yaml"
MANIFEST_STS="${OPENSHIFT_DIR}/manifests/pg/statefulset-external-rbd-nr.yaml"

failures=0

fail() {
  echo "❌  $*" >&2
  failures=$((failures + 1))
}

ok() {
  echo "✅  $*"
}

echo "Topology alignment check (canonical: ${ZONES[*]})"
echo ""

# --- Node labels ---
declare -A seen_zones=()
while IFS= read -r line; do
  node=$(awk '{print $1}' <<<"$line")
  zone=$(awk '{print $2}' <<<"$line")
  if [[ -z "$zone" || "$zone" == "<none>" ]]; then
    fail "Node ${node} missing label ${K8S_ZONE_LABEL}"
    continue
  fi
  seen_zones["$zone"]=1
  if [[ ! " ${ZONES[*]} " =~ " ${zone} " ]]; then
    fail "Node ${node} has ${K8S_ZONE_LABEL}=${zone} — not in canonical ZONES (${ZONES[*]})"
  fi
done < <(
  oc get nodes -o json 2>/dev/null \
    | jq -r --arg key "${K8S_ZONE_LABEL}" \
      '.items[] | "\(.metadata.name) \(.metadata.labels[$key] // "")"' \
    || true
)

for z in "${ZONES[@]}"; do
  if [[ -z "${seen_zones[$z]:-}" ]]; then
    fail "No node labelled ${K8S_ZONE_LABEL}=${z}"
  else
    ok "At least one node in ${z}"
  fi
done

# --- Node labels vs StorageClass allowedTopologies / domainLabel ---
if oc get storageclass "${EXTERNAL_SC}" &>/dev/null; then
  sc_label_key=$(oc get storageclass "${EXTERNAL_SC}" -o json \
    | jq -r '.allowedTopologies[0].matchLabelExpressions[0].key // ""')
  mapfile -t sc_allowed_zones < <(
    oc get storageclass "${EXTERNAL_SC}" -o json \
      | jq -r '.allowedTopologies[].matchLabelExpressions[].values[]?' \
      | sort -u
  )
  mapfile -t sc_pool_zones < <(
    oc get storageclass "${EXTERNAL_SC}" -o json \
      | jq -r '.parameters.topologyConstrainedPools | fromjson | .[].domainSegments[] | select(.domainLabel == "'"${K8S_ZONE_LABEL}"'") | .value' \
      | sort -u
  )
  if [[ "${sc_label_key}" != "${K8S_ZONE_LABEL}" ]]; then
    fail "StorageClass ${EXTERNAL_SC} allowedTopologies key=${sc_label_key:-MISSING} — expected ${K8S_ZONE_LABEL} (see External-Ceph-Cluster.md §3a)"
  else
    ok "StorageClass ${EXTERNAL_SC} uses label key ${K8S_ZONE_LABEL}"
  fi
  for z in "${ZONES[@]}"; do
    if [[ ! " ${sc_allowed_zones[*]} " =~ " ${z} " ]]; then
      fail "StorageClass ${EXTERNAL_SC} allowedTopologies missing ${z}"
    fi
    if [[ ! " ${sc_pool_zones[*]} " =~ " ${z} " ]]; then
      fail "StorageClass ${EXTERNAL_SC} topologyConstrainedPools missing ${K8S_ZONE_LABEL}=${z}"
    fi
  done
  while IFS= read -r line; do
    node=$(awk '{print $1}' <<<"$line")
    zone=$(awk '{print $2}' <<<"$line")
    [[ -z "$zone" || "$zone" == "<none>" ]] && continue
    if [[ ! " ${sc_allowed_zones[*]} " =~ " ${zone} " ]]; then
      fail "Node ${node} ${K8S_ZONE_LABEL}=${zone} not listed in StorageClass allowedTopologies"
    fi
  done < <(
    oc get nodes -o json 2>/dev/null \
      | jq -r --arg key "${K8S_ZONE_LABEL}" \
        '.items[] | "\(.metadata.name) \(.metadata.labels[$key] // "")"' \
      || true
  )
  ok "Node zone values align with StorageClass ${EXTERNAL_SC}"
fi

# --- StorageClass (cluster) ---
if oc get storageclass "${EXTERNAL_SC}" &>/dev/null; then
  mapfile -t sc_zones < <(
    oc get storageclass "${EXTERNAL_SC}" -o json \
      | jq -r '.parameters.topologyConstrainedPools | fromjson | .[].domainSegments[].value' \
      | sort -u
  )
  mapfile -t sc_pools < <(
    oc get storageclass "${EXTERNAL_SC}" -o json \
      | jq -r '.parameters.topologyConstrainedPools | fromjson | .[].poolName' \
      | sort -u
  )
  for z in "${ZONES[@]}"; do
    if [[ ! " ${sc_zones[*]} " =~ " ${z} " ]]; then
      fail "StorageClass ${EXTERNAL_SC} topologyConstrainedPools missing zone ${z}"
    fi
    pool="$(rbd_pool_for_zone "$z")"
    if [[ ! " ${sc_pools[*]} " =~ " ${pool} " ]]; then
      fail "StorageClass ${EXTERNAL_SC} missing pool ${pool} for ${z}"
    fi
  done
  ok "StorageClass ${EXTERNAL_SC} pools and zones match canonical topology"
else
  echo "⚠️  StorageClass ${EXTERNAL_SC} not applied — skipping live SC check"
fi

# --- Manifest files on disk ---
for z in "${ZONES[@]}"; do
  pool="$(rbd_pool_for_zone "$z")"
  if ! grep -q "\"poolName\":\"${pool}\"" "${MANIFEST_SC}" \
      || ! grep -q "\"value\":\"${z}\"" "${MANIFEST_SC}"; then
    fail "Manifest ${MANIFEST_SC} missing mapping ${pool} ↔ ${z}"
  fi
  if ! grep -q "${z}" "${MANIFEST_STS}"; then
    fail "Manifest ${MANIFEST_STS} missing zone ${z}"
  fi
done
ok "Manifest files reference all canonical zones and pools"

# --- 02-label-nodes.sh uses same ZONES ---
if ! grep -q 'source.*topology/zones.env' "${OPENSHIFT_DIR}/02-label-nodes.sh"; then
  fail "02-label-nodes.sh does not source topology/zones.env"
else
  ok "02-label-nodes.sh sources topology/zones.env"
fi

# --- Ceph-CSI clusterID: ConfigMap ↔ StorageClass ↔ zones.env ---
CSI_NS="external-ceph-csi"
CM_CLUSTER_ID=""
SC_CLUSTER_ID=""
if oc -n "${CSI_NS}" get configmap ceph-csi-config &>/dev/null; then
  CM_CLUSTER_ID=$(oc -n "${CSI_NS}" get configmap ceph-csi-config -o json \
    | jq -r '.data["config.json"] | fromjson | .[0].clusterID // ""' 2>/dev/null || echo "")
  if [[ -z "${CM_CLUSTER_ID}" ]]; then
    fail "ConfigMap ceph-csi-config missing clusterID in config.json"
  elif [[ "${CM_CLUSTER_ID}" != "${CSI_CLUSTER_ID}" ]]; then
    fail "ConfigMap ceph-csi-config clusterID=${CM_CLUSTER_ID} — expected ${CSI_CLUSTER_ID} (see External-Ceph-Cluster.md §2.3a)"
  else
    ok "ConfigMap ceph-csi-config clusterID=${CSI_CLUSTER_ID}"
  fi
else
  echo "⚠️  ConfigMap ceph-csi-config not found in ${CSI_NS} — skipping clusterID check"
fi

if oc get storageclass "${EXTERNAL_SC}" &>/dev/null; then
  SC_CLUSTER_ID=$(oc get storageclass "${EXTERNAL_SC}" -o jsonpath='{.parameters.clusterID}' 2>/dev/null || echo "")
  if [[ -z "${SC_CLUSTER_ID}" ]]; then
    fail "StorageClass ${EXTERNAL_SC} missing parameters.clusterID"
  elif [[ "${SC_CLUSTER_ID}" != "${CSI_CLUSTER_ID}" ]]; then
    fail "StorageClass ${EXTERNAL_SC} clusterID=${SC_CLUSTER_ID} — expected ${CSI_CLUSTER_ID} (see External-Ceph-Cluster.md §2.3a)"
  else
    ok "StorageClass ${EXTERNAL_SC} clusterID=${CSI_CLUSTER_ID}"
  fi
  if [[ -n "${CM_CLUSTER_ID}" && "${CM_CLUSTER_ID}" != "${SC_CLUSTER_ID}" ]]; then
    fail "clusterID mismatch: ConfigMap=${CM_CLUSTER_ID} vs StorageClass=${SC_CLUSTER_ID}"
  fi
fi

if ! grep -q "clusterID: ${CSI_CLUSTER_ID}" "${MANIFEST_SC}"; then
  fail "Manifest ${MANIFEST_SC} clusterID does not match CSI_CLUSTER_ID=${CSI_CLUSTER_ID}"
else
  ok "Manifest ${MANIFEST_SC} clusterID=${CSI_CLUSTER_ID}"
fi

# --- Ceph-CSI node plugin advertises the same topology key as the StorageClass ---
if oc -n "${CSI_NS}" get daemonset csi-rbdplugin &>/dev/null; then
  if oc -n "${CSI_NS}" get daemonset csi-rbdplugin -o json \
      | jq -e --arg dl "${CSI_DOMAIN_LABELS}" \
        '.spec.template.spec.containers[] | select(.name=="csi-rbdplugin") | .args[]? | select(test("^--domainlabels=")) | select(test($dl))' \
      &>/dev/null; then
    ok "DaemonSet csi-rbdplugin has --domainlabels=${CSI_DOMAIN_LABELS}"
  else
    fail "DaemonSet csi-rbdplugin missing --domainlabels=${CSI_DOMAIN_LABELS} (CSI advertises topology.rbd.csi.ceph.com/zone by default)"
  fi
else
  echo "⚠️  DaemonSet csi-rbdplugin not found in ${CSI_NS} — skipping CSI domainLabels check"
fi

echo ""
if [[ "$failures" -gt 0 ]]; then
  echo "❌  ${failures} alignment issue(s). Edit topology/zones.env and all Ceph/K8s objects together." >&2
  exit 1
fi
echo "✅  OpenShift topology aligned with zones.env"
