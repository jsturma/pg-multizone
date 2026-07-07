# Manual StorageClass setup — `cephrbd-multizone`

Use this path when you need **zone-local block volumes** for PostgreSQL.  
Unlike CephFS, the RBD CSI driver supports topology-aware provisioning with `WaitForFirstConsumer`.

> **Prerequisites**
> - ODF RBD CSI driver: `openshift-storage.rbd.csi.ceph.com`
> - Nodes labeled `topology.kubernetes.io/zone=zone-a|zone-b|zone-c` (run [`02-label-nodes.sh`](02-label-nodes.sh) first)
> - Per-zone Ceph block pools — **only for the topology template** (see below)

---

## Which path matches your cluster?

Check Ceph block pools:

```bash
oc get cephblockpool -n openshift-storage
oc get storageclass | grep rbd
```

| What you see | Path | Zone-local PVCs |
|--------------|------|-----------------|
| Only `ocs-storagecluster-cephblockpool` with `FAILUREDOMAIN: host` | [**Simple**](#path-a--simple-no-per-zone-pools) | No |
| `ocs-storagecluster-ceph-non-resilient-rbd` exists, or per-zone pools | [**Topology**](#path-b--topology-per-zone-pools) | Yes |

### Path A — Simple (no per-zone pools)

Your cluster matches this if `oc get cephblockpool` shows only host-level pools, for example:

```
NAME                               PHASE   TYPE         FAILUREDOMAIN
ocs-storagecluster-cephblockpool   Ready   Replicated   host
```

**Fastest — clone the ODF default RBD class:**

```bash
oc get storageclass ocs-storagecluster-ceph-rbd -o yaml \
  | sed 's/name: ocs-storagecluster-ceph-rbd/name: cephrbd-multizone/' \
  | oc apply -f -
```

**Or apply the bundled simple template** (same parameters as a standard ODF RBD cluster):

```bash
oc apply -f manifests/storageclass-cephrbd-multizone-simple.yaml
oc get storageclass cephrbd-multizone -o yaml
```

Uses `volumeBindingMode: Immediate` — no `topologyConstrainedPools`.  
PostgreSQL pods can still be spread across zones via [`02-label-nodes.sh`](02-label-nodes.sh); RBD volumes use the shared replicated pool.

Then deploy: `./deploy-rbd.sh` or `./03-deploy-postgres.sh cephrbd`

---

### Path B — Topology (per-zone pools)

Required for **zone-local block volumes** with `WaitForFirstConsumer`.

**Full guide:** [`ZONE-LOCAL-RBD.md`](ZONE-LOCAL-RBD.md) — prerequisites, ODF `cephNonResilientPools`, StorageClass, verification, and troubleshooting.

Quick summary:

1. Label nodes with `topology.kubernetes.io/zone`
2. Enable non-resilient pools: `oc patch storagecluster ocs-storagecluster … cephNonResilientPools/enable: true`
3. Wait for per-zone `cephblockpool` resources and `ocs-storagecluster-ceph-non-resilient-rbd`
4. Clone or apply `cephrbd-multizone` StorageClass
5. Deploy with `./deploy-rbd.sh`

---

## Step 1 — Verify the RBD CSI driver

```bash
oc get csidriver openshift-storage.rbd.csi.ceph.com
oc get pods -n openshift-storage | grep -i rbd
```

Optional automated check (recommends simple vs topology path):

```bash
./01-verify-csi-rbd.sh
```

---

## Step 2 — Check for an existing topology-aware StorageClass

Skip this if you already used [Path A — Simple](#path-a--simple-no-per-zone-pools).

ODF may already expose a non-resilient, topology-constrained RBD class after zone labels are applied:

```bash
oc get storageclass | grep rbd
oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd -o yaml
```

**If `ocs-storagecluster-ceph-non-resilient-rbd` exists**, the fastest path is to copy it and rename:

```bash
oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd -o yaml \
  | sed 's/name: ocs-storagecluster-ceph-non-resilient-rbd/name: cephrbd-multizone/' \
  | oc apply -f -
```

Skip to [step 4](#step-4--apply-and-verify) to verify.

---

## Step 3 — Build from the ODF default RBD class (manual template)

If no topology class exists yet, read parameters from the default RBD StorageClass:

```bash
oc get storageclass ocs-storagecluster-ceph-rbd -o yaml
```

Extract key values:

```bash
oc get storageclass ocs-storagecluster-ceph-rbd -o jsonpath='clusterID={.parameters.clusterID}{"\n"}pool={.parameters.pool}{"\n"}'
```

List per-zone pools (names vary by cluster — adjust the grep pattern):

```bash
oc get cephblockpool -n openshift-storage
# or inspect topologyConstrainedPools on ocs-storagecluster-ceph-non-resilient-rbd if present
```

Edit [`manifests/storageclass-cephrbd-multizone.yaml`](manifests/storageclass-cephrbd-multizone.yaml) (topology template only):

| Placeholder | Source |
|-------------|--------|
| `<CLUSTER_ID>` | `.parameters.clusterID` from `ocs-storagecluster-ceph-rbd` |
| `<POOL>` | `.parameters.pool` (base block pool) |
| `<POOL_ZONE_A>` | Ceph block pool for `zone-a` |
| `<POOL_ZONE_B>` | Ceph block pool for `zone-b` |
| `<POOL_ZONE_C>` | Ceph block pool for `zone-c` |

Copy any `csi.storage.k8s.io/*` secret parameters from the ODF default class if they differ from the template.

> **domainLabel** in `topologyConstrainedPools` must match how ODF created the pools.  
> This runbook uses `topology.kubernetes.io/zone` with values `zone-a`, `zone-b`, `zone-c` — consistent with [`02-label-nodes.sh`](02-label-nodes.sh).  
> If your ODF pools use a different label (e.g. `zone: us-east-1a`), align both node labels and `domainSegments` accordingly.

---

## Step 4 — Apply and verify

```bash
oc apply -f manifests/storageclass-cephrbd-multizone.yaml   # topology
# or
oc apply -f manifests/storageclass-cephrbd-multizone-simple.yaml  # simple
oc get storageclass cephrbd-multizone -o yaml
```

Confirm (topology path):

- `provisioner` is `openshift-storage.rbd.csi.ceph.com`
- `volumeBindingMode` is `WaitForFirstConsumer`
- `topologyConstrainedPools` lists one pool per zone
- `allowedTopologies` matches your node zone labels

Confirm (simple path):

- `volumeBindingMode` is `Immediate`
- `pool` is `ocs-storagecluster-cephblockpool` (or your cluster's RBD pool)
- no `topologyConstrainedPools`

---

## Step 5 — Deploy PostgreSQL with RBD storage

```bash
./deploy-rbd.sh
```

Or step by step:

```bash
./02-label-nodes.sh
STORAGE_CLASS=cephrbd-multizone ./03-deploy-postgres.sh
./04-verify.sh
./05-test-connection.sh
```

---

## Step 6 — Quick PVC test (optional)

PVC stays `Pending` until a pod consumes it (`WaitForFirstConsumer`):

```bash
oc create namespace sc-test --dry-run=client -o yaml | oc apply -f -
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-rbd
  namespace: sc-test
spec:
  nodeSelector:
    topology.kubernetes.io/zone: zone-a
  containers:
  - name: pause
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-rbd
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-rbd
  namespace: sc-test
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cephrbd-multizone
  resources:
    requests:
      storage: 1Gi
EOF

oc get pvc -n sc-test -w
# expect: Bound (after pod is scheduled)

oc delete namespace sc-test
```

---

## CephFS vs RBD — which to use?

| | **cephfs-multizone** | **cephrbd-multizone** |
|---|---|---|
| Provisioner | `openshift-storage.cephfs.csi.ceph.com` | `openshift-storage.rbd.csi.ceph.com` |
| Binding mode | `Immediate` | `Immediate` (simple) or `WaitForFirstConsumer` (topology) |
| Zone-local volume | No (shared filesystem) | No (simple) / Yes (topology) |
| Guide | [`STORAGECLASS.md`](STORAGECLASS.md) | this file |
| SC manifest | `storageclass-cephfs-multizone.yaml` | `storageclass-cephrbd-multizone-simple.yaml` or `-multizone.yaml` |
| Deploy script | [`deploy.sh`](deploy.sh) | [`deploy-rbd.sh`](deploy-rbd.sh) |

---

## Cleanup

```bash
oc delete storageclass cephrbd-multizone
```

Or: `STORAGE_CLASS=cephrbd-multizone ./06-cleanup.sh`
