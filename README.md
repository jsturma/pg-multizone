# 📋 Complete Runbook  
## Provision a **multi-zone CephFS StorageClass**, **label nodes**, then **deploy a PostgreSQL database** (one instance per zone: zone-a, zone-b, zone-c) on **OpenShift**.

All scripts and manifests live under [`runbooks/openshift/`](runbooks/openshift/).

> **Platform support**  
> This project currently supports **OpenShift only**. The runbooks use OpenShift-specific resources (OCS, `oc`, Routes) and have been tested against OpenShift Container Storage.  
> Support for other Kubernetes platforms (vanilla Kubernetes, AKS, EKS, GKE, …) is **planned** — contributions and feedback are welcome.

> **CSI provisioner**  
> StorageClass generation currently targets the OpenShift CephFS driver **`openshift-storage.cephfs.csi.ceph.com`** only.  
> Support for other CephFS CSI provisioners (e.g. `rook-ceph.cephfs.csi.ceph.com`) is **planned**.

---

## 0️⃣  General Prerequisites  

| Item | Description | Verification |
|------|-------------|--------------|
| **OpenShift cluster** | v4.12 or later, with the *OpenShift Container Storage* (OCS) or *Rook-Ceph* operator already installed. | `oc get pods -n openshift-storage` – OCS/rook-ceph pods must be running. |
| **Admin access** | `cluster-admin` or a role able to create StorageClasses, label nodes, create PVCs, etc. | `oc whoami` → must return an authorized account. |
| **CSI CephFS driver** | `openshift-storage.cephfs.csi.ceph.com` (OpenShift OCS) must be present. Other provisioners are not supported yet. | `oc get csinodes` → the driver must appear. |
| **PostgreSQL images** | E.g. `registry.redhat.io/rhel9/postgresql-13` (or other) available from the cluster registry. | `oc import-image registry.redhat.io/rhel9/postgresql-13 --dry-run=client` |
| **Tools** | `oc`, `jq`, `bash` (or PowerShell) on your workstation. | `oc version`, `jq --version` |

---

## Quick start

```bash
cd runbooks/openshift
./deploy.sh
```

Or run each step individually:

| Step | Script | Description |
|------|--------|-------------|
| 1 | [`01-create-storageclass.sh`](runbooks/openshift/01-create-storageclass.sh) | Ensure Ceph toolbox, extract Ceph params, generate & apply StorageClass |
| 2 | [`02-label-nodes.sh`](runbooks/openshift/02-label-nodes.sh) | Discover Ready nodes and label them `zone-a` / `zone-b` / `zone-c` |
| 3 | [`03-deploy-postgres.sh`](runbooks/openshift/03-deploy-postgres.sh) | Create namespace and apply PostgreSQL manifests |
| 4 | [`04-verify.sh`](runbooks/openshift/04-verify.sh) | Check pods, PVCs, and zone placement |
| 5 | [`05-test-connection.sh`](runbooks/openshift/05-test-connection.sh) | Run a client pod and query PostgreSQL |
| 6 | [`06-cleanup.sh`](runbooks/openshift/06-cleanup.sh) | Delete namespace and generated StorageClass |

---

## 1️⃣  Create the **`cephfs-multizone` StorageClass**

```bash
./01-create-storageclass.sh
```

This script:
1. Verifies the CephFS CSI driver (`openshift-storage.cephfs.csi.ceph.com`) is registered and running
2. Ensures a **rook-ceph-tools** pod exists ([`manifests/rook-ceph-tools.yaml`](runbooks/openshift/manifests/rook-ceph-tools.yaml))
3. Retrieves `clusterID`, `fsName`, and `pool` from Ceph
4. Writes a cluster-specific manifest to `generated/cephfs-multizone.yaml` using provisioner `openshift-storage.cephfs.csi.ceph.com` and applies it

Override defaults if needed:

```bash
CEPH_NS=openshift-storage \
CEPHFS_PROVISIONER=openshift-storage.cephfs.csi.ceph.com \
./01-create-storageclass.sh
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
./03-deploy-postgres.sh
```

Manifests applied from [`manifests/`](runbooks/openshift/manifests/):

| File | Resource |
|------|----------|
| [`configmap.yaml`](runbooks/openshift/manifests/configmap.yaml) | Database name and user |
| [`secret.yaml`](runbooks/openshift/manifests/secret.yaml) | `POSTGRES_PASSWORD` |
| [`service.yaml`](runbooks/openshift/manifests/service.yaml) | Headless Service |
| [`statefulset.yaml`](runbooks/openshift/manifests/statefulset.yaml) | 3-replica StatefulSet (one per zone) |
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
| **PostgreSQL high availability** | The model above creates **3 isolated databases**. If you need master-slave replication or a cluster, deploy a *PostgreSQL Operator* (CrunchyData, Zalando Patroni) and set `storageClassName` to `cephfs-multizone`. |
| **Reclaim policy** | `Delete` removes the PV when the PVC is deleted. Use `Retain` if you want to keep the data. |
| **Monitoring** | Add the `postgres_exporter` sidecar or deploy a Prometheus DaemonSet to scrape metrics. |
| **CephFS tuning** | Check inter-zone latency; consider dedicated pools per zone if cross-zone traffic becomes a bottleneck. |
| **Scalability** | `allowVolumeExpansion: true` lets you grow the PVC via `oc patch pvc <pvc> -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'`. |
| **PostgreSQL version** | The `registry.redhat.io/rhel9/postgresql-13` image is an example. Replace it with the version that meets your requirements (14, 15, …). |

---

## 7️⃣  Directory layout

```
runbooks/openshift/
├── deploy.sh                  # run steps 1–4
├── 01-create-storageclass.sh
├── 02-label-nodes.sh
├── 03-deploy-postgres.sh
├── 04-verify.sh
├── 05-test-connection.sh
├── 06-cleanup.sh
├── manifests/
│   ├── rook-ceph-tools.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── service.yaml
│   ├── statefulset.yaml
│   └── route.yaml
└── generated/                 # created at runtime (cluster-specific StorageClass)
    └── cephfs-multizone.yaml
```

---

### 🎉  You now have:

1. A **CephFS StorageClass** that ensures each volume is created in the zone where the pod is scheduled.  
2. **Properly labeled nodes** (`topology.kubernetes.io/zone`).  
3. A **PostgreSQL deployment** (3 replicas, one per zone) that uses this StorageClass and benefits from zone-aware placement.  

Good luck, and feel free to automate this runbook in your CI/CD pipelines for each new cluster! 🚀
