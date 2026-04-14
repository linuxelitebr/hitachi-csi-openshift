# Storage Preparation

Before touching OpenShift, the storage side needs to be ready. This is typically done by the storage admin team, but you need to know what to ask for and why.

## Dedicated storage pool per cluster

The common and recommended practice is to create a dedicated storage pool for each OpenShift cluster. This gives you:

- Clear resource isolation between clusters
- Independent capacity management
- Simpler troubleshooting when things go wrong
- Per-cluster performance monitoring

If you are running multiple OpenShift clusters (hosting + hosted, or multiple standalone), each one should get its own pool. Sharing a single pool across clusters works technically, but makes capacity planning and incident isolation much harder.

## LDEV allocation

Storage admins typically pre-allocate a range of LDEVs (Logical Devices) in the pool. The number of LDEVs directly limits how many PVCs you can create, because each PVC maps to one LDEV.

Plan for more than you think you need. Consider:

- Each PVC consumes one LDEV
- VolumeSnapshots also consume LDEVs
- Backup operations (if using storage-level snapshots) consume additional LDEVs
- OpenShift internal components create PVCs too (monitoring, logging, registry, etcd)

A typical starting point for a production cluster is 200-500 LDEVs per pool. For lab environments, 50-100 is usually enough. Running out of LDEVs causes PVC provisioning failures that are not always obvious from the OpenShift side.

## Resource groups

Resource groups in Hitachi storage control which LDEVs, pools, and ports a service account can access. The recommended setup is:

- One resource group per OpenShift cluster
- The resource group contains: the dedicated pool, the allocated LDEV range, and the FC ports used by that cluster's nodes

This creates a clean security boundary. The CSI driver's service account can only see and manipulate storage resources assigned to its cluster.

## Service account (integration user)

The Hitachi CSI driver authenticates against the storage management API using a dedicated service account. This account is referenced in the Kubernetes Secret that the CSI driver uses.

Important lessons learned:

**Use full permissions on the resource group.** We have seen multiple cases where attempts to restrict the integration user's permissions caused volume provisioning failures with unhelpful error messages (like `HSPC0x0000c008`). Until Hitachi publishes a documented minimum permission set for the CSI driver, keep full permissions on the resource group.

**Do not use Virtual Storage Machine (VSM) restricted pools.** Pools created via the VSM method with restricted permissions have caused provisioning failures. If you need VSM, make sure the Virtual ID attribute is correctly defined on the storage side.

The credentials for the service account should be stored in a secrets manager (Ansible Vault, HashiCorp Vault, etc.) and never committed to source control.

## FC zoning

The FC fabric must be zoned so that each OpenShift node's HBA ports can see the storage array's target ports. The port IDs you configure in the StorageClass (e.g., `CL1-J,CL1-K,CL2-J,CL2-K`) must be reachable from every node that will mount volumes.

A typical setup uses 4 paths per node (2 HBA ports x 2 storage controllers), which Hitachi recommends as the maximum for balanced performance and redundancy. See the [Multipath Configuration](02-multipath.md) section for details.

Verify zoning before deploying the CSI driver:

```bash
# On a node, check FC HBA status
oc debug node/<node> -- chroot /host bash -c '
  for host in /sys/class/fc_host/host*; do
    echo "=== $(basename $host) ==="
    echo "Port Name: $(cat $host/port_name)"
    echo "Port State: $(cat $host/port_state)"
    echo "Speed: $(cat $host/speed)"
  done
'
```

All HBAs should show `port_state: Online` and a valid speed. If any show `Linkdown`, the zoning is incomplete or the cable is not connected.

## What to ask your storage admin

When requesting storage for a new OpenShift cluster, provide:

1. Cluster name and purpose (production, lab, etc.)
2. Estimated PVC count (start with 200 for production, 50 for lab)
3. Total capacity needed (sum of all expected PVC sizes + 20% headroom)
4. FC port pairs to zone (get the HBA WWNs from `oc debug node` as shown above)
5. Connection type: FC (recommended) or iSCSI
6. Whether snapshots are needed (adds LDEV overhead)

Ask them to provide:
- Storage array serial number
- Pool ID
- Resource group ID
- FC port IDs (e.g., CL1-J, CL1-K, CL2-J, CL2-K)
- Management API URL
- Service account credentials (username + password)

You will need all of these values for the CSI configuration.
