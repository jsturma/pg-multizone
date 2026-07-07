# 📋 Complete Runbook  
## Provision a **multi-zone Ceph StorageClass**, **label nodes**, then **deploy PostgreSQL** (one instance per zone: zone-a, zone-b, zone-c) on **OpenShift**.

All scripts and manifests live under [`runbooks/openshift/`](runbooks/openshift/).

Two storage backends are supported:

| StorageClass | Backend | Zone-local volumes | Guide |
|--------------|---------|-------------------|-------|
| `cephfs-multizone` | CephFS | No — shared filesystem | [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md) |
| `cephrbd-multizone-r` | RBD resilient (3-way pool) | No | [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md) |
| `cephrbd-multizone-nr` | RBD non-resilient (zone-local) | Yes — [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md) | [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md) |
| `ceph-external-zone-nr` | External Ceph zone-local RBD | Yes — [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md) | [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md) |

> **Platform support**  
> This project currently supports **OpenShift only**. The runbooks use OpenShift-specific resources (OCS, `oc`, Routes) and have been tested against OpenShift Container Storage.  
> Support for other Kubernetes platforms (vanilla Kubernetes, AKS, EKS, GKE, …) is **planned** — contributions and feedback are welcome.

> **CSI provisioners**  
> StorageClasses target OpenShift ODF drivers **`openshift-storage.cephfs.csi.ceph.com`** and **`openshift-storage.rbd.csi.ceph.com`**.  
> Other CSI provisioners are **planned**.

---

## 0️⃣  General Prerequisites  

| Item | Description | Verification |
|------|-------------|--------------|
| **OpenShift cluster** | v4.12 or later, with the *OpenShift Container Storage* (OCS) or *Rook-Ceph* operator already installed. | `oc get pods -n openshift-storage` – OCS/rook-ceph pods must be running. |
| **Admin access** | `cluster-admin` or a role able to create StorageClasses, label nodes, create PVCs, etc. | `oc whoami` → must return an authorized account. |
| **CSI CephFS driver** | `openshift-storage.cephfs.csi.ceph.com` — for `cephfs-multizone`. | `oc get csidriver openshift-storage.cephfs.csi.ceph.com` |
| **CSI RBD driver** | `openshift-storage.rbd.csi.ceph.com` — for `cephrbd-multizone-r` / `-nr`. | `oc get csidriver openshift-storage.rbd.csi.ceph.com` |
| **PostgreSQL images** | `registry.redhat.io/rhel9/postgresql-13` uses `POSTGRESQL_*` env vars (not `POSTGRES_*`). | `oc import-image registry.redhat.io/rhel9/postgresql-13 --dry-run=client` |
| **Tools** | `oc`, `jq`, `bash` (or PowerShell) on your workstation. | `oc version`, `jq --version` |

---

## Quick start

### Option A — CephFS (`cephfs-multizone`)

**1.** Create the StorageClass manually — [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md)

**2.** Deploy:

```bash
cd runbooks/openshift
./deploy.sh
```

### Option B — RBD resilient (`cephrbd-multizone-r`)

**1.** Create StorageClass — [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md)

**2.** Deploy: `./deploy-rbd.sh`

### Option C — RBD non-resilient / zone-local (`cephrbd-multizone-nr`)

**1.** Create both ODF NR pools and StorageClass — [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md)

**2.** Deploy: `./deploy-rbd-nr.sh`

### Option D — External Ceph zone-local (`ceph-external-zone-nr`)

When ODF cannot create per-zone pools (e.g. `flexibleScaling: true`), deploy or reuse an external Ceph cluster — [`External-Ceph-Cluster.md`](External-Ceph-Cluster.md).

**1.** Complete Ceph + CSI steps in the guide (Steps F.1–F.9 or 1, then 2–4).

**2.** Deploy PostgreSQL:

```bash
cd runbooks/openshift
oc apply -f manifests/configmap.yaml -f manifests/secret.yaml -f manifests/service.yaml
oc apply -f manifests/statefulset-external-rbd-nr.yaml
./04-verify.sh
```

### Steps reference

