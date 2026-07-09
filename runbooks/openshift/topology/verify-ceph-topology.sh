#!/usr/bin/env bash
# Verify Ceph CRUSH buckets and RBD pools match canonical zones.env.
# Run on a Ceph admin node (ceph CLI or cephadm shell).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=zones.env
source "${SCRIPT_DIR}/zones.env"

CEPH="${CEPH_CMD:-ceph}"
if ! command -v ceph &>/dev/null; then
  if command -v cephadm &>/dev/null; then
    CEPH="cephadm shell -- ceph"
  else
    echo "❌  ceph or cephadm not found. Set CEPH_CMD or run on a Ceph admin node." >&2
    exit 1
  fi
fi

failures=0

fail() {
  echo "❌  $*" >&2
  failures=$((failures + 1))
}

ok() {
  echo "✅  $*"
}

echo "Ceph topology alignment check (canonical: ${ZONES[*]})"
echo ""

crush_json=$($CEPH osd crush dump -f json 2>/dev/null || true)
if [[ -z "$crush_json" ]]; then
  echo "❌  Could not read CRUSH map (is the cluster reachable?)" >&2
  exit 1
fi

for z in "${ZONES[@]}"; do
  if ! jq -e --arg z "$z" '.buckets[] | select(.name == $z)' <<<"$crush_json" &>/dev/null; then
    fail "CRUSH bucket ${z} not found — see External-Ceph-Cluster.md F.6 / Step 1.2"
  else
    ok "CRUSH bucket ${z}"
  fi

  pool="$(rbd_pool_for_zone "$z")"
  if ! $CEPH osd pool ls 2>/dev/null | grep -qx "${pool}"; then
    fail "RBD pool ${pool} not found — see F.7 / Step 1.3"
  else
    ok "RBD pool ${pool}"
  fi

  rule="$(crush_rule_for_zone "$z")"
  if ! $CEPH osd crush rule ls 2>/dev/null | grep -qx "${rule}"; then
    fail "CRUSH rule ${rule} not found"
  else
    ok "CRUSH rule ${rule}"
  fi
done

echo ""
echo "CRUSH tree (zone buckets and hosts):"
$CEPH osd tree 2>/dev/null | head -30 || true

echo ""
if [[ "$failures" -gt 0 ]]; then
  echo "❌  ${failures} Ceph alignment issue(s). Zone names must match topology/zones.env and K8s manifests." >&2
  exit 1
fi
echo "✅  Ceph topology aligned with zones.env"
