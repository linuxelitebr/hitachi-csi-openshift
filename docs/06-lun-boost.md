# LUN Boost

LUN boost increases the maximum number of LUNs the operating system can discover per SCSI target. The default kernel limit is usually 256, which can be insufficient in environments with many volumes or when using Hitachi storage with large LDEV pools.

This is a Red Hat recommended configuration for bare-metal environments with SAN storage.

## What it does

The core change is the kernel parameter `scsi_mod.max_luns`, which controls the maximum LUN count at the SCSI subsystem level. This parameter is universal and applies to all FC drivers regardless of vendor.

Additionally, some FC HBA drivers have their own per-driver max LUN parameter. Depending on the hardware in your nodes, you may want to set both the kernel-level and driver-level limits.

## Identifying your FC driver

Before configuring LUN boost, identify which FC driver your nodes use:

```bash
oc debug node/<node> -- chroot /host bash -c 'lsmod | grep -E "lpfc|qla2xxx|qedf|bnx2fc"'
```

Common FC drivers on OpenShift bare-metal nodes:

| Driver | Vendor | Hardware | Max LUN parameter | Default limit |
|--------|--------|----------|-------------------|---------------|
| `lpfc` | Emulex (Broadcom) | LPe HBAs | `lpfc_max_luns` | 65535 |
| `qla2xxx` | QLogic (Marvell) | QLE HBAs (native FC) | `ql2xmaxlun` | 65535 |
| `qedf` | QLogic (Marvell) | QLE HBAs (FCoE) | `max_lun` | -1 (unlimited) |
| `bnx2fc` | Broadcom | BCM57xx (FCoE) | N/A | N/A |

To check the current value of the driver-specific parameter:

```bash
# For lpfc (Emulex)
oc debug node/<node> -- chroot /host cat /sys/module/lpfc/parameters/lpfc_max_luns

# For qla2xxx (QLogic native FC)
oc debug node/<node> -- chroot /host cat /sys/module/qla2xxx/parameters/ql2xmaxlun

# For qedf (QLogic FCoE)
oc debug node/<node> -- chroot /host cat /sys/module/qedf/parameters/max_lun

# Kernel-level (always available)
oc debug node/<node> -- chroot /host cat /sys/module/scsi_mod/parameters/max_luns
```

Note: `scsi_mod` is built into the RHCOS kernel, so it does not appear in `lsmod`, but the parameter still works via kernel arguments.

## How to find LUN-related parameters for any module

If your hardware uses a driver not listed above, you can discover its parameters yourself:

```bash
# Step 1: Identify which SCSI/FC modules are loaded
oc debug node/<node> -- chroot /host bash -c 'lsmod | grep -iE "scsi|fc|iscsi|lpfc|qla|qed|bnx2|mpt|hpsa|mega"'

# Step 2: Check if a module has a LUN-related parameter
oc debug node/<node> -- chroot /host bash -c 'modinfo <module_name> | grep -i lun'

# Step 3: List all parameters of a module
oc debug node/<node> -- chroot /host bash -c 'modinfo <module_name> | grep ^parm:'

# Step 4: Check the current value of a specific parameter
oc debug node/<node> -- chroot /host cat /sys/module/<module_name>/parameters/<param_name>

# Step 5: List all parameters and their current values at once
oc debug node/<node> -- chroot /host bash -c '
  for p in /sys/module/<module_name>/parameters/*; do
    echo "$(basename $p) = $(cat $p 2>/dev/null || echo N/A)"
  done
'
```

For example, if you have an HPE server with the `hpsa` driver and want to check if it has a LUN limit:

```bash
oc debug node/<node> -- chroot /host bash -c 'modinfo hpsa | grep -i lun'
```

If no LUN parameter appears, the driver does not impose its own limit and `scsi_mod.max_luns` is the only one that matters.

The general rule: `modinfo <module> | grep -i lun` tells you if the driver has its own limit. If it does, `cat /sys/module/<module>/parameters/<param>` shows the current value.

## Do you actually need driver-specific LUN boost?

In many cases, `scsi_mod.max_luns` alone is enough:

- **qedf**: default is `-1` (0xffffffff, effectively unlimited). No driver-level boost needed.
- **qla2xxx**: default is `65535`. Unless you have more than 65535 LUNs per target (extremely unlikely), no driver-level boost needed.
- **lpfc**: default is `65535`. Same as qla2xxx.

The kernel-level `scsi_mod.max_luns=2048` is the one that matters in practice, because its default (256) is the actual bottleneck. The driver-level defaults are already high enough.

That said, if you want to be explicit and defensive, setting both kernel and driver parameters does no harm.

## When you need it

