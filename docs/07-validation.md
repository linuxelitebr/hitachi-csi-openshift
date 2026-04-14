# Validation

After deploying the CSI driver and creating StorageClasses, validate that everything works end-to-end before handing the cluster over to application teams.

## Quick PVC test

The simplest test: create a PVC and verify it binds:

```bash
# Create test PVC
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Watch until it binds
oc get pvc csi-test-pvc -w
# Should transition from Pending to Bound

# Cleanup
oc delete pvc csi-test-pvc
```

If the PVC stays in `Pending`, check the CSI provisioner logs:

```bash
oc logs -n storage-hitachi deployment/hspc-csi-controller -c hspc-csi-driver
```

## Full functional test (SAN RTA)

For a thorough validation, test PVC creation, pod mount, and data write on every node. This catches node-specific issues like missing multipath, incorrect FC zoning, or per-node connectivity problems.

The test flow:

1. Create a test namespace (`dummysan`)
2. Create one PVC per schedulable node using the target StorageClass
3. Create a test pod per node (pinned via `nodeSelector`) that mounts the PVC
4. Each pod writes a test file to the mounted volume
5. Run FC diagnostics on each node (HBA status, multipath devices)
6. If any pod fails to mount, trigger an FC LIP rescan and retry
7. Clean up all test resources

The test pods use `ubi8/ubi-minimal:latest` with proper security context (non-root, seccomp profile, dropped capabilities) to match real workload conditions.

### Running the test manually

```bash
# Create test namespace
oc create namespace dummysan

# For each node, create a PVC + pod
NODE=worker-0
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-${NODE}
  namespace: dummysan
spec:
  storageClassName: sc-hitachi-vsp5044
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-${NODE}
  namespace: dummysan
spec:
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test
      image: registry.access.redhat.com/ubi8/ubi-minimal:latest
      command: ["sh", "-c", "df -h /mnt/test && echo 'write test' > /mnt/test/testfile && ls -la /mnt/test/ && sleep 300"]
      volumeMounts:
        - name: test-vol
          mountPath: /mnt/test
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-${NODE}
  restartPolicy: Never
EOF

# Check results
oc get pvc -n dummysan
oc get pods -n dummysan -o wide
oc logs -n dummysan test-${NODE}

# Cleanup
oc delete namespace dummysan
```

## FC diagnostics

If PVCs bind but pods fail to mount (the PVC transitions to Bound, but the pod shows `ContainerCreating` or mount errors), run FC diagnostics:

```bash
# Check FC HBA status on a node
oc debug node/<node> -- chroot /host bash -c '
  for host in /sys/class/fc_host/host*; do
    echo "=== $(basename $host) ==="
    echo "Port Name: $(cat $host/port_name)"
    echo "Port State: $(cat $host/port_state)"
    echo "Speed: $(cat $host/speed)"
  done
'

# Check multipath devices
oc debug node/<node> -- chroot /host multipath -ll

# Force FC LIP rescan (if LUNs are not visible)
oc debug node/<node> -- chroot /host bash -c '
  for host in /sys/class/fc_host/host*; do
    echo "Rescanning $(basename $host)..."
    echo 1 > $host/issue_lip
    sleep 10
  done
'
```

After a LIP rescan, wait 30 seconds and check multipath again. New LUNs should appear.

## Common validation failures

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| PVC stuck in Pending | CSI provisioner cannot reach storage API | Check Secret credentials and storage URL |
| PVC stuck in Pending | Pool has no free LDEVs | Ask storage admin to allocate more LDEVs |
| Pod stuck in ContainerCreating | Multipath not configured | Apply multipath MachineConfig and wait for rollout |
| Pod stuck in ContainerCreating | FC zoning incomplete | Verify all nodes can see storage ports |
| `HSPC0x0000c008` in events | Device not found on node | Check multipath, FC zoning, and service account permissions |
| `Permission denied` (-13) | Wrong credentials or insufficient permissions | Verify Secret contents and storage service account permissions |
