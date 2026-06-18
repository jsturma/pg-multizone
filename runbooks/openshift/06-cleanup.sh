#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
NAMESPACE="${NAMESPACE:-pg-multizone}"

oc delete namespace "$NAMESPACE" --ignore-not-found

if [[ -f "${GENERATED_DIR}/cephfs-multizone.yaml" ]]; then
  oc delete -f "${GENERATED_DIR}/cephfs-multizone.yaml" --ignore-not-found
fi

echo "✅  Cleanup complete"