| Step | Script / doc | Description |
|------|--------------|-------------|
| 1a | [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md) | **Manual** — create `cephfs-multizone` |
| 1b | [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md) | **Manual** — create `cephrbd-multizone-r` and/or `-nr` |
| 1c | [`01-verify-csi.sh`](runbooks/openshift/01-verify-csi.sh) | Optional — verify CephFS CSI |
| 1d | [`01-verify-csi-rbd.sh`](runbooks/openshift/01-verify-csi-rbd.sh) | Optional — verify RBD CSI |
| 2 | [`02-label-nodes.sh`](runbooks/openshift/02-label-nodes.sh) | Label nodes `zone-a` / `zone-b` / `zone-c` |
| 3 | [`03-deploy-postgres.sh`](runbooks/openshift/03-deploy-postgres.sh) | Deploy PostgreSQL (`STORAGE_CLASS` env selects backend) |
| 4 | [`04-verify.sh`](runbooks/openshift/04-verify.sh) | Check pods, PVCs, zone placement |
| 5 | [`05-test-connection.sh`](runbooks/openshift/05-test-connection.sh) | Test PostgreSQL connectivity |
| 6 | [`06-cleanup.sh`](runbooks/openshift/06-cleanup.sh) | Delete namespace and StorageClass(s) |

---

## 1️⃣  Create the **`cephfs-multizone` StorageClass** (manual)