- Your storage pool has more than 256 LDEVs allocated
- You plan to use many PVCs across the cluster
- You see SCSI discovery errors or missing LUNs on nodes
- Your storage admin allocated a large LDEV range proactively

Even if you are not hitting the limit today, it is a good practice to apply this early. It is much easier to apply before workloads are running than to coordinate a rolling reboot later.

## MachineConfig for scsi_mod only (recommended for most environments)

Since the driver-level defaults are already high, most environments only need the kernel-level parameter:

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
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/modprobe.d/scsi_mod.conf
          mode: 0644
          overwrite: true
          contents:
            # options scsi_mod max_luns=2048
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBzY3NpX21vZCBtYXhfbHVucz0yMDQ4"
```

Create a second one with `name: 99-master-lun-boost` and `role: master` using the same spec.

## MachineConfig with driver-specific parameters (defensive approach)

If you want to also set the driver-level parameter, add the appropriate kernel argument and modprobe file for your hardware.

### Emulex (lpfc)

```yaml
spec:
  kernelArguments:
    - "scsi_mod.max_luns=2048"
    - "lpfc.lpfc_max_luns=2048"
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/modprobe.d/scsi_mod.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBzY3NpX21vZCBtYXhfbHVucz0yMDQ4"
        - path: /etc/modprobe.d/lpfc.conf
          mode: 0644
          overwrite: true
          contents:
            # options lpfc lpfc_max_luns=2048
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBscGZjIGxwZmNfbWF4X2x1bnM9MjA0OA=="
```

### QLogic native FC (qla2xxx)

```yaml
spec:
  kernelArguments:
    - "scsi_mod.max_luns=2048"
    - "qla2xxx.ql2xmaxlun=2048"
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/modprobe.d/scsi_mod.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBzY3NpX21vZCBtYXhfbHVucz0yMDQ4"
        - path: /etc/modprobe.d/qla2xxx.conf
          mode: 0644
          overwrite: true
          contents:
            # options qla2xxx ql2xmaxlun=2048
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBxbGEyeHh4IHFsMnhtYXhsdW49MjA0OA=="
```

### QLogic FCoE (qedf)

The `qedf` driver defaults to unlimited (`max_lun=-1`), so there is no practical reason to set a driver-level limit. Just use `scsi_mod.max_luns`.

## Mixed hardware environments

If your cluster has nodes with different HBA vendors (some Emulex, some QLogic), use the modprobe.d approach. The modprobe files are only applied when the corresponding module is loaded, so having both `/etc/modprobe.d/lpfc.conf` and `/etc/modprobe.d/qla2xxx.conf` on the same node is harmless. The file for the module that is not loaded is simply ignored.

```yaml
spec:
  kernelArguments:
    - "scsi_mod.max_luns=2048"
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/modprobe.d/scsi_mod.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBzY3NpX21vZCBtYXhfbHVucz0yMDQ4"
        - path: /etc/modprobe.d/lpfc.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBscGZjIGxwZmNfbWF4X2x1bnM9MjA0OA=="
        - path: /etc/modprobe.d/qla2xxx.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,b3B0aW9ucyBxbGEyeHh4IHFsMnhtYXhsdW49MjA0OA=="
```

Do not add kernel arguments for drivers that are not loaded (`lpfc.lpfc_max_luns` on a QLogic node or vice versa), because the kernel will print a warning at boot for unknown module parameters. The modprobe.d files do not have this issue.

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

# Verify runtime parameter (kernel level)
oc debug node/<node> -- chroot /host cat /sys/module/scsi_mod/parameters/max_luns
# Should output: 2048

# Verify modprobe files exist
oc debug node/<node> -- chroot /host ls -la /etc/modprobe.d/ | grep -E 'scsi_mod|lpfc|qla2xxx'
```

## Base64 reference

For convenience, here are the base64 encodings for common modprobe options:

| Content | Base64 |
|---------|--------|
| `options scsi_mod max_luns=2048` | `b3B0aW9ucyBzY3NpX21vZCBtYXhfbHVucz0yMDQ4` |
| `options lpfc lpfc_max_luns=2048` | `b3B0aW9ucyBscGZjIGxwZmNfbWF4X2x1bnM9MjA0OA==` |
| `options qla2xxx ql2xmaxlun=2048` | `b3B0aW9ucyBxbGEyeHh4IHFsMnhtYXhsdW49MjA0OA==` |

To generate your own with a different value:

```bash
echo -n "options scsi_mod max_luns=4096" | base64
echo -n "options lpfc lpfc_max_luns=4096" | base64
echo -n "options qla2xxx ql2xmaxlun=4096" | base64
```
