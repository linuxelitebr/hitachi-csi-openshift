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
