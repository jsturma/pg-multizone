The root cause of these cascading errors boils down to a fundamental misunderstanding of how the `ceph osd crush rule create-replicated` command interprets its arguments.

The syntax for that command is:

```bash
ceph osd crush rule create-replicated <rule-name> <root> <failure-domain-type> [<class>]

```

The error **`Error EINVAL: unknown type zone-a`** happens because Ceph expects the 4th argument to be a **CRUSH bucket type** (like `root`, `region`, `zone`, `host`, or `osd`), but you passed the *literal name* of your zone bucket (`zone-a`). Because `zone-a` failed to create the rule, the subsequent pool creation and property commands failed with `ENOENT`.

---

### The Fix

If your intended CRUSH hierarchy is `default (root) -> zone-a/b/c (zone) -> ceph-node1/2/3 (host)`, you need to tell Ceph that your failure domain type is **`zone`**, not `host`.

Here is the corrected script:

```bash
sudo cephadm shell -- bash -c '
for z in zone-a zone-b zone-c; do
  # 1. Create the rule pointing to "default" root, with failure domain set to "zone"
  ceph osd crush rule create-replicated "replicated-${z}" default zone
  
  # 2. Create the pool using the new rule
  ceph osd pool create "rbd-${z}" 32 32 "replicated-${z}"
  
  # 3. Set sizes and enable the RBD application
  ceph osd pool set "rbd-${z}" size 1
  ceph osd pool set "rbd-${z}" min_size 1
  ceph osd pool application enable "rbd-${z}" rbd
done
ceph osd pool ls detail | grep rbd
'

```

### 💡 A Critical Warning on Pool Size

You have set both `size 1` and `min_size 1` for these pools.

Setting `size 1` means **zero data redundancy**. If the single OSD holding an object in that zone goes down or suffers data corruption, that data is permanently lost. This is acceptable for a scratchpad lab environment, but **never** do this in a production cluster.
