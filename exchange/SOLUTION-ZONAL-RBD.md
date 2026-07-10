# Zonal RBD — cluster analysis & proposed solution

Based on `exchange/cmd_out.txt` diagnostic output.

---

## Cluster profile

| Check | Your value | Impact |
|-------|------------|--------|
| RBD CSI | ✅ `openshift-storage.rbd.csi.ceph.com` | Driver OK |
| Block pools | `ocs-storagecluster-cephblockpool` — **FAILUREDOMAIN: host** | No per-zone pools |
| `flexibleScaling` | **`true`** | ODF uses host-level CRUSH; **zone labels ignored for pools** |
| `failureDomain` | **`host`** | Not `zone` |
| `failureDomainKey` | **`kubernetes.io/hostname`** | Pools keyed by host, not `topology.kubernetes.io/zone` |
| `cephNonResilientPools` | **not enabled** (`{}`) | No replica-1 topology SC |
| Zone labels | ✅ `ocp-node1→zone-a`, `ocp-node2→zone-b`, `ocp-node3→zone-c` | Good for **pod** scheduling only |
| `ocs-storagecluster-ceph-non-resilient-rbd` | **not found** | Topology path not available |

**Conclusion:** True zone-local RBD (`WaitForFirstConsumer` + `topologyConstrainedPools` per zone) **cannot be enabled on this StorageCluster as-is**.  
`flexibleScaling: true` was set at ODF install and pins failure domain to **host**; Red Hat documents this as **not changeable in flight**.

---

## Proposed solution

### Option 1 — Use now (no ODF changes): simple RBD + pod zone spread

Best fit for this cluster today. Block storage works; pods spread across zones; volumes are **not** zone-pinned.

```bash
cd runbooks/openshift

# StorageClass (clone ODF default RBD)
oc get storageclass ocs-storagecluster-ceph-rbd -o yaml \
  | sed 's/name: ocs-storagecluster-ceph-rbd/name: cephrbd-multizone/' \
  | oc apply -f -
# or: oc apply -f manifests/topology/storageclass-cephrbd-multizone-simple.yaml

./02-label-nodes.sh          # already labeled zone-a/b/c — safe to re-run
./03-deploy-postgres.sh cephrbd
```

| You get | You don't get |
|---------|----------------|
| RBD block volumes (3-way replicated Ceph pool) | Volume pinned to pod zone |
| Postgres pods schedulable per zone (node affinity) | `ocs-storagecluster-ceph-non-resilient-rbd` behaviour |

---

### Option 2 — Do not rely on: patch `cephNonResilientPools` only

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage --type json \
  --patch '[{"op": "replace", "path": "/spec/managedResources/cephNonResilientPools/enable", "value": true}]'
```

On **this** cluster, ODF will likely create **per-host** replica-1 pools (`failureDomainKey: kubernetes.io/hostname`), not per `zone-a/b/c`.  
The topology StorageClass in this repo expects **zone** `domainSegments` — provisioning would fail or mis-route unless you hand-craft `topologyConstrainedPools` to map each zone to the pool on the node in that zone (fragile; 1:1 node↔zone only works on your 3-node compact layout).

**Not recommended** as a stable zonal-RBD solution.

---

### Option 3 — True zonal RBD (requires ODF redeploy)

To get real zone-local volumes, plan a **new ODF deployment** (or new cluster):

1. **Before** installing ODF, label all storage nodes:
   ```bash
   oc label node ocp-node1 topology.kubernetes.io/zone=zone-a --overwrite
   oc label node ocp-node2 topology.kubernetes.io/zone=zone-b --overwrite
   oc label node ocp-node3 topology.kubernetes.io/zone=zone-c --overwrite
   ```

2. Install ODF with **`flexibleScaling: false`** (default) so `failureDomain` becomes **`zone`** when zone labels exist.

3. Confirm after install:
   ```bash
   oc get storagecluster ocs-storagecluster -n openshift-storage \
     -o jsonpath='flexibleScaling={.spec.flexibleScaling} failureDomain={.status.failureDomain}{"\n"}'
   # expect: flexibleScaling=false failureDomain=zone
   ```

4. Enable non-resilient pools (see [`ZONE-LOCAL-RBD.md`](../runbooks/openshift/ZONE-LOCAL-RBD.md)):
   ```bash
   oc patch storagecluster ocs-storagecluster -n openshift-storage --type json \
     --patch '[{"op": "replace", "path": "/spec/managedResources/cephNonResilientPools/enable", "value": true}]'
   ```

5. Verify `ocs-storagecluster-ceph-non-resilient-rbd` and per-zone `cephblockpool`, then:
   ```bash
   oc get storageclass ocs-storagecluster-ceph-non-resilient-rbd -o yaml \
     | sed 's/name: ocs-storagecluster-ceph-non-resilient-rbd/name: cephrbd-multizone/' \
     | oc apply -f -
   ./deploy-rbd.sh
   ```

**Compact cluster note:** All three nodes are `control-plane,master,worker`. Supported for dev/lab; production stretch/topology designs usually separate workers and storage capacity per zone.

---

## Decision matrix

| Goal | Action |
|------|--------|
| Run Postgres multi-zone **now** on existing ODF | **Option 1** — `storageclass-cephrbd-multizone-simple.yaml` |
| Minimize change, shared replicated storage | Option 1 or `cephfs-multizone` |
| PVC must live in same AZ as pod | **Option 3** — redeploy ODF without `flexibleScaling` |
| Quick test patch only | Option 2 — expect host pools, not zone pools |

---

## Verify after Option 1

```bash
oc get storageclass cephrbd-multizone
oc get pods,pvc -n pg-multizone -o wide
oc get nodes -L topology.kubernetes.io/zone
```

## References

- [`runbooks/openshift/ZONE-LOCAL-RBD.md`](../runbooks/openshift/ZONE-LOCAL-RBD.md)
- [`runbooks/openshift/STORAGECLASS-RBD.md`](../runbooks/openshift/STORAGECLASS-RBD.md) — Path A (simple)
- [ODF topology considerations](https://developers.redhat.com/articles/2024/06/19/red-hat-openshift-data-foundation-topology-considerations)
