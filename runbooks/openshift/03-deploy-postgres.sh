#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
NAMESPACE="${NAMESPACE:-pg-multizone}"

oc create namespace "$NAMESPACE" 2>/dev/null || echo "Namespace $NAMESPACE already exists"

oc apply -f "${MANIFESTS_DIR}/configmap.yaml"
oc apply -f "${MANIFESTS_DIR}/secret.yaml"
oc apply -f "${MANIFESTS_DIR}/service.yaml"
oc apply -f "${MANIFESTS_DIR}/statefulset.yaml"

if [[ "${APPLY_ROUTE:-false}" == "true" ]]; then
  oc apply -f "${MANIFESTS_DIR}/route.yaml"
fi

echo "✅  PostgreSQL deployed in namespace $NAMESPACE"
