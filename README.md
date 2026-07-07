# 📋 Complete Runbook  
## Provision a **multi-zone Ceph StorageClass**, **label nodes**, then **deploy PostgreSQL** (one instance per zone: zone-a, zone-b, zone-c) on **OpenShift**.

All scripts and manifests live under [`runbooks/openshift/`](runbooks/openshift/).

Two storage backends are supported:

| StorageClass | Backend | Zone-local volumes | Guide |
|--------------|---------|-------------------|-------|
| `cephfs-multizone` | CephFS | No — shared filesystem | [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md) |
| `cephrbd-multizone` | RBD block | Yes — `WaitForFirstConsumer` + topology pools | [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md) |

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
| **CSI RBD driver** | `openshift-storage.rbd.csi.ceph.com` — for `cephrbd-multizone`. | `oc get csidriver openshift-storage.rbd.csi.ceph.com` |
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

### Option B — RBD (`cephrbd-multizone`, zone-local volumes)

**1.** Label nodes, then create the StorageClass — [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md)

**2.** Deploy:

```bash
cd runbooks/openshift
./deploy-rbd.sh
```

### Steps reference

| Step | Script / doc | Description |
|------|--------------|-------------|
| 1a | [`STORAGECLASS.md`](runbooks/openshift/STORAGECLASS.md) | **Manual** — create `cephfs-multizone` |
| 1b | [`STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md) | **Manual** — create `cephrbd-multizone` |
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

## 1️⃣b  Create the **`cephrbd-multizone` StorageClass** (manual)

Follow [`runbooks/openshift/STORAGECLASS-RBD.md`](runbooks/openshift/STORAGECLASS-RBD.md).

Summary:

1. **Verify** the RBD CSI driver: `oc get csidriver openshift-storage.rbd.csi.ceph.com`
2. **Copy** from `ocs-storagecluster-ceph-non-resilient-rbd` if it exists (topology-aware), or build from [`manifests/storageclass-cephrbd-multizone.yaml`](runbooks/openshift/manifests/storageclass-cephrbd-multizone.yaml)
3. Set `topologyConstrainedPools` with one block pool per zone (`zone-a`, `zone-b`, `zone-c`)
4. **Apply**: `oc apply -f manifests/storageclass-cephrbd-multizone.yaml`

Uses `volumeBindingMode: WaitForFirstConsumer` — PVCs provision in the same zone as the scheduled pod.

Optional CSI check: `./01-verify-csi-rbd.sh`  
Deploy: `./deploy-rbd.sh`

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
./deploy-rbd.sh      # RBD    — cephrbd-multizone
```

Or interactively (prompts for `cephfs` or `cephrbd`):

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
| [`statefulset-rbd.yaml`](runbooks/openshift/manifests/statefulset-rbd.yaml) | StatefulSet using `cephrbd-multizone` |
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
| **PostgreSQL high availability** | The model above creates **3 isolated databases**. For replication/clustering, use a PostgreSQL Operator and set `storageClassName` to `cephfs-multizone` or `cephrbd-multizone`. |
| **Zone-local storage** | Prefer **`cephrbd-multizone`** (RBD) over CephFS when volumes must be provisioned in the pod's zone. |
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
├── deploy-rbd.sh                  # RBD path (cephrbd-multizone)
├── STORAGECLASS.md                # manual CephFS StorageClass guide
├── STORAGECLASS-RBD.md            # manual RBD StorageClass guide
├── 01-verify-csi.sh
├── 01-verify-csi-rbd.sh
├── 02-label-nodes.sh
├── 03-deploy-postgres.sh          # STORAGE_CLASS=cephfs-multizone|cephrbd-multizone
├── 04-verify.sh
├── 05-test-connection.sh
├── 06-cleanup.sh
└── manifests/
    ├── storageclass-cephfs-multizone.yaml
    ├── storageclass-cephrbd-multizone.yaml
    ├── configmap.yaml
    ├── secret.yaml
    ├── service.yaml
    ├── statefulset.yaml           # cephfs-multizone
    ├── statefulset-rbd.yaml       # cephrbd-multizone
    └── route.yaml
```

---

### 🎉  You now have:

1. A **multi-zone StorageClass** (`cephfs-multizone` or `cephrbd-multizone`).  
2. **Properly labeled nodes** (`topology.kubernetes.io/zone`).  
3. A **PostgreSQL deployment** (3 replicas) with zone-aware pod placement — and zone-local block volumes when using RBD.  

Good luck, and feel free to automate this runbook in your CI/CD pipelines for each new cluster! 🚀
