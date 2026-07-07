#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! oc get storageclass cephfs-multizone &>/dev/null; then
  echo "❌  StorageClass 'cephfs-multizone' not found." >&2
  echo "    Create it manually first — see ${SCRIPT_DIR}/STORAGECLASS.md" >&2
  exit 1
fi

"${SCRIPT_DIR}/02-label-nodes.sh"
"${SCRIPT_DIR}/03-deploy-postgres.sh"
"${SCRIPT_DIR}/04-verify.sh"

echo ""
echo "Run ${SCRIPT_DIR}/05-test-connection.sh to test PostgreSQL connectivity."
