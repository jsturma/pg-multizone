#!/usr/bin/env bash
set -euo pipefail

mapfile -t NODES < <(
  oc get nodes -l node-role.kubernetes.io/worker= --no-headers 2>/dev/null \
    | awk '$2 ~ /^Ready/ {print $1}' \
    | sort
)
if [[ ${#NODES[@]} -eq 0 ]]; then
  mapfile -t NODES < <(oc get nodes --no-headers | awk '$2 ~ /^Ready/ {print $1}' | sort)
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "❌  No Ready nodes found" >&2
  exit 1
fi

echo "📋  Found ${#NODES[@]} node(s): ${NODES[*]}"

ZONES=(zone-a zone-b zone-c)

label_node() {
  local node=$1
  local zone=$2
  oc label node "$node" topology.kubernetes.io/zone="$zone" --overwrite
  echo "🔖  $node → $zone"
}

i=0
for node in "${NODES[@]}"; do
  label_node "$node" "${ZONES[$((i % ${#ZONES[@]}))]}"
  ((i++)) || true
done

oc get nodes -L topology.kubernetes.io/zone
