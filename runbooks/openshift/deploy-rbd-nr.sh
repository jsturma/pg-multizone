#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORAGE_CLASS="${STORAGE_CLASS:-cephrbd-multizone-nr}"

if ! oc get storageclass "$STORAGE_CLASS" &>/dev/null; then
  echo "❌  StorageClass '$STORAGE_CLASS' not found." >&2
  echo "    Create non-resilient pool first — see ${SCRIPT_DIR}/ZONE-LOCAL-RBD.md" >&2
  exit 1
fi

"${SCRIPT_DIR}/02-label-nodes.sh"
STORAGE_CLASS="$STORAGE_CLASS" "${SCRIPT_DIR}/03-deploy-postgres.sh" cephrbd-nr
"${SCRIPT_DIR}/04-verify.sh"

echo ""
echo "Run ${SCRIPT_DIR}/05-test-connection.sh to test PostgreSQL connectivity."
