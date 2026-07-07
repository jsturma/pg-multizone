# RBD StorageClasses — resilient and non-resilient pools

This runbook creates **two** optional RBD StorageClasses. You can install one or both.

| StorageClass | Ceph pool type | Binding | Zone-local PVC | Manifest |
|--------------|----------------|---------|----------------|----------|
| **`cephrbd-multizone-r`** | Resilient (3-way replicated `ocs-storagecluster-cephblockpool`) | `Immediate` | No | [`storageclass-cephrbd-multizone-r.yaml`](manifests/storageclass-cephrbd-multizone-r.yaml) |
| **`cephrbd-multizone-nr`** | Non-resilient (replica-1 per zone) | `WaitForFirstConsumer` | Yes | [`storageclass-cephrbd-multizone-nr.yaml`](manifests/storageclass-cephrbd-multizone-nr.yaml) |

Deploy PostgreSQL with:

```bash
./03-deploy-postgres.sh cephrbd-r    # resilient
./03-deploy-postgres.sh cephrbd-nr   # non-resilient / zone-local
```

---

## Create both pools (recommended layout)

### 1 — Resilient pool (`cephrbd-multizone-r`)

Works on any ODF cluster with the default RBD block pool.

```bash
# Option A: clone ODF default
oc get storageclass ocs-storagecluster-ceph-rbd -o yaml \
  | sed 's/name: ocs-storagecluster-ceph-rbd/name: cephrbd-multizone-r/' \
  | oc apply -f -

# Option B: bundled template
oc apply -f manifests/storageclass-cephrbd-multizone-r.yaml
```

Verify:

```bash
oc get storageclass cephrbd-multizone-r -o jsonpath='pool={.parameters.pool} binding={.volumeBindingMode}{"\n"}'
# pool=ocs-storagecluster-cephblockpool binding=Immediate
```

### 2 — Non-resilient pool (`cephrbd-multizone-nr`)

Requires per-zone Ceph block pools. **Full procedure:** [`ZONE-LOCAL-RBD.md`](ZONE-LOCAL-RBD.md).

```bash
# Label nodes first
./02-label-nodes.sh

# Enable ODF non-resilient pools (when topology supports it)
oc patch storagecluster ocs-storagecluster -n openshift-storage --type json \
  --patch '[{"op": "replace", "path": "/spec/managedResources/cephNonResilientPools/enable", "value": true}]'

# Wait for pools + ODF SC
watch oc get cephblockpool -n openshift-storage
oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd
```

Create the custom StorageClass:

```bash
# Option A: clone ODF topology SC (easiest when it exists)
oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd -o yaml \
  | sed 's/name: ocs-storagecluster-ceph-non-resilient-rbd/name: cephrbd-multizone-nr/' \
  | oc apply -f -

# Option B: edit and apply template
# manifests/storageclass-cephrbd-multizone-nr.yaml
oc apply -f manifests/storageclass-cephrbd-multizone-nr.yaml
```

Verify:

```bash
oc get storageclass cephrbd-multizone-nr -o jsonpath='binding={.volumeBindingMode}{"\n"}'
oc get storageclass cephrbd-multizone-nr -o jsonpath='{.parameters.topologyConstrainedPools}' | jq .
```

### 3 — Deploy

```bash
oc get storageclass | grep cephrbd-multizone
./03-deploy-postgres.sh    # interactive — lists only SCs that exist
```

---

## Which pool when?

| Use case | StorageClass |
|----------|--------------|
| Default Postgres data, survives OSD loss (Ceph replicated) | `cephrbd-multizone-r` |
| Volume must stay in the same zone as the pod | `cephrbd-multizone-nr` |
| App handles its own replication (3 isolated DBs) | `cephrbd-multizone-nr` |
| Your cluster has `flexibleScaling: true` / `failureDomain: host` | **`cephrbd-multizone-r` only** — see [`exchange/SOLUTION-ZONAL-RBD.md`](../../exchange/SOLUTION-ZONAL-RBD.md) |

---

## Cluster diagnosis

```bash
oc get cephblockpool -n openshift-storage
oc get storageclass | grep rbd
oc get storagecluster ocs-storagecluster -n openshift-storage -o yaml \
  | grep -E 'flexibleScaling|failureDomain|cephNonResilientPools'
```

| What you see | `cephrbd-multizone-r` | `cephrbd-multizone-nr` |
|--------------|----------------------|------------------------|
| Only `ocs-storagecluster-cephblockpool` (host) | ✅ Create now | ❌ Needs ODF zone topology |
| `ocs-storagecluster-ceph-non-resilient-rbd` exists | ✅ | ✅ Clone or template |
| `flexibleScaling: true` | ✅ | ❌ Redeploy ODF without flexibleScaling |

---

## Resilient pool (detail)

### Path A — no per-zone pools (most clusters)

Your cluster matches if `oc get cephblockpool` shows only:

```
ocs-storagecluster-cephblockpool   Ready   Replicated   host
```

Apply [`manifests/storageclass-cephrbd-multizone-r.yaml`](manifests/storageclass-cephrbd-multizone-r.yaml) or clone `ocs-storagecluster-ceph-rbd`.

Pod zone spread: [`02-label-nodes.sh`](02-label-nodes.sh). Volumes use the shared replicated pool.

```bash
./03-deploy-postgres.sh cephrbd-r
```

---

## Non-resilient pool (detail)

### Path B — zone-local volumes

**Full guide:** [`ZONE-LOCAL-RBD.md`](ZONE-LOCAL-RBD.md)

```bash
./03-deploy-postgres.sh cephrbd-nr
```

Uses [`manifests/statefulset-rbd-nr.yaml`](manifests/statefulset-rbd-nr.yaml).

---

## Verify CSI driver

```bash
./01-verify-csi-rbd.sh
```

---

## Quick PVC tests

**Resilient:**

```bash
oc create namespace sc-test --dry-run=client -o yaml | oc apply -f -
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-r
  namespace: sc-test
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cephrbd-multizone-r
  resources:
    requests:
      storage: 1Gi
EOF
oc get pvc -n sc-test -w
```

**Non-resilient** (needs a consuming pod — `WaitForFirstConsumer`):

```bash
# see ZONE-LOCAL-RBD.md § step 4
```

---

## CephFS vs RBD

| | **cephfs-multizone** | **cephrbd-multizone-r** | **cephrbd-multizone-nr** |
|---|---|---|---|
| Provisioner | cephfs | rbd | rbd |
| Zone-local | No | No | Yes |
| Ceph replication | Filesystem default | 3-way pool | Replica 1 per zone |
| Guide | [`STORAGECLASS.md`](STORAGECLASS.md) | this file | [`ZONE-LOCAL-RBD.md`](ZONE-LOCAL-RBD.md) |

---

## Cleanup

```bash
oc delete storageclass cephrbd-multizone-r cephrbd-multizone-nr --ignore-not-found
```

Or `./06-cleanup.sh` (removes all runbook StorageClasses).
