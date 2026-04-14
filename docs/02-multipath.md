# Multipath Configuration

Multipath is a hard prerequisite for the Hitachi CSI driver. Without it, the CSI node plugin cannot map LDEVs to block devices on the nodes, and volume mounts will fail.

## Why multipath matters

In a Fibre Channel setup, each node typically has 2 HBA ports connected to 2 storage controllers, creating 4 physical paths to each LUN. Without multipath, the OS sees 4 separate block devices for what is really one volume. multipathd aggregates these into a single device with failover and load balancing.

## Hitachi recommended path count

Hitachi recommends a maximum of **4 paths** per LUN. This is typically achieved with:

- 2 HBA ports on the node
- 2 storage controller ports (one per controller/CL pair)
- Result: 2 HBAs x 2 controllers = 4 paths

Going beyond 4 paths (e.g., using 4 HBA ports) is not recommended by Hitachi and can cause performance degradation due to path management overhead. If your nodes have more than 2 HBA ports, zone only 2 of them to the storage.

## multipath.conf for Hitachi

Here is a working multipath.conf tuned for Hitachi OPEN-V and OPEN-* series arrays:

```ini
defaults {
    no_path_retry 10
    find_multipaths yes
    user_friendly_names yes
}
devices {
    device {
        vendor                  "HITACHI"
        product                 "OPEN-.*"
        path_grouping_policy    multibus
        path_checker            tur
        hardware_handler        "0"
        path_selector           "round-robin 0"
        failback                immediate
        rr_weight               priorities
    }
}
```

What each setting does:

| Parameter | Value | Why |
|-----------|-------|-----|
| `vendor` | `"HITACHI"` | Matches Hitachi arrays in SCSI inquiry |
| `product` | `"OPEN-.*"` | Matches OPEN-V, OPEN-E, and similar product lines |
| `path_grouping_policy` | `multibus` | All paths in one group for load balancing |
| `path_checker` | `tur` | Test Unit Ready, standard for Hitachi |
| `hardware_handler` | `"0"` | No special hardware handler needed |
| `path_selector` | `"round-robin 0"` | Distribute I/O across all active paths |
| `failback` | `immediate` | Return to preferred path as soon as it recovers |
| `rr_weight` | `priorities` | Use path priorities for round-robin weighting |
| `no_path_retry` | `10` | Retry 10 times before failing I/O when all paths are down |
| `find_multipaths` | `yes` | Only create multipath devices when multiple paths exist |
| `user_friendly_names` | `yes` | Use friendly device names (mpath*) |

## Applying on OpenShift

Multipath is deployed via MachineConfig, which enables the `multipathd.service` and writes `/etc/multipath.conf` on all nodes.

### Standalone and hosting clusters

Create MachineConfigs for both worker and master roles:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-multipath
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: multipathd.service
          enabled: true
    storage:
      files:
        - path: /etc/multipath.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,ZGVmYXVsdHMgewogICAgbm9fcGF0aF9yZXRyeSAxMAogICAgZmluZF9tdWx0aXBhdGhzIHllcwogICAgdXNlcl9mcmllbmRseV9uYW1lcyB5ZXMKfQpkZXZpY2VzIHsKICAgIGRldmljZSB7CiAgICAgICAgdmVuZG9yICAgICAgICAgICAgICAgICAgIkhJVEFDSEkiCiAgICAgICAgcHJvZHVjdCAgICAgICAgICAgICAgICAgIk9QRU4tLioiCiAgICAgICAgcGF0aF9ncm91cGluZ19wb2xpY3kgICAgbXVsdGlidXMKICAgICAgICBwYXRoX2NoZWNrZXIgICAgICAgICAgICB0dXIKICAgICAgICBoYXJkd2FyZV9oYW5kbGVyICAgICAgICAiMCIKICAgICAgICBwYXRoX3NlbGVjdG9yICAgICAgICAgICAicm91bmQtcm9iaW4gMCIKICAgICAgICBmYWlsYmFjayAgICAgICAgICAgICAgICBpbW1lZGlhdGUKICAgICAgICBycl93ZWlnaHQgICAgICAgICAgICAgICAgcHJpb3JpdGllcwogICAgfQp9Cg=="
```

Create a second one with `name: 99-master-multipath` and `role: master` using the same spec.

The base64 string above is the multipath.conf shown earlier. To encode your own:

```bash
cat multipath.conf | base64 -w0
```

### HyperShift hosted clusters

Hosted clusters do not support MachineConfig directly. Instead, wrap the MachineConfig inside a ConfigMap on the hosting cluster and reference it in the NodePool:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-cluster-multipath
  namespace: my-hosted-cluster-namespace
data:
  config: |
    apiVersion: machineconfiguration.openshift.io/v1
    kind: MachineConfig
    metadata:
      name: 99-worker-multipath
      labels:
        machineconfiguration.openshift.io/role: worker
    spec:
      config:
        ignition:
          version: 3.2.0
        systemd:
          units:
            - name: multipathd.service
              enabled: true
        storage:
          files:
            - path: /etc/multipath.conf
              mode: 0644
              overwrite: true
              contents:
                source: "data:text/plain;charset=utf-8;base64,<your-base64-content>"
```

Then patch the NodePool to reference the ConfigMap:

```bash
# Get existing config references (preserve them!)
oc get nodepool my-cluster -n my-namespace -o jsonpath='{.spec.config}' | jq .

# Patch to add multipath (keep existing entries)
oc patch nodepool my-cluster -n my-namespace --type=merge \
  -p '{"spec":{"config":[{"name":"my-cluster-multipath"}, ...existing entries...]}}'
```

Only create a worker MachineConfig for hosted clusters, since hosted clusters do not have master nodes.

## Verification

After the MachineConfigPool rollout completes (nodes will reboot):

```bash
# Check multipathd is running
oc debug node/<node> -- chroot /host systemctl status multipathd

# Check multipath devices
oc debug node/<node> -- chroot /host multipath -ll

# Check multipath.conf was applied
oc debug node/<node> -- chroot /host cat /etc/multipath.conf
```

With Hitachi storage connected, `multipath -ll` should show devices with the configured number of paths (typically 4). If you see more or fewer paths, check your FC zoning configuration.
