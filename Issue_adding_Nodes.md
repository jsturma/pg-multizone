If plain SSH works but:

```bash
cephadm shell -- ceph orch host add ceph-node3 192.168.1.13
```

fails with:

```text
Auth failed for user root
Connection Failure: Permission denied
Aborting connection
```

then the problem is usually that **Ceph Orchestrator is trying to SSH as root using its own cluster SSH key**, not the key you used manually.

Check the Ceph-managed SSH configuration:

### 1. View the orchestrator SSH key

On your bootstrap node:

```bash
cephadm shell -- ceph cephadm get-pub-key
```

Copy the output.

### 2. Verify the key is in root's authorized\_keys on ceph-node3

On `ceph-node3`:

```bash
cat /root/.ssh/authorized_keys
```

The key from step 1 must be present.

If not:

```bash
cephadm shell -- ceph cephadm get-pub-key > ceph.pub

ssh root@ceph-node3 "mkdir -p /root/.ssh && chmod 700 /root/.ssh"

cat ceph.pub | ssh root@ceph-node3 "cat >> /root/.ssh/authorized_keys"

ssh root@ceph-node3 "chmod 600 /root/.ssh/authorized_keys"
```

### 3. Test using the Ceph private key

Export the private key used by cephadm:

```bash
cephadm shell -- ceph config-key get mgr/cephadm/ssh_identity_key > ceph.key
chmod 600 ceph.key
```

Then test:

```bash
ssh -i ceph.key root@192.168.1.13
```

If this fails, you've found the issue.

### 4. Check root login is allowed

On `ceph-node3`:

```bash
grep PermitRootLogin /etc/ssh/sshd_config
```

Should be:

```text
PermitRootLogin yes
```

or

```text
PermitRootLogin prohibit-password
```

Restart SSH if you make changes:

```bash
systemctl restart sshd
```

### 5. Verify Ceph's SSH configuration

```bash
cephadm shell -- ceph cephadm get-ssh-config
```

and

```bash
ceph orch host ls
```

### 6. Check cephadm logs

```bash
ceph -W cephadm
```

or

```bash
cephadm shell -- ceph log last cephadm
```

A very common scenario is:

* You can SSH manually using your personal key (`~/.ssh/id_rsa`).
* Cephadm uses a different cluster key stored in `mgr/cephadm/ssh_identity_key`.
* That key is not present in `/root/.ssh/authorized_keys` on the new node.

Can you paste the output of:

```bash
cephadm shell -- ceph cephadm get-pub-key
```

and

```bash
ssh -i ceph.key root@192.168.1.13
```

(or the exact error from the second command)? That will pinpoint the root cause.
