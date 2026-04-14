# StorageClass and Secrets

Each storage array needs a Secret (credentials) and a StorageClass (provisioning parameters). If you have multiple arrays serving the same cluster, create one pair per array.

## Secret

The Secret holds the storage management API credentials and the resource group ID. The CSI driver uses these to provision and manage volumes.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hitachi-vsp5044-secret
  namespace: storage-hitachi
type: Opaque
stringData:
  url: "https://svp-vsp5044.example.com"
  user: "openshift-csi"
  password: "YourSecretPassword"
  resourceGroupID: "3"
```

Using `stringData` instead of `data` means you write the values in plain text and Kubernetes handles the base64 encoding. Never commit this file with real credentials to source control.

## StorageClass

The StorageClass defines how volumes are provisioned. It references the Secret in six different CSI parameter fields (this is how the HSPC CSI driver works, all six are required):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc-hitachi-vsp5044
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: hspc.csi.hitachi.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
parameters:
  serialNumber: "55044"
  poolID: "2"
  portID: "CL3-A,CL3-B,CL4-A,CL4-B"
  connectionType: fc
  storageEfficiency: "CompressionDeduplication"
  storageEfficiencyMode: "Inline"
  csi.storage.k8s.io/fstype: ext4
  csi.storage.k8s.io/node-publish-secret-name: "hitachi-vsp5044-secret"
  csi.storage.k8s.io/node-publish-secret-namespace: "storage-hitachi"
  csi.storage.k8s.io/provisioner-secret-name: "hitachi-vsp5044-secret"
  csi.storage.k8s.io/provisioner-secret-namespace: "storage-hitachi"
  csi.storage.k8s.io/controller-publish-secret-name: "hitachi-vsp5044-secret"
  csi.storage.k8s.io/controller-publish-secret-namespace: "storage-hitachi"
  csi.storage.k8s.io/node-stage-secret-name: "hitachi-vsp5044-secret"
  csi.storage.k8s.io/node-stage-secret-namespace: "storage-hitachi"
  csi.storage.k8s.io/controller-expand-secret-name: "hitachi-vsp5044-secret"
  csi.storage.k8s.io/controller-expand-secret-namespace: "storage-hitachi"
```

### Parameter reference

| Parameter | Description | Example |
|-----------|-------------|---------|
| `serialNumber` | Storage array serial number | `"55044"` |
| `poolID` | Storage pool ID | `"2"` |
| `portID` | FC port IDs (comma-separated, FC only) | `"CL3-A,CL3-B,CL4-A,CL4-B"` |
| `connectionType` | `fc` or `iscsi` | `fc` |
| `storageEfficiency` | Compression/dedup setting | `"CompressionDeduplication"` |
| `storageEfficiencyMode` | When to apply efficiency | `"Inline"` |
| `csi.storage.k8s.io/fstype` | Filesystem type | `ext4` (recommended by Hitachi) |

Note on `portID`: this is only required for FC connections. For iSCSI, omit it. The port IDs correspond to the FC target ports on the storage array that are zoned to your OpenShift nodes.

### Filesystem type

Hitachi recommends **ext4** for container workloads. While xfs works, ext4 has been more stable in our experience with Hitachi CSI.

## Multiple arrays

Sites with multiple Hitachi arrays create one Secret + StorageClass per array. Only one StorageClass should be marked as the cluster default:

```yaml
# Array 1: default SC
metadata:
  name: sc-hitachi-vsp3044
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"

# Array 2: not default
metadata:
  name: sc-hitachi-vsp5044
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
```

Having more than one default StorageClass triggers the `MultipleDefaultStorageClasses` alert in OpenShift.

To use a non-default StorageClass, specify it explicitly in the PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  storageClassName: sc-hitachi-vsp5044
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

## Verification

```bash
# Check all StorageClasses
oc get sc

# Check which one is default
oc get sc -o custom-columns=NAME:.metadata.name,DEFAULT:.metadata.annotations.'storageclass\.kubernetes\.io/is-default-class'

# Test provisioning
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-hitachi
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for binding
oc get pvc test-hitachi -w

# Cleanup
oc delete pvc test-hitachi
```