The StorageClass is **not** created by a script. Follow [`runbooks/openshift/STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md).

Summary:

1. **Verify** the CephFS CSI driver: `oc get csidriver openshift-storage.cephfs.csi.ceph.com`
2. **Copy parameters** from the ODF default class:
   ```bash
   oc get storageclass ocs-storagecluster-cephfs -o jsonpath='clusterID={.parameters.clusterID}{"\n"}fsName={.parameters.fsName}{"\n"}pool={.parameters.pool}{"\n"}'
   ```
3. **Edit** [`manifests/storageclass-cephfs-multizone.yaml`](runbooks/openshift/manifests/storageclass-cephfs-multizone.yaml) — replace `<CLUSTER_ID>`, `<FS_NAME>`, `<POOL>`
4. **Apply**: `oc apply -f manifests/storageclass-cephfs-multizone.yaml`

Use `volumeBindingMode: Immediate` (CephFS does not support `WaitForFirstConsumer`).

Optional CSI check: `./01-verify-csi.sh`

---

## 1️⃣b  Create RBD StorageClasses (manual)

Both pools are documented in [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md):

| Class | Purpose |
|-------|---------|
| `cephrbd-multizone-r` | Resilient 3-way replicated pool — works on your cluster today |
| `cephrbd-multizone-nr` | Non-resilient zone-local — see [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md) |

**Your cluster (resilient now):**

```bash
oc apply -f runbooks/openshift/manifests/storageclass-cephrbd-multizone-r.yaml
./03-deploy-postgres.sh cephrbd-r
```

---

## 2️⃣  **Label nodes** (zone-a, zone-b, zone-c)

```bash
./02-label-nodes.sh
```

> Ready worker nodes are discovered automatically and assigned round-robin to `zone-a`, `zone-b`, and `zone-c`.  
> If your cloud provider already sets `topology.kubernetes.io/zone`, skip this step.

> **Expected result** (excerpt):

```
NAME    STATUS   ROLES    AGE   VERSION   INTERNAL-IP   topology.kubernetes.io/zone
node01  Ready    worker   70d   v1.28.2   10.0.0.1      zone-a
node03  Ready    worker   70d   v1.28.2   10.0.0.3      zone-b
node05  Ready    worker   70d   v1.28.2   10.0.0.5      zone-c
```

---

## 3️⃣  Deploy **zone-aware** PostgreSQL

```bash
./deploy.sh          # CephFS — cephfs-multizone
./deploy-rbd.sh         # resilient — cephrbd-multizone-r
./deploy-rbd-nr.sh      # non-resilient — cephrbd-multizone-nr
```

Or interactively (lists `cephfs`, `cephrbd-r`, `cephrbd-nr` that exist in cluster):

```bash
./03-deploy-postgres.sh
./03-deploy-postgres.sh --help
```

Manifests applied from [`manifests/`](runbooks/openshift/manifests/):

| File | Resource |
|------|----------|
| [`configmap.yaml`](runbooks/openshift/manifests/configmap.yaml) | `POSTGRESQL_DATABASE` and `POSTGRESQL_USER` |
| [`secret.yaml`](runbooks/openshift/manifests/secret.yaml) | `POSTGRESQL_PASSWORD` |
| [`service.yaml`](runbooks/openshift/manifests/service.yaml) | Headless Service |
| [`statefulset.yaml`](runbooks/openshift/manifests/statefulset.yaml) | StatefulSet using `cephfs-multizone` |
| [`statefulset-rbd.yaml`](runbooks/openshift/manifests/statefulset-rbd.yaml) | StatefulSet using `cephrbd-multizone-r` |
| [`statefulset-rbd-nr.yaml`](runbooks/openshift/manifests/statefulset-rbd-nr.yaml) | StatefulSet using `cephrbd-multizone-nr` |
| [`route.yaml`](runbooks/openshift/manifests/route.yaml) | Optional Route (not applied by default) |

To also expose PostgreSQL via a Route:

```bash
APPLY_ROUTE=true ./03-deploy-postgres.sh
```

> ⚠️ In production, prefer placing **pgbouncer/HAProxy** in front and exposing **that** rather than the PostgreSQL pod directly.

---

## 4️⃣  Post-deployment verification

```bash
./04-verify.sh
./05-test-connection.sh
```

Expected pod placement (example):

```
NAME        READY   STATUS    RESTARTS   AGE   IP           NODE      NOMINATED NODE   READINESS GATES   ZONE
postgres-0  1/1     Running   0          2m    10.129.2.5   node01    <none>           <none>            zone-a
postgres-1  1/1     Running   0          2m    10.129.2.6   node03    <none>           <none>            zone-b
postgres-2  1/1     Running   0          2m    10.129.2.7   node05    <none>           <none>            zone-c
```

---

## 5️⃣  Cleanup

```bash
./06-cleanup.sh
```

---

## 6️⃣  Important notes & best practices (checklist)

| Topic | Recommendation |
|-------|----------------|
| **Password security** | Use *SealedSecrets*, *Vault*, or *OpenShift Secrets Encryption* in production. |
| **CephFS backup** | Create a `VolumeSnapshotClass` and schedule snapshots (`kubectl snapshot`). |
| **PostgreSQL high availability** | 3 isolated DBs per zone. Use `cephrbd-multizone-r` for Ceph replication, or `cephrbd-multizone-nr` with app-level HA. |
| **Zone-local storage** | Use `cephrbd-multizone-nr` — [`ZONE-LOCAL-RBD.md`](runbooks/openshift/ZONE-LOCAL-RBD.md). Resilient pool: `cephrbd-multizone-r`. |
| **Reclaim policy** | `Delete` removes the PV when the PVC is deleted. Use `Retain` if you want to keep the data. |
| **Monitoring** | Add the `postgres_exporter` sidecar or deploy a Prometheus DaemonSet to scrape metrics. |
| **CephFS tuning** | Check inter-zone latency; consider dedicated pools per zone if cross-zone traffic becomes a bottleneck. |
| **Scalability** | `allowVolumeExpansion: true` lets you grow the PVC via `oc patch pvc <pvc> -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'`. |
| **PostgreSQL version** | The `registry.redhat.io/rhel9/postgresql-13` image is an example. Replace it with the version that meets your requirements (14, 15, …). |

---

## 7️⃣  Directory layout

```
runbooks/openshift/
├── deploy.sh                      # CephFS path (cephfs-multizone)
├── deploy-rbd.sh                  # resilient (cephrbd-multizone-r)
├── deploy-rbd-nr.sh               # non-resilient (cephrbd-multizone-nr)
├── STORAGECLASS.md                # manual CephFS StorageClass guide
├── STORAGECLASS-RBD.md            # manual RBD StorageClass guide
├── ZONE-LOCAL-RBD.md              # true zone-local RBD (ODF topology pools)
├── 01-verify-csi.sh
├── 01-verify-csi-rbd.sh
├── 02-label-nodes.sh
├── 03-deploy-postgres.sh          # STORAGE_CLASS=cephfs-multizone|cephrbd-multizone
├── 04-verify.sh
├── 05-test-connection.sh
├── 06-cleanup.sh
└── manifests/
    ├── storageclass-cephfs-multizone.yaml
    ├── storageclass-cephrbd-multizone-r.yaml
    ├── storageclass-cephrbd-multizone-nr.yaml
    ├── storageclass-ceph-external-zone-nr.yaml   # external Ceph — External-Ceph-Cluster.md
    ├── configmap.yaml
    ├── secret.yaml
    ├── service.yaml
    ├── statefulset.yaml           # cephfs-multizone
    ├── statefulset-rbd.yaml       # cephrbd-multizone-r
    ├── statefulset-rbd-nr.yaml  # cephrbd-multizone-nr
    ├── statefulset-external-rbd-nr.yaml  # ceph-external-zone-nr
    └── route.yaml
```

---

### 🎉  You now have:

1. **StorageClasses** (`cephfs-multizone`, `cephrbd-multizone-r`, `cephrbd-multizone-nr`).  
2. **Properly labeled nodes** (`topology.kubernetes.io/zone`).  
3. A **PostgreSQL deployment** (3 replicas) with zone-aware pod placement — and zone-local block volumes when using RBD.  

Good luck, and feel free to automate this runbook in your CI/CD pipelines for each new cluster! 🚀
