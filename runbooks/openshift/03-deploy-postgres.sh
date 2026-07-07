#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
NAMESPACE="${NAMESPACE:-pg-multizone}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

usage() {
  cat <<'EOF'
Usage: 03-deploy-postgres.sh [cephfs|cephrbd] [options]

Deploy PostgreSQL in the pg-multizone namespace.

Storage backend:
  cephfs    CephFS — StorageClass cephfs-multizone (statefulset.yaml)
  cephrbd   RBD    — StorageClass cephrbd-multizone (statefulset-rbd.yaml)

If no backend is given on the command line and STORAGE_CLASS is unset,
an interactive prompt is shown.

Options:
  -h, --help    Show this help message and exit

Environment variables:
  STORAGE_CLASS   cephfs | cephrbd | cephfs-multizone | cephrbd-multizone
  NAMESPACE       Target namespace (default: pg-multizone)
  APPLY_ROUTE     Set to true to also apply the Route manifest

Examples:
  ./03-deploy-postgres.sh
  ./03-deploy-postgres.sh cephfs
  ./03-deploy-postgres.sh cephrbd
  STORAGE_CLASS=cephrbd ./03-deploy-postgres.sh
  APPLY_ROUTE=true ./03-deploy-postgres.sh cephrbd
EOF
}

normalize_storage_class() {
  case "$1" in
    cephfs|cephfs-multizone)  echo cephfs-multizone ;;
    cephrbd|cephrbd-multizone) echo cephrbd-multizone ;;
    *)
      echo "❌  Unknown storage backend: $1" >&2
      echo "    Supported: cephfs, cephrbd" >&2
      return 1
      ;;
  esac
}

prompt_storage_class() {
  echo "Select storage backend:"
  echo "  1) cephfs  — CephFS (cephfs-multizone)"
  echo "  2) cephrbd — RBD block (cephrbd-multizone)"
  while true; do
    read -rp "Choice [1/2 or cephfs/cephrbd]: " choice
    case "$choice" in
      1|cephfs)  STORAGE_CLASS=cephfs; break ;;
      2|cephrbd) STORAGE_CLASS=cephrbd; break ;;
      "")        echo "    Please enter 1, 2, cephfs, or cephrbd." ;;
      *)         echo "    Invalid choice. Enter 1, 2, cephfs, or cephrbd." ;;
    esac
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    cephfs|cephrbd)
      if [[ -n "$STORAGE_CLASS" ]]; then
        echo "❌  Storage backend specified more than once." >&2
        exit 1
      fi
      STORAGE_CLASS="$1"
      ;;
    *)
      echo "❌  Unknown argument: $1" >&2
      echo ""
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$STORAGE_CLASS" ]]; then
  if [[ -t 0 ]]; then
    prompt_storage_class
  else
    echo "❌  No storage backend selected." >&2
    echo "    Pass cephfs or cephrbd as an argument, set STORAGE_CLASS, or run interactively." >&2
    echo ""
    usage >&2
    exit 1
  fi
fi

STORAGE_CLASS=$(normalize_storage_class "$STORAGE_CLASS")

case "$STORAGE_CLASS" in
  cephfs-multizone)  STATEFULSET="${MANIFESTS_DIR}/statefulset.yaml" ;;
  cephrbd-multizone) STATEFULSET="${MANIFESTS_DIR}/statefulset-rbd.yaml" ;;
esac

oc create namespace "$NAMESPACE" 2>/dev/null || echo "Namespace $NAMESPACE already exists"

oc apply -f "${MANIFESTS_DIR}/configmap.yaml"
oc apply -f "${MANIFESTS_DIR}/secret.yaml"
oc apply -f "${MANIFESTS_DIR}/service.yaml"
oc apply -f "$STATEFULSET"

if [[ "${APPLY_ROUTE:-false}" == "true" ]]; then
  oc apply -f "${MANIFESTS_DIR}/route.yaml"
fi

echo "✅  PostgreSQL deployed in namespace $NAMESPACE (storage: $STORAGE_CLASS)"
