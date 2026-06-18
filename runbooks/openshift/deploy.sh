#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/01-create-storageclass.sh"
"${SCRIPT_DIR}/02-label-nodes.sh"
"${SCRIPT_DIR}/03-deploy-postgres.sh"
"${SCRIPT_DIR}/04-verify.sh"

echo ""
echo "Run ${SCRIPT_DIR}/05-test-connection.sh to test PostgreSQL connectivity."
