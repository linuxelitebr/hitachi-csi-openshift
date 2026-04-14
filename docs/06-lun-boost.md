# LUN Boost

LUN boost increases the maximum number of LUNs the operating system can discover per SCSI target. The default kernel limit is usually 256, which can be insufficient in environments with many volumes or when using Hitachi storage with large LDEV pools.

This is a Red Hat recommended configuration for bare-metal environments with SAN storage.

## What it does

LUN boost applies two changes via MachineConfig:

1. **Kernel arguments** (applied at boot):
   - `scsi_mod.max_luns=2048`
   - `lpfc.lpfc_max_luns=2048`

2. **Modprobe configuration files** (applied when modules are loaded):
   - `/etc/modprobe.d/scsi_mod.conf` containing `options scsi_mod max_luns=2048`
   - `/etc/modprobe.d/lpfc.conf` containing `options lpfc lpfc_max_luns=2048`

The `scsi_mod` parameter affects all SCSI devices. The `lpfc` parameter is specific to Emulex (Broadcom) Fibre Channel HBAs. If your nodes use QLogic HBAs, replace `lpfc` with `qla2xxx` and the corresponding parameter.

Nodes will reboot during the MachineConfigPool rollout to apply the kernel arguments.

## When you need it

- Your storage pool has more than 256 LDEVs allocated
- You plan to use many PVCs across the cluster
- You see SCSI discovery errors or missing LUNs on nodes
- Your storage admin allocated a large LDEV range proactively

Even if you are not hitting the limit today, it is a good practice to apply this early. It is much easier to apply before workloads are running than to coordinate a rolling reboot later.

## Standalone and hosting clusters

Create MachineConfigs for worker and master roles:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-lun-boost
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - "scsi_mod.max_luns=2048"
    - "lpfc.lpfc_max_luns=2048"
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/modprobe.d/lpfc.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBscGZjIGxwZmNfbWF4X2x1bnM9MjA0OA=="
        - path: /etc/modprobe.d/scsi_mod.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBzY3NpX21vZCBtYXhfbHVucz0yMDQ4"
```

Create a second one with `name: 99-master-lun-boost` and `role: master` using the same spec.

```bash
oc apply -f 99-worker-lun-boost.yaml
oc apply -f 99-master-lun-boost.yaml
```

The base64 values decode to:
- `b3B0aW9ucyBscGZjIGxwZmNfbWF4X2x1bnM9MjA0OA==` = `options lpfc lpfc_max_luns=2048`
- `b3B0aW9ucyBzY3NpX21vZCBtYXhfbHVucz0yMDQ4` = `options scsi_mod max_luns=2048`

## HyperShift hosted clusters

Hosted clusters cannot use MachineConfig directly. Use the ConfigMap + NodePool patch pattern instead. See [HyperShift Hosted Clusters](08-hypershift.md) for the full pattern.

The ConfigMap wraps the same MachineConfig YAML shown above. Only the worker variant is needed because hosted clusters do not have master nodes.

## Verification

After the MCP rollout completes and nodes reboot:

```bash
# Check MachineConfigs exist
oc get mc | grep lun-boost

# Check MCP status (UPDATED should be True)
oc get mcp

# Verify kernel arguments on a node
oc debug node/<node> -- chroot /host cat /proc/cmdline | grep max_luns

# Verify runtime parameter
oc debug node/<node> -- chroot /host cat /sys/module/scsi_mod/parameters/max_luns
# Should output: 2048

# For lpfc (only if Emulex HBA is present)
oc debug node/<node> -- chroot /host cat /sys/module/lpfc/parameters/lpfc_max_luns
# Should output: 2048 (or error if lpfc module is not loaded, which is fine on non-FC nodes)
```

Note: `scsi_mod` is built into the kernel on RHCOS, so it does not appear in `lsmod`. The kernel argument is what changes its behavior. The `lpfc` module is only loaded when an Emulex HBA is physically present.

## Custom LUN limits

If 2048 is not enough (unusual but possible in very large environments), adjust the value in the MachineConfig and re-encode the modprobe files:

```bash
echo -n "options scsi_mod max_luns=4096" | base64
echo -n "options lpfc lpfc_max_luns=4096" | base64
```

Replace the base64 strings and kernel argument values in the MachineConfig YAML.
