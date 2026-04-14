# HyperShift Hosted Clusters

HyperShift hosted clusters have a different architecture: the control plane runs on the hosting cluster, and worker nodes are the only nodes in the hosted cluster. This changes how MachineConfigs and some CSI operations work.

## CSI installation on hosted clusters

The CSI operator and StorageClass are installed directly on the hosted cluster, the same way as a standalone cluster. The only difference is that you target the hosted cluster's kubeconfig instead of the hosting cluster's.

The Namespace, OperatorGroup, Subscription, HSPC CR, Secrets, and StorageClasses are all created on the hosted cluster.

## MachineConfig differences

Hosted clusters do not have direct MachineConfig support. The MachineConfig Operator runs on the hosting cluster's control plane, not on the hosted cluster. To apply MachineConfigs to hosted cluster worker nodes, you use a ConfigMap + NodePool patch pattern:

1. Create a ConfigMap in the hosted cluster's namespace on the **hosting** cluster
2. The ConfigMap's `data.config` field contains the full MachineConfig YAML
3. Patch the NodePool to add the ConfigMap reference to `spec.config`
4. The HyperShift operator delivers the MachineConfig to the worker nodes

This pattern is used for multipath, LUN boost, and any other MachineConfig-based configuration.

## ConfigMap + NodePool pattern

### Create the ConfigMap

The ConfigMap goes in the hosted cluster namespace on the hosting cluster (not on the hosted cluster itself):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-cluster-multipath
  namespace: hosting-ns-my-cluster
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
                source: "data:text/plain;charset=utf-8;base64,<your-multipath-conf-base64>"
```

Only use the `worker` role. Hosted clusters do not have master nodes.

### Patch the NodePool

This is the critical part. The NodePool's `spec.config` is an array of ConfigMap references. You must **preserve existing entries** when adding a new one:

```bash
# First, check what is already there
oc get nodepool my-cluster -n hosting-ns-my-cluster \
  -o jsonpath='{.spec.config}' | jq .

# Example output:
# [{"name":"my-cluster-max-pods"},{"name":"my-cluster-multipath"}]

# Add the new entry (preserve existing ones!)
oc get nodepool my-cluster -n hosting-ns-my-cluster -o json | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
configs = data.get('spec', {}).get('config', [])
new_name = 'my-cluster-lun-boost'
if not any(c.get('name') == new_name for c in configs):
    configs.append({'name': new_name})
    print(json.dumps(configs))
else:
    print('Already referenced', file=sys.stderr)
    sys.exit(0)
" > /tmp/new-config.json

oc patch nodepool my-cluster -n hosting-ns-my-cluster \
  --type=merge \
  -p "{\"spec\":{\"config\":$(cat /tmp/new-config.json)}}"
```

A `--type=merge` patch with only the new entry would overwrite the entire array, removing all existing ConfigMap references. Always read, append, then patch.

### What happens after patching

After patching the NodePool, the hosted cluster worker nodes will do a rolling restart. Each node gets drained, rebooted with the new configuration, and uncordoned. This takes several minutes per node.

Monitor the rollout:

```bash
# On the hosting cluster
oc get nodepool my-cluster -n hosting-ns-my-cluster -w

# On the hosted cluster
oc get nodes -w
```

## Pre-deploy optimization

If you know you need multipath, LUN boost, or other MachineConfigs before deploying the hosted cluster, create the ConfigMaps first and include them in the NodePool manifest before running `oc apply`. This way, nodes boot with the final desired configuration and you avoid post-deploy rolling restarts entirely.

The flow:
1. Create ConfigMaps (multipath, lun-boost, etc.) in the HC namespace
2. Add ConfigMap references to the NodePool YAML before applying
3. Run `oc apply` for the HostedCluster and NodePool
4. Nodes boot with all configurations already active

This is a significant optimization for production deployments where every rolling restart means downtime for workloads.

## Summary of what runs where

| Operation | Where it runs | Target |
|-----------|--------------|--------|
| CSI operator install | Hosted cluster | Hosted cluster API |
| Secret, StorageClass | Hosted cluster | Hosted cluster API |
| Multipath ConfigMap | Hosting cluster | HC namespace on hosting |
| LUN boost ConfigMap | Hosting cluster | HC namespace on hosting |
| NodePool patch | Hosting cluster | NodePool resource on hosting |
| PVC creation | Hosted cluster | Hosted cluster API |
| FC diagnostics | Hosted cluster nodes | Node debug sessions |
