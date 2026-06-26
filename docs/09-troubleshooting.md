# Troubleshooting

## Operator not installing

```bash
# Check Subscription status
oc get sub -n storage-hitachi
oc get sub hspc-operator -n storage-hitachi -o yaml

# Check InstallPlan
oc get installplan -n storage-hitachi

# Check CSV status
oc get csv -n storage-hitachi
```

If the Subscription shows `ResolutionFailed`, the requested CSV version does not exist in the catalog for your OCP version. Check available versions:

```bash
oc get packagemanifest hspc-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}: {.currentCSV}{"\n"}{end}'
```

If a stale Subscription or InstallPlan is stuck from a previous attempt, clean up and recreate:

```bash
oc delete subscription hspc-operator -n storage-hitachi
oc delete csv -n storage-hitachi -l operators.coreos.com/hspc-operator.storage-hitachi
# Reapply the Subscription YAML with the correct version
```

## CSI pods not ready

CSI pods may fail if there is no actual storage connectivity. This is expected in lab environments. Check logs:

```bash
# Controller logs
oc logs -n storage-hitachi deployment/hspc-csi-controller -c hspc-csi-driver

# Operator logs
oc logs -n storage-hitachi deployment/hspc-operator-controller-manager
```

## Volume mount failures (HSPC0x0000c008)

The error "failed to find the target device" indicates infrastructure-level issues. Check in this order:

1. **multipathd running?**
   ```bash
   oc debug node/<node> -- chroot /host systemctl status multipathd
   ```
   If not running, multipath MachineConfig was not applied or the node did not reboot after applying it.

2. **FC zoning correct?**
   ```bash
   oc debug node/<node> -- chroot /host bash -c '
     for host in /sys/class/fc_host/host*; do
       echo "$(basename $host): state=$(cat $host/port_state) speed=$(cat $host/speed)"
     done
   '
   ```
   All HBAs should show `Online`. If any show `Linkdown`, the FC fabric is not zoned correctly for that port.

3. **Service account permissions**
   The integration user in the Secret needs full permissions on the storage resource group. Restricted access has caused provisioning failures in every case we have seen. If the storage admin recently changed permissions, that is likely the cause.

4. **Virtual ID (VSM environments)**
   When using Virtual Storage Machines, the Virtual ID attribute must be defined on the storage side. Missing Virtual ID causes the CSI driver to fail to locate the storage pool.

### When the infrastructure is healthy and it still happens

Treat this as a way to find the cause, not a verdict. Several different problems produce the same
`Aborted ... 0x0000c008` message, so the goal is to tell them apart in your environment before
you act.

Start with the pattern. `code = Aborted` is a retryable code: the kubelet retries MountDevice on
its own (the event shows "N times in the last M minutes"), and the pod usually reaches Running
once a later retry lands. The fact that it heals on its own means the LUN does become usable, so
a permanently broken SAN is unlikely. Now narrow it down.

**Step 1, multipathd health.** Run `multipath -ll` on the affected node while the pod is failing.

- It **hangs or returns slowly**: multipathd is backlogged, a uevent or rescan storm. Check its
  CPU and `journalctl -u multipathd`, and whether the failures cluster with bursts (a node
  reboot, or many PVCs attaching at once). The problem is in the multipath layer.
- It **returns instantly with all paths online**: the device is present and multipathd is
  responsive. The problem is above multipath. Go to step 2.

**Step 2, is the device really in the kernel?** Still at the moment of failure, on that node:

```bash
lsscsi | grep -i hitachi
ls -l /dev/disk/by-id/ | grep -i <ldev-serial>
multipath -ll <wwid>
```

If the multipath device, its paths, and the `by-id` symlink are all there, the block device
exists and is healthy. The driver could not consume a device that is present, which is a
driver-side timing problem, not a SAN one.

**Step 3, read the driver's own log.** This is the artifact that tells the driver-side causes
apart. The `hspc-csi-node` pod on the failing node records which device it was waiting for and
why it gave up:

