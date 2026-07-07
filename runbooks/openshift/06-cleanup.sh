#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-pg-multizone}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

oc delete namespace "$NAMESPACE" --ignore-not-found

if [[ -n "$STORAGE_CLASS" ]]; then
  oc delete storageclass "$STORAGE_CLASS" --ignore-not-found
else
  oc delete storageclass cephfs-multizone cephrbd-multizone --ignore-not-found
fi

echo "✅  Cleanup complete"
