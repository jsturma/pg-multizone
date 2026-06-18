#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-pg-multizone}"

oc run -i --tty --rm debug-pg \
  --namespace="$NAMESPACE" \
  --image=registry.access.redhat.com/ubi8/ubi \
  --restart=Never \
  --command -- bash -c "\
    yum -y install postgresql && \
    PGPASSWORD='Password123!' psql -h postgres.${NAMESPACE}.svc.cluster.local -U admin -d mydb -c 'SELECT version();' \
  "
