#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
NAMESPACE="${NAMESPACE:-pg-multizone}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

CEPHFS_SC="cephfs-multizone"
CEPHRBD_SC="cephrbd-multizone"
AVAILABLE_BACKENDS=()

usage() {
  cat <<'EOF'
Usage: 03-deploy-postgres.sh [cephfs|cephrbd] [options]

Deploy PostgreSQL in the pg-multizone namespace.

Storage backend:
  cephfs    CephFS — StorageClass cephfs-multizone (statefulset.yaml)
  cephrbd   RBD    — StorageClass cephrbd-multizone (statefulset-rbd.yaml)

Only backends whose StorageClass exists in the cluster are offered.

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

storage_class_exists() {
  oc get storageclass "$1" &>/dev/null
}

backend_to_sc() {
  case "$1" in
    cephfs)  echo "$CEPHFS_SC" ;;
    cephrbd) echo "$CEPHRBD_SC" ;;
  esac
}

backend_doc() {
  case "$1" in
    cephfs)  echo "${SCRIPT_DIR}/STORAGECLASS.md" ;;
    cephrbd) echo "${SCRIPT_DIR}/STORAGECLASS-RBD.md" ;;
  esac
}

discover_available_backends() {
  AVAILABLE_BACKENDS=()
  storage_class_exists "$CEPHFS_SC" && AVAILABLE_BACKENDS+=("cephfs")
  storage_class_exists "$CEPHRBD_SC" && AVAILABLE_BACKENDS+=("cephrbd")
}

backend_is_available() {
  local backend="$1"
  local sc
  sc=$(backend_to_sc "$backend")
  storage_class_exists "$sc"
}

no_storage_classes_error() {
  echo "❌  No supported StorageClass found in the cluster." >&2
  echo "    Expected one of: $CEPHFS_SC, $CEPHRBD_SC" >&2
  echo "    Create one manually:" >&2
  echo "      CephFS → ${SCRIPT_DIR}/STORAGECLASS.md" >&2
  echo "      RBD    → ${SCRIPT_DIR}/STORAGECLASS-RBD.md" >&2
}

normalize_storage_class() {
  case "$1" in
    cephfs|cephfs-multizone)   echo "$CEPHFS_SC" ;;
    cephrbd|cephrbd-multizone) echo "$CEPHRBD_SC" ;;
    *)
      echo "❌  Unknown storage backend: $1" >&2
      echo "    Supported: cephfs, cephrbd" >&2
      return 1
      ;;
  esac
}

backend_from_normalized_sc() {
  case "$1" in
    "$CEPHFS_SC")  echo cephfs ;;
    "$CEPHRBD_SC") echo cephrbd ;;
  esac
}

ensure_storage_class_available() {
  local sc="$1"
  if storage_class_exists "$sc"; then
    return 0
  fi

  local backend
  backend=$(backend_from_normalized_sc "$sc")
  echo "❌  StorageClass '$sc' not found." >&2
  echo "    Create it manually — see $(backend_doc "$backend")" >&2
  discover_available_backends
  if [[ ${#AVAILABLE_BACKENDS[@]} -gt 0 ]]; then
    echo "    Available in cluster: ${AVAILABLE_BACKENDS[*]}" >&2
  fi
  exit 1
}

prompt_storage_class() {
  discover_available_backends

  if [[ ${#AVAILABLE_BACKENDS[@]} -eq 0 ]]; then
    no_storage_classes_error
    exit 1
  fi

  if [[ ${#AVAILABLE_BACKENDS[@]} -eq 1 ]]; then
    STORAGE_CLASS="${AVAILABLE_BACKENDS[0]}"
    echo "✅  Only available backend: ${STORAGE_CLASS} ($(backend_to_sc "$STORAGE_CLASS"))"
    return
  fi

  echo "Select storage backend:"
  local i=1
  for backend in "${AVAILABLE_BACKENDS[@]}"; do
    case "$backend" in
      cephfs)  echo "  $i) cephfs  — CephFS ($CEPHFS_SC)" ;;
      cephrbd) echo "  $i) cephrbd — RBD block ($CEPHRBD_SC)" ;;
    esac
    ((i++)) || true
  done

  local choice_labels
  choice_labels=$(IFS=/; echo "${AVAILABLE_BACKENDS[*]}")

  while true; do
    read -rp "Choice [1-${#AVAILABLE_BACKENDS[@]} or ${choice_labels}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      local idx=$((choice - 1))
      if [[ $idx -ge 0 && $idx -lt ${#AVAILABLE_BACKENDS[@]} ]]; then
        STORAGE_CLASS="${AVAILABLE_BACKENDS[$idx]}"
        break
      fi
    elif [[ "$choice" == "cephfs" || "$choice" == "cephrbd" ]]; then
      if backend_is_available "$choice"; then
        STORAGE_CLASS="$choice"
        break
      fi
      echo "    StorageClass for '$choice' is not available in the cluster."
      continue
    elif [[ -z "$choice" ]]; then
      echo "    Please enter a number or ${choice_labels}."
      continue
    fi
    echo "    Invalid choice. Enter 1-${#AVAILABLE_BACKENDS[@]} or ${choice_labels}."
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
    discover_available_backends
    if [[ ${#AVAILABLE_BACKENDS[@]} -eq 1 ]]; then
      STORAGE_CLASS="${AVAILABLE_BACKENDS[0]}"
      echo "✅  Using only available backend: ${STORAGE_CLASS}"
    else
      echo "❌  No storage backend selected." >&2
      discover_available_backends
      if [[ ${#AVAILABLE_BACKENDS[@]} -gt 0 ]]; then
        echo "    Available: ${AVAILABLE_BACKENDS[*]}" >&2
      else
        no_storage_classes_error
      fi
      echo "    Pass cephfs or cephrbd as an argument, set STORAGE_CLASS, or run interactively." >&2
      echo ""
      usage >&2
      exit 1
    fi
  fi
fi

STORAGE_CLASS=$(normalize_storage_class "$STORAGE_CLASS")
ensure_storage_class_available "$STORAGE_CLASS"

case "$STORAGE_CLASS" in
  "$CEPHFS_SC")  STATEFULSET="${MANIFESTS_DIR}/statefulset.yaml" ;;
  "$CEPHRBD_SC") STATEFULSET="${MANIFESTS_DIR}/statefulset-rbd.yaml" ;;
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
