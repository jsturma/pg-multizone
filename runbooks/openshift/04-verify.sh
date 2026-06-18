#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-pg-multizone}"

echo "Pods:"
oc get pods -n "$NAMESPACE"

echo ""
echo "PVCs:"
oc get pvc -n "$NAMESPACE"

echo ""
echo "Pod placement:"
oc get pod -n "$NAMESPACE" -o wide
