# Complete Runbook

Provision a **multi-zone Ceph StorageClass**, **label nodes**, then **deploy PostgreSQL** (one instance per zone: zone-a, zone-b, zone-c) on **OpenShift**.

All scripts and manifests live under [`runbooks/openshift/`](runbooks/openshift/).

## Storage backends

| StorageClass | Backend | Zone-local volumes | CSI driver | Guide |
|--------------|---------|-------------------|------------|-------|
| `cephfs-multizone` | CephFS | No — shared filesystem | `openshift-storage.cephfs.csi.ceph.com` | [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md) |
| `cephrbd-multizone-r` | RBD resilient (3-way pool) | No | `openshift-storage.rbd.csi.ceph.com` | [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md) |
| `cephrbd-multizone-nr` | RBD non-resilient (ODF) | Yes | `openshift-storage.rbd.csi.ceph.com` | [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md) |
| `ceph-external-zone-nr` | External Ceph RBD | Yes | `rbd.csi.ceph.com` | [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md) |

> **Warning — `cephrbd-multizone-nr` (ODF non-resilient) changes the cluster**  
> This path is **not** a StorageClass-only step. It requires **ODF StorageCluster changes** and correct **zone topology at install time**:
>
> - **Patch** `StorageCluster` to enable `cephNonResilientPools` — ODF then creates **new per-zone replica-1** `CephBlockPool` resources.
> - **Label nodes** with `topology.kubernetes.io/zone` **before** enabling non-resilient pools (order matters).
> - **Blocked** on many existing clusters: `flexibleScaling: true` with `failureDomain: host` cannot create zone pools without **redeploying ODF** with zone topology. Diagnose first — [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md#0--diagnose-your-cluster).
> - **Data risk:** replica-1 volumes — OSD loss in a zone means **data loss** for volumes in that zone.
>
> If diagnosis shows NR pools are not supported, use **`cephrbd-multizone-r`** (resilient, no cluster change) or **Option D** — external Ceph ([`External-Ceph-Cluster.md`](External-Ceph-Cluster.md)).
>
> **Recommendation for zone-local volumes:** when ODF NR is blocked and you need true zone-pinned RBD, prefer a **[fresh Ceph install on 3 dedicated Linux nodes](External-Ceph-Cluster.md#fresh-install--ceph-on-3-linux-nodes)** (Option D, F.1–F.9) over patching an existing ODF-backed Ceph cluster. A dedicated cluster gives clean zone topology from day one, avoids CRUSH changes on the ODF storage layer, and does not require ODF redeploy. Use the [existing-cluster path](External-Ceph-Cluster.md#step-1--ceph-per-zone-pools-on-an-existing-cluster) only when you already operate a separate Ceph cluster you can extend.

> **Platform support**  
> This project currently supports **OpenShift only**. The runbooks use OpenShift-specific resources (OCS, `oc`, Routes) and have been tested against OpenShift Container Storage.  
> Support for other Kubernetes platforms (vanilla Kubernetes, AKS, EKS, GKE, …) is **planned**.

> **CSI provisioners**  
> ODF paths use **`openshift-storage.cephfs.csi.ceph.com`** and **`openshift-storage.rbd.csi.ceph.com`**.  
> The external Ceph path deploys a separate **`rbd.csi.ceph.com`** driver — see [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md).

---

## General prerequisites

| Item | Description | Verification |
|------|-------------|--------------|
| **OpenShift cluster** | v4.12 or later | `oc version` |
| **ODF / OCS** (Options A–C) | OpenShift Data Foundation or Rook-Ceph | `oc get pods -n openshift-storage` |
| **Admin access** | `cluster-admin` or equivalent | `oc whoami` |
| **CSI CephFS** (Option A) | `openshift-storage.cephfs.csi.ceph.com` | `oc get csidriver openshift-storage.cephfs.csi.ceph.com` |
| **CSI RBD** (Options B–C) | `openshift-storage.rbd.csi.ceph.com` | `oc get csidriver openshift-storage.rbd.csi.ceph.com` |
| **External Ceph** (Option D) | Separate Ceph cluster + `rbd.csi.ceph.com` | See [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md) pre-flight |
| **PostgreSQL image** | `registry.redhat.io/rhel9/postgresql-13` uses `POSTGRESQL_*` env vars | `oc import-image registry.redhat.io/rhel9/postgresql-13 --dry-run=client` |
| **Tools** | `oc`, `jq`, `bash` on your workstation | `oc version`, `jq --version` |

---

## Quick start

Pick **one** path. Each deploys 3 PostgreSQL replicas spread across `zone-a`, `zone-b`, and `zone-c`.

### Option A — CephFS (`cephfs-multizone`)

**1.** Create the StorageClass — [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md)

**2.** Deploy:

```bash
cd runbooks/openshift
./deploy.sh
```

### Option B — RBD resilient (`cephrbd-multizone-r`)

**1.** Create StorageClass — [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md)

**2.** Deploy:

```bash
cd runbooks/openshift
./deploy-rbd.sh
```

### Option C — RBD zone-local via ODF (`cephrbd-multizone-nr`)

> **Cluster changes required.** Read the warning above and run diagnosis in [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md#0--diagnose-your-cluster) before proceeding.

**1.** Label nodes, enable ODF non-resilient pools, create StorageClass — [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md)

Quick diagnosis:

```bash
oc get storagecluster ocs-storagecluster -n openshift-storage \
  -o jsonpath='flexibleScaling={.spec.flexibleScaling}{"\n"}failureDomain={.status.failureDomain}{"\n"}'
oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd 2>/dev/null || echo "NR StorageClass not found"
```

**2.** Deploy:

```bash
cd runbooks/openshift
./deploy-rbd-nr.sh
```

### Option D — RBD zone-local via external Ceph (`ceph-external-zone-nr`)

Use when ODF cannot create per-zone pools (e.g. `flexibleScaling: true`, `failureDomain: host` only).

> **Recommended:** [Fresh install — Ceph on 3 Linux nodes](External-Ceph-Cluster.md#fresh-install--ceph-on-3-linux-nodes) (F.1–F.9) on **dedicated storage hosts** — not OpenShift workers. Zone buckets and per-zone pools are created in the right order with no impact on ODF.  
> **Alternative:** [existing Ceph cluster](External-Ceph-Cluster.md#step-1--ceph-per-zone-pools-on-an-existing-cluster) (Step 1) only if you already run a separate Ceph cluster; skip Step 1 if you completed the fresh install.

**1.** Follow [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md):

| Situation | Start at |
|-----------|----------|
| No Ceph yet (recommended) | [F.1 — Prepare all three nodes](External-Ceph-Cluster.md#f1-prepare-all-three-nodes) |
| Ceph already running | [Step 1 — per-zone pools](External-Ceph-Cluster.md#step-1--ceph-per-zone-pools-on-an-existing-cluster) |

Then complete Steps 2–4 (Ceph-CSI, node labels, StorageClass).

**2.** Deploy PostgreSQL:

```bash
cd runbooks/openshift
oc create namespace pg-multizone 2>/dev/null || true
oc apply -f manifests/configmap.yaml -f manifests/secret.yaml -f manifests/service.yaml
oc apply -f manifests/statefulset-external-rbd-nr.yaml
./04-verify.sh
./05-test-connection.sh
```

> Option D does **not** use `03-deploy-postgres.sh` — that script targets ODF StorageClasses only.

### Steps reference (Options A–C)

| Step | Script / doc | Description |
|------|--------------|-------------|
| 1a | [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md) | Manual — create `cephfs-multizone` |
| 1b | [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md) | Manual — create `cephrbd-multizone-r` and/or `-nr` |
| 1c | [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md) | ODF per-zone pools for `cephrbd-multizone-nr` |
| 1d | [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md) | External Ceph + `ceph-external-zone-nr` (Option D) |
| 1e | [`01-verify-csi.sh`](runbooks/openshift/01-verify-csi.sh) | Optional — verify CephFS CSI |
| 1f | [`01-verify-csi-rbd.sh`](runbooks/openshift/01-verify-csi-rbd.sh) | Optional — verify ODF RBD CSI |
| 2 | [`02-label-nodes.sh`](runbooks/openshift/02-label-nodes.sh) | Label nodes `zone-a` / `zone-b` / `zone-c` |
| 3 | [`03-deploy-postgres.sh`](runbooks/openshift/03-deploy-postgres.sh) | Deploy PostgreSQL (interactive backend selection) |
| 4 | [`04-verify.sh`](runbooks/openshift/04-verify.sh) | Check pods, PVCs, zone placement |
| 5 | [`05-test-connection.sh`](runbooks/openshift/05-test-connection.sh) | Test PostgreSQL connectivity |
| 6 | [`06-cleanup.sh`](runbooks/openshift/06-cleanup.sh) | Delete namespace and StorageClass(s) |

---

## Create StorageClasses (manual)

StorageClasses are **not** created by deploy scripts. Apply the manifest after editing placeholders (ODF paths) or follow the external guide (Option D).

### CephFS — `cephfs-multizone`

Follow [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md):

1. Verify CSI: `oc get csidriver openshift-storage.cephfs.csi.ceph.com`
2. Copy parameters from ODF:
   ```bash
   oc get storageclass ocs-storagecluster-cephfs -o jsonpath='clusterID={.parameters.clusterID}{"\n"}fsName={.parameters.fsName}{"\n"}pool={.parameters.pool}{"\n"}'
   ```
3. Edit [`manifests/storageclass-cephfs-multizone.yaml`](runbooks/openshift/manifests/storageclass-cephfs-multizone.yaml)
4. Apply: `oc apply -f manifests/storageclass-cephfs-multizone.yaml`

Use `volumeBindingMode: Immediate` (CephFS does not support `WaitForFirstConsumer`).

### RBD — ODF (`cephrbd-multizone-r` / `cephrbd-multizone-nr`)

Documented in [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md):

| Class | Purpose |
|-------|---------|
| `cephrbd-multizone-r` | Resilient 3-way replicated pool — works on most ODF clusters today |
| `cephrbd-multizone-nr` | Zone-local, replica-1 — **patches StorageCluster**, creates per-zone ODF pools ([`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md)) |

> **`cephrbd-multizone-nr` only** — enables `cephNonResilientPools` on the ODF `StorageCluster`, waits for new zone-scoped `CephBlockPool` objects, then clones `ocs-storagecluster-ceph-non-resilient-rbd`. Not available when `flexibleScaling: true` / `failureDomain: host`; use `cephrbd-multizone-r` or [Option D](External-Ceph-Cluster.md) instead.

Quick start (resilient):

```bash
oc apply -f runbooks/openshift/manifests/storageclass-cephrbd-multizone-r.yaml
cd runbooks/openshift && ./03-deploy-postgres.sh cephrbd-r
```

### RBD — external Ceph (`ceph-external-zone-nr`)

Full end-to-end guide: [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md).

```bash
oc apply -f runbooks/openshift/manifests/storageclass-ceph-external-zone-nr.yaml
```

Prerequisites: Ceph pools `rbd-zone-a/b/c`, Ceph-CSI in `external-ceph-csi`, node zone labels.

---

## Label nodes (zone-a, zone-b, zone-c)

Canonical zone names: [`topology/zones.env`](runbooks/openshift/topology/zones.env) (must match Ceph CRUSH buckets and StorageClass `topologyConstrainedPools`).

```bash
cd runbooks/openshift
./02-label-nodes.sh
./topology/verify-alignment.sh
```

Ready worker nodes are discovered automatically and assigned round-robin to `zone-a`, `zone-b`, and `zone-c`.

If your cloud provider already sets `topology.kubernetes.io/zone`, align Ceph CRUSH zone names with those values instead of overwriting labels.

**Expected result** (excerpt):

```
NAME    STATUS   ROLES    AGE   VERSION   INTERNAL-IP   topology.kubernetes.io/zone
node01  Ready    worker   70d   v1.28.2   10.0.0.1      zone-a
node03  Ready    worker   70d   v1.28.2   10.0.0.3      zone-b
node05  Ready    worker   70d   v1.28.2   10.0.0.5      zone-c
```

---

## Deploy zone-aware PostgreSQL

### ODF paths (Options A–C)

```bash
cd runbooks/openshift
./deploy.sh              # CephFS — cephfs-multizone
./deploy-rbd.sh            # resilient — cephrbd-multizone-r
./deploy-rbd-nr.sh         # zone-local ODF — cephrbd-multizone-nr
```

Or interactively (only backends whose StorageClass exists in the cluster):

```bash
./03-deploy-postgres.sh
./03-deploy-postgres.sh --help
```

### Manifests

| File | StorageClass | Used by |
|------|--------------|---------|
| [`configmap.yaml`](runbooks/openshift/manifests/configmap.yaml) | — | All paths |
| [`secret.yaml`](runbooks/openshift/manifests/secret.yaml) | — | All paths |
| [`service.yaml`](runbooks/openshift/manifests/service.yaml) | — | All paths |
| [`statefulset.yaml`](runbooks/openshift/manifests/statefulset.yaml) | `cephfs-multizone` | `deploy.sh` / `cephfs` |
| [`statefulset-rbd.yaml`](runbooks/openshift/manifests/statefulset-rbd.yaml) | `cephrbd-multizone-r` | `deploy-rbd.sh` / `cephrbd-r` |
| [`statefulset-rbd-nr.yaml`](runbooks/openshift/manifests/statefulset-rbd-nr.yaml) | `cephrbd-multizone-nr` | `deploy-rbd-nr.sh` / `cephrbd-nr` |
| [`statefulset-external-rbd-nr.yaml`](runbooks/openshift/manifests/statefulset-external-rbd-nr.yaml) | `ceph-external-zone-nr` | Option D |
| [`route.yaml`](runbooks/openshift/manifests/route.yaml) | — | Optional |

Expose via Route (ODF paths only):

```bash
APPLY_ROUTE=true ./03-deploy-postgres.sh
```

In production, prefer **pgbouncer/HAProxy** in front rather than exposing PostgreSQL directly.

---

## Post-deployment verification

```bash
cd runbooks/openshift
./04-verify.sh
./05-test-connection.sh
```

Expected pod placement (example):

```
NAME        READY   STATUS    RESTARTS   AGE   IP           NODE      ZONE
postgres-0  1/1     Running   0          2m    10.129.2.5   node01    zone-a
postgres-1  1/1     Running   0          2m    10.129.2.6   node03    zone-b
postgres-2  1/1     Running   0          2m    10.129.2.7   node05    zone-c
```

---

## Cleanup

```bash
cd runbooks/openshift
./06-cleanup.sh
```

For Option D, tear down external Ceph zone resources and start over:

```bash
cd runbooks/openshift
CONFIRM=yes FULL=true ./06-cleanup-external-ceph.sh
./topology/verify-k8s-clean.sh
# On Ceph admin node:
CONFIRM=yes ./topology/reset-ceph-zones.sh --with-csi-user --with-orch-labels
```

Full procedure: [`External-Ceph-Cluster.md` § Rollback and reset](External-Ceph-Cluster.md#rollback-and-reset-start-from-zero).

---

## Best practices

| Topic | Recommendation |
|-------|----------------|
| **Password security** | Use SealedSecrets, Vault, or OpenShift Secrets Encryption in production. |
| **CephFS backup** | Create a `VolumeSnapshotClass` and schedule snapshots. |
| **PostgreSQL HA** | 3 isolated DBs per zone. Use `cephrbd-multizone-r` for Ceph replication, or zone-local RBD with app-level HA. |
| **Zone-local storage** | ODF: `cephrbd-multizone-nr` — **requires StorageCluster patch** and zone topology ([`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md)). If blocked: **fresh external Ceph on 3 nodes** ([`External-Ceph-Cluster.md` § Fresh install](External-Ceph-Cluster.md#fresh-install--ceph-on-3-linux-nodes)) — preferred over ODF redeploy or sharing ODF's Ceph. |
| **Resilient storage** | `cephrbd-multizone-r` — replicas across zones, not zone-pinned. |
| **Reclaim policy** | `Delete` removes the PV when the PVC is deleted. Use `Retain` to keep data. |
| **Monitoring** | Add `postgres_exporter` or Prometheus scraping. |
| **Scalability** | `allowVolumeExpansion: true` — grow PVCs with `oc patch pvc`. |
| **PostgreSQL version** | `postgresql-13` is an example; use 14, 15, … as needed. |

---

## Directory layout

```
pg-multizone/
├── README.md
├── External-Ceph-Cluster.md         # Option D — fresh or existing external Ceph
├── rbd-ceph-csi-deployment.md         # Résumé FR — topologie CSI RBD (pointe vers External-Ceph-Cluster.md)
└── runbooks/openshift/
    ├── deploy.sh                    # CephFS (cephfs-multizone)
    ├── deploy-rbd.sh                # resilient (cephrbd-multizone-r)
    ├── deploy-rbd-nr.sh             # ODF zone-local (cephrbd-multizone-nr)
    ├── STORAGECLASS.md
    ├── STORAGECLASS-RBD.md
    ├── ZONE-LOCAL-RBD.md
    ├── 01-verify-csi.sh
    ├── 01-verify-csi-rbd.sh
    ├── 02-label-nodes.sh            # sources topology/zones.env
    ├── topology/
    │   ├── zones.env                # canonical zone-a/b/c ↔ rbd-zone-* mapping
    │   ├── verify-alignment.sh      # OpenShift labels + manifests
    │   ├── verify-k8s-clean.sh      # post-cleanup K8s verification
    │   ├── verify-ceph-topology.sh  # Ceph CRUSH + pools (admin node)
    │   └── reset-ceph-zones.sh      # Ceph pools + CRUSH rollback
    ├── 03-deploy-postgres.sh      # Options A–C only
    ├── 04-verify.sh
    ├── 05-test-connection.sh
    ├── 06-cleanup.sh
    ├── 06-cleanup-external-ceph.sh  # Option D — OpenShift reset
    └── manifests/
        ├── storageclass-cephfs-multizone.yaml
        ├── storageclass-cephrbd-multizone-r.yaml
        ├── storageclass-cephrbd-multizone-nr.yaml
        ├── storageclass-ceph-external-zone-nr.yaml
        ├── configmap.yaml
        ├── secret.yaml
        ├── service.yaml
        ├── statefulset.yaml
        ├── statefulset-rbd.yaml
        ├── statefulset-rbd-nr.yaml
        ├── statefulset-external-rbd-nr.yaml
        └── route.yaml
```

---

## Outcome

After completing any path you have:

1. A **StorageClass** for your chosen backend.
2. **Labeled nodes** (`topology.kubernetes.io/zone`).
3. **PostgreSQL** (3 replicas) with zone-aware pod placement — and zone-local block volumes when using RBD NR or external Ceph.