```bash
oc logs -n storage-hitachi <hspc-csi-node-pod> -c hspc-csi-driver --timestamps \
  | grep -iE 'c008|detect|device|stage|aborted'
```

Use this table to place your case:

| What you observe at failure | Points to |
|---|---|
| `multipath -ll` slow, multipathd busy, failures in bursts | a multipathd storm (multipath layer) |
| A path `faulty`/`failed`, or it only hits one node or HBA | a bad FC path or zoning (SAN layer) |
| Paths online, `multipath -ll` instant, device in `/dev/mapper` and `by-id` | driver-side detection (see below) |

If you land in the driver-side row, the cause is one of a few timing problems, and the driver log
is what tells them apart: a udev/`by-id` symlink that lags the multipath map, a wait that ends
before all expected paths are assembled, stale device state from a previous mapping, or a
detection window shorter than this array's assembly latency. `multipath.conf` tuning does not fix
any of these, with one thing worth ruling out first: `find_multipaths "smart"` adds a deliberate
hold before a new device becomes a map, so confirm you are on `yes` (see the multipath chapter).

Hitachi's own note for `0x0000c008` treats it as a one-time event right after the initial FC
setup and says to delete the pod and reboot the host. That does not match an error that recurs
and clears on its own without a reboot. If that is your case, take it to Hitachi with the
`hspc-csi-node` log from a real failure, which shows exactly what the driver was waiting for. That
log is what turns "it looks like a detection timeout" into a specific, fixable finding, instead of
a guess.

## Permission denied (rados error -13)

This error is specific to Ceph and indicates wrong credentials. If you see this on a Hitachi setup, you are likely hitting a different storage backend by mistake. Check which StorageClass the PVC is using:

```bash
oc get pvc <pvc-name> -o jsonpath='{.spec.storageClassName}'
```

## PVC stuck in Pending

Common causes and how to diagnose:

```bash
# Check events on the PVC
oc describe pvc <pvc-name>

# Check provisioner logs
oc logs -n storage-hitachi deployment/hspc-csi-controller -c hspc-csi-driver --tail=50
```

| Event message | Cause | Fix |
|--------------|-------|-----|
| `waiting for a volume to be created` | Normal, provisioning in progress | Wait a minute |
| `failed to provision volume` | Storage API error | Check Secret credentials and storage URL |
| No events at all | CSI provisioner not running | Check CSI controller pod status |

## LUNs not visible after adding new storage

If the storage admin added new LDEVs but they are not showing up as multipath devices:

```bash
# Force FC LIP rescan
oc debug node/<node> -- chroot /host bash -c '
  for host in /sys/class/fc_host/host*; do
    echo "Rescanning $(basename $host)..."
    echo 1 > $host/issue_lip
    sleep 10
  done
'

# Wait and check
sleep 30
oc debug node/<node> -- chroot /host multipath -ll
```

If LUNs still do not appear, verify the FC zoning includes the new storage ports.

## Events and logs

```bash
# CSI events in the storage namespace
oc get events -n storage-hitachi --sort-by='.lastTimestamp'

# CSI controller logs (provisioning)
oc logs -n storage-hitachi deployment/hspc-csi-controller -c hspc-csi-driver --tail=100

# CSI node logs (mount operations)
oc logs -n storage-hitachi daemonset/hspc-csi-node -c hspc-csi-driver --tail=100

# Operator logs
oc logs -n storage-hitachi deployment/hspc-operator-controller-manager --tail=100
```

## Useful commands

```bash
# Full CSI driver status
oc get all -n storage-hitachi

# Check CSIDriver registration
oc get csidriver hspc.csi.hitachi.com

# List all PVs provisioned by Hitachi
oc get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase,SIZE:.spec.capacity.storage | grep hitachi

# Check storage events cluster-wide
oc get events -A --field-selector reason=ProvisioningFailed --sort-by='.lastTimestamp'
```
