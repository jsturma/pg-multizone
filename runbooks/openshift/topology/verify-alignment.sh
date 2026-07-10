#!/usr/bin/env bash
# Verify OpenShift topology labels match canonical zones.env and external-Ceph manifests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSHIFT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=zones.env
source "${SCRIPT_DIR}/zones.env"

EXTERNAL_SC="ceph-external-zone-nr"
MANIFEST_SC="${OPENSHIFT_DIR}/manifests/storageclass-ceph-external-zone-nr.yaml"
MANIFEST_STS="${OPENSHIFT_DIR}/manifests/statefulset-external-rbd-nr.yaml"

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

# --- Ceph-CSI node plugin advertises the same topology key as the StorageClass ---
CSI_NS="external-ceph-csi"
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
