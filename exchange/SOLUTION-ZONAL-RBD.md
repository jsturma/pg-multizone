# Zonal RBD — cluster analysis & proposed solution

Based on `exchange/cmd_out.txt` diagnostic output.

---

## Cluster profile

| Check | Your value | Impact |
|-------|------------|--------|
| RBD CSI | ✅ `openshift-storage.rbd.csi.ceph.com` | Driver OK |
| Block pools | `ocs-storagecluster-cephblockpool` — **FAILUREDOMAIN: host** | Resilient pool only |
| `flexibleScaling` | **`true`** | NR zone pools need ODF redeploy |
| `failureDomainKey` | **`kubernetes.io/hostname`** | Host-level, not zone |
| `cephNonResilientPools` | **not enabled** | No NR pools yet |
| Zone labels | ✅ ocp-node1/2/3 → zone-a/b/c | Pod scheduling OK |
| `ocs-storagecluster-ceph-non-resilient-rbd` | **not found** | NR path blocked |

---

## Proposed solution — both pools

Install **both** StorageClasses when possible. On this cluster, start with **resilient**; add **non-resilient** after ODF topology changes.

### Pool 1 — Resilient (`cephrbd-multizone-r`) — **do this now**

```bash
cd runbooks/openshift
oc apply -f manifests/storageclass-cephrbd-multizone-r.yaml
./02-label-nodes.sh
./03-deploy-postgres.sh cephrbd-r
```

| You get | You don't get |
|---------|----------------|
| RBD with 3-way Ceph replication | Zone-pinned volumes |

### Pool 2 — Non-resilient (`cephrbd-multizone-nr`) — **after ODF redeploy**

Requires `flexibleScaling: false` and zone failure domain. See [`ZONE-LOCAL-RBD.md`](../runbooks/openshift/ZONE-LOCAL-RBD.md).

```bash
# After ODF supports NR pools:
oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd -o yaml \
  | sed 's/name: ocs-storagecluster-ceph-non-resilient-rbd/name: cephrbd-multizone-nr/' \
  | oc apply -f -
./03-deploy-postgres.sh cephrbd-nr
```

---

## Verify both pools

```bash
oc get storageclass | grep cephrbd-multizone
# cephrbd-multizone-r    ← resilient (expect now)
# cephrbd-multizone-nr   ← non-resilient (after ODF NR setup)
./01-verify-csi-rbd.sh
```

---

## Decision matrix

| Goal | StorageClass |
|------|--------------|
| Postgres with Ceph data safety | `cephrbd-multizone-r` |
| Zone-local PVC | `cephrbd-multizone-nr` |
| Both on same cluster | Create **both** SCs; pick at deploy time |

## References

- [`STORAGECLASS-RBD.md`](../runbooks/openshift/STORAGECLASS-RBD.md) — both pools
- [`ZONE-LOCAL-RBD.md`](../runbooks/openshift/ZONE-LOCAL-RBD.md) — NR setup
