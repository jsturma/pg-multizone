# Manual StorageClass setup — `cephfs-multizone`

The CephFS StorageClass must be created **manually** once per cluster.

> For RBD block volumes, see [`STORAGECLASS-RBD.md`](STORAGECLASS-RBD.md) (`cephrbd-multizone-r` resilient, `cephrbd-multizone-nr` zone-local).

> **CephFS and topology**  
> The CephFS CSI driver (`openshift-storage.cephfs.csi.ceph.com`) does **not** support `WaitForFirstConsumer` or zone-pinned provisioning.  
> Use `volumeBindingMode: Immediate` (same as the ODF default `ocs-storagecluster-cephfs` class).  
> Zone spread for PostgreSQL is handled by **node labels** and **pod affinity**, not by the StorageClass.

---

## Step 1 — Verify the CephFS CSI driver

```bash
oc get csidriver openshift-storage.cephfs.csi.ceph.com
oc get pods -n openshift-storage | grep -i cephfs
```

Optional automated check:

```bash
./01-verify-csi.sh
```

---

## Step 2 — Read parameters from the ODF default StorageClass

ODF ships a working CephFS StorageClass. Reuse its parameters:

```bash
oc get storageclass ocs-storagecluster-cephfs -o yaml
```

Extract the three values needed for your custom class:

```bash
oc get storageclass ocs-storagecluster-cephfs -o jsonpath='clusterID={.parameters.clusterID}{"\n"}fsName={.parameters.fsName}{"\n"}pool={.parameters.pool}{"\n"}'
```

Example output:

```
clusterID=abc123-def456-...
fsName=ocs-storagecluster-cephfilesystem
pool=ocs-storagecluster-cephfilesystem-data0
```

> If `ocs-storagecluster-cephfs` does not exist, list available classes with `oc get sc` and pick the one whose `provisioner` is `openshift-storage.cephfs.csi.ceph.com`.

---

## Step 3 — Edit the manifest template

Open [`manifests/topology/storageclass-cephfs-multizone.yaml`](manifests/topology/storageclass-cephfs-multizone.yaml) and replace the placeholders:

| Placeholder | Source |
|-------------|--------|
| `<CLUSTER_ID>` | `.parameters.clusterID` from step 2 |
| `<FS_NAME>` | `.parameters.fsName` from step 2 |
| `<POOL>` | `.parameters.pool` from step 2 |

If the ODF default class has extra parameters (e.g. `csi.storage.k8s.io/*` secrets), copy them into your manifest as well — they must match what the provisioner expects.

---

## Step 4 — Apply and verify

```bash
oc apply -f manifests/topology/storageclass-cephfs-multizone.yaml
oc get storageclass cephfs-multizone -o yaml
```

Confirm:

- `provisioner` is `openshift-storage.cephfs.csi.ceph.com`
- `volumeBindingMode` is `Immediate`
- parameters `clusterID`, `fsName`, and `pool` are set

---

## Step 5 — Quick PVC test (optional)

```bash
oc create namespace sc-test --dry-run=client -o yaml | oc apply -f -
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-cephfs
  namespace: sc-test
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cephfs-multizone
  resources:
    requests:
      storage: 1Gi
EOF

oc get pvc -n sc-test -w
# expect: Bound

oc delete namespace sc-test
```

---

## Cleanup

```bash
oc delete storageclass cephfs-multizone
```

Or use [`06-cleanup.sh`](06-cleanup.sh) which also removes the PostgreSQL namespace.
