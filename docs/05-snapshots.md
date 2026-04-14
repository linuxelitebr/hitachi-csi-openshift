# VolumeSnapshotClass

VolumeSnapshots allow you to create point-in-time copies of persistent volumes. Each Hitachi array that supports snapshots needs its own VolumeSnapshotClass.

## Configuration

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: snapshotclass-hitachi-vsp5044
driver: hspc.csi.hitachi.com
deletionPolicy: Delete
parameters:
  poolID: "2"
  csi.storage.k8s.io/snapshotter-secret-name: "hitachi-vsp5044-secret"
  csi.storage.k8s.io/snapshotter-secret-namespace: "storage-hitachi"
```

The `poolID` should match the pool used for the corresponding StorageClass. The snapshot Secret references are similar to the StorageClass but only need the snapshotter pair.

## LDEV considerations

Each snapshot consumes an LDEV on the storage array. If you plan to use snapshots regularly (for backups, cloning, etc.), factor this into your LDEV allocation when setting up the storage pool. See [Storage Preparation](01-storage-preparation.md).

## Deletion policy

- `Delete`: when the VolumeSnapshot object is deleted from Kubernetes, the underlying storage snapshot is also deleted
- `Retain`: the storage snapshot is preserved even after the Kubernetes object is deleted

For most use cases, `Delete` is appropriate. Use `Retain` only if you need snapshots to survive beyond the lifecycle of the Kubernetes object.

## Usage

```bash
# Create a snapshot of an existing PVC
oc apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: snapshotclass-hitachi-vsp5044
  source:
    persistentVolumeClaimName: my-existing-pvc
EOF

# Check status
oc get volumesnapshot my-snapshot -o yaml

# Restore from snapshot (create new PVC)
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-from-snapshot
  namespace: default
spec:
  storageClassName: sc-hitachi-vsp5044
  dataSource:
    name: my-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF
```
