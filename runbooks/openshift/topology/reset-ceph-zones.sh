#!/usr/bin/env bash
# Remove pg-multizone zone pools, CRUSH rules, zone buckets, and optional CSI user.
# Run on a Ceph admin node after OpenShift workloads/PVCs are deleted.
#
# Usage:
#   CONFIRM=yes ./reset-ceph-zones.sh
#   CONFIRM=yes CEPH_HOSTS="ceph-node1 ceph-node2 ceph-node3" ./reset-ceph-zones.sh
#   CONFIRM=yes ./reset-ceph-zones.sh --with-csi-user --with-orch-labels
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=zones.env
source "${SCRIPT_DIR}/zones.env"

WITH_CSI_USER=false
WITH_ORCH_LABELS=false

for arg in "$@"; do
  case "$arg" in
    --with-csi-user) WITH_CSI_USER=true ;;
    --with-orch-labels) WITH_ORCH_LABELS=true ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ "${CONFIRM:-}" != "yes" ]]; then
  echo "❌  Refusing to run without CONFIRM=yes" >&2
  echo "    Delete OpenShift PVCs first: ./06-cleanup-external-ceph.sh" >&2
  exit 1
fi

CEPH="${CEPH_CMD:-ceph}"
if ! command -v ceph &>/dev/null; then
  if command -v cephadm &>/dev/null; then
    CEPH="cephadm shell -- ceph"
  else
    echo "❌  ceph or cephadm not found" >&2
    exit 1
  fi
fi

RBD="${RBD_CMD:-rbd}"
if ! command -v rbd &>/dev/null && command -v cephadm &>/dev/null; then
  RBD="cephadm shell -- rbd"
fi

read -r -a HOSTS <<< "${CEPH_HOSTS:-}"
if [[ ${#HOSTS[@]} -eq 0 ]]; then
  mapfile -t HOSTS < <(
    $CEPH osd crush tree 2>/dev/null | awk '$3 == "host" { print $4 }' | sort -u
  )
fi

echo "🧹  Reset Ceph zone topology (zones: ${ZONES[*]})"
[[ ${#HOSTS[@]} -gt 0 ]] && echo "    Hosts to move under default: ${HOSTS[*]}"

pool_delete() {
  local pool=$1
  if ! $CEPH osd pool ls 2>/dev/null | grep -qx "$pool"; then
    echo "⏭️  Pool ${pool} not present"
    return 0
  fi

  echo "🗑️  Purging RBD images in ${pool}..."
  mapfile -t images < <($RBD ls -p "$pool" 2>/dev/null || true)
  for img in "${images[@]}"; do
    [[ -z "$img" ]] && continue
    $RBD rm -p "$pool" "$img" --force 2>/dev/null \
      || $RBD rm "${pool}/${img}" --force 2>/dev/null \
      || echo "⚠️  Could not remove ${pool}/${img} — delete PVCs on OpenShift first"
  done

  echo "🗑️  Deleting pool ${pool}..."
  $CEPH osd pool delete "$pool" "$pool" --yes-i-really-really-mean-it 2>/dev/null \
    || $CEPH osd pool rm "$pool" --yes-i-really-really-mean-it
  echo "✅  Pool ${pool} removed"
}

for z in "${ZONES[@]}"; do
  pool_delete "$(rbd_pool_for_zone "$z")"
done

for z in "${ZONES[@]}"; do
  rule="$(crush_rule_for_zone "$z")"
  if $CEPH osd crush rule ls 2>/dev/null | grep -qx "$rule"; then
    echo "🗑️  Removing CRUSH rule ${rule}..."
    $CEPH osd crush rule rm "$rule"
    echo "✅  Rule ${rule} removed"
  else
    echo "⏭️  CRUSH rule ${rule} not present"
  fi
done

for host in "${HOSTS[@]}"; do
  [[ -z "$host" ]] && continue
  echo "↩️  Moving host ${host} → root=default"
  $CEPH osd crush move "$host" root=default 2>/dev/null || true
done

for z in "${ZONES[@]}"; do
  if $CEPH osd crush dump 2>/dev/null | grep -q "\"name\": \"${z}\""; then
    echo "🗑️  Removing CRUSH bucket ${z}..."
    $CEPH osd crush remove "$z" 2>/dev/null || $CEPH osd crush rm "$z" 2>/dev/null || {
      echo "⚠️  Could not remove bucket ${z} — ensure it is empty (hosts moved out)" >&2
    }
  else
    echo "⏭️  CRUSH bucket ${z} not present"
  fi
done

if $WITH_ORCH_LABELS; then
  for host in "${HOSTS[@]}"; do
    [[ -z "$host" ]] && continue
    $CEPH orch host label rm "$host" zone 2>/dev/null || true
  done
  echo "✅  Orch zone labels removed (where present)"
fi

if $WITH_CSI_USER; then
  if $CEPH auth ls 2>/dev/null | grep -q 'client.csi-rbd-external'; then
    $CEPH auth del client.csi-rbd-external
    echo "✅  client.csi-rbd-external removed"
  fi
fi

echo ""
echo "✅  Ceph zone reset complete. Verify:"
echo "    ceph osd tree"
echo "    ceph osd pool ls | grep rbd-zone || echo '(no rbd-zone-* pools)'"
echo ""
echo "    Re-run from F.6 / Step 1.2 when ready."
