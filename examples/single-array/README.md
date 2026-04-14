# Single Array Example

Complete example for deploying Hitachi HSPC CSI with one storage array.

## Apply order

```bash
# 1. Namespace and OperatorGroup
oc apply -f namespace.yaml
oc apply -f operatorgroup.yaml

# 2. Subscription (Manual approval)
oc apply -f subscription.yaml

# 3. Wait for InstallPlan and approve
oc get installplan -n storage-hitachi -w
oc patch installplan <plan-name> -n storage-hitachi --type=merge -p '{"spec":{"approved":true}}'

# 4. Wait for CSV
oc get csv -n storage-hitachi -w

# 5. Create HSPC instance
oc apply -f hspc.yaml

# 6. Wait for CSI pods
oc get pods -n storage-hitachi -w

# 7. Create Secret (edit with real credentials first!)
oc apply -f secret.yaml

# 8. Create StorageClass
oc apply -f storageclass.yaml

# 9. Create VolumeSnapshotClass
oc apply -f snapshotclass.yaml

# 10. Verify
oc get sc | grep hitachi
oc get volumesnapshotclass | grep hitachi
```

## Before you start

Make sure you have:
- [ ] Multipath configured on all nodes
- [ ] FC zoning complete
- [ ] Storage pool and resource group created
- [ ] Service account credentials ready
