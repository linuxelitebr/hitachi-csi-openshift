#!/bin/bash
# =============================================================================
# LUN Boost Validation Test
# =============================================================================
# Creates N PVCs and pods to verify the cluster can provision beyond the
# default 256 LUN limit. Each PVC maps to one LDEV on the storage array.
#
# Usage:
#   ./test-lun-boost.sh [count] [storageclass]
#
# Examples:
#   ./test-lun-boost.sh 260 sc-hitachi-vsp5044
#   ./test-lun-boost.sh 50                        # uses default SC
#   ./test-lun-boost.sh                           # 260 PVCs, default SC
#
# Cleanup:
#   oc delete namespace lun-boost-test
# =============================================================================

set -euo pipefail

COUNT=${1:-260}
STORAGECLASS=${2:-""}
NAMESPACE="lun-boost-test"
PVC_SIZE="1Gi"
BATCH_SIZE=20
WAIT_TIMEOUT=600

echo "============================================"
echo "LUN Boost Validation Test"
echo "============================================"
echo "PVCs to create:  $COUNT"
echo "StorageClass:    ${STORAGECLASS:-"(cluster default)"}"
echo "Namespace:       $NAMESPACE"
echo "PVC size:        $PVC_SIZE"
echo "Batch size:      $BATCH_SIZE"
echo "============================================"
echo ""

# Check current max_luns
echo "Checking current scsi_mod.max_luns on first node..."
FIRST_NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
CURRENT_MAX=$(oc debug node/$FIRST_NODE -- chroot /host cat /sys/module/scsi_mod/parameters/max_luns 2>/dev/null || echo "unknown")
echo "Current max_luns: $CURRENT_MAX"
echo ""

if [ "$CURRENT_MAX" != "unknown" ] && [ "$CURRENT_MAX" -lt "$COUNT" ]; then
    echo "WARNING: max_luns ($CURRENT_MAX) is less than requested PVC count ($COUNT)."
    echo "The test may fail after PVC #$CURRENT_MAX."
    echo ""
fi

# Create namespace
echo "Creating namespace $NAMESPACE..."
oc create namespace $NAMESPACE 2>/dev/null || echo "Namespace already exists"
echo ""

# Build SC spec line
SC_SPEC=""
if [ -n "$STORAGECLASS" ]; then
    SC_SPEC="storageClassName: $STORAGECLASS"
fi

# Create PVCs in batches
echo "Creating $COUNT PVCs in batches of $BATCH_SIZE..."
CREATED=0
FAILED=0

for i in $(seq 1 $COUNT); do
    NAME=$(printf "pvc-%04d" $i)

    cat <<EOF | oc apply -f - > /dev/null 2>&1 &
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NAME
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  ${SC_SPEC:+$SC_SPEC}
  resources:
    requests:
      storage: $PVC_SIZE
EOF

    CREATED=$((CREATED + 1))

    # Wait for batch to complete
    if [ $((CREATED % BATCH_SIZE)) -eq 0 ]; then
        wait
        BOUND=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Bound || true)
        PENDING=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Pending || true)
        echo "  Created: $CREATED / $COUNT | Bound: $BOUND | Pending: $PENDING"
    fi
done

wait
echo ""
echo "All $COUNT PVCs submitted. Waiting for binding..."
echo ""

# Wait for PVCs to bind
ELAPSED=0
INTERVAL=15
while [ $ELAPSED -lt $WAIT_TIMEOUT ]; do
    BOUND=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Bound || true)
    PENDING=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Pending || true)
    FAILED_PVC=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -cv 'Bound\|Pending' || true)

    echo "  Bound: $BOUND / $COUNT | Pending: $PENDING | Other: $FAILED_PVC | Elapsed: ${ELAPSED}s"

    if [ "$BOUND" -eq "$COUNT" ]; then
        break
    fi

    if [ "$PENDING" -eq 0 ] && [ "$BOUND" -lt "$COUNT" ]; then
        echo "WARNING: No PVCs pending but not all bound. Some may have failed."
        break
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

# Final report
BOUND=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Bound || true)
PENDING=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Pending || true)

echo "============================================"
echo "LUN Boost Test Results"
echo "============================================"
echo "Total PVCs:   $COUNT"
echo "Bound:        $BOUND"
echo "Pending:      $PENDING"
echo "max_luns:     $CURRENT_MAX"
echo ""

if [ "$BOUND" -eq "$COUNT" ]; then
    echo "RESULT: PASSED"
    echo ""
    echo "All $COUNT PVCs bound successfully."
    echo "The cluster can provision beyond the default 256 LUN limit."
else
    echo "RESULT: FAILED"
    echo ""
    echo "Only $BOUND of $COUNT PVCs bound."
    if [ "$BOUND" -le 256 ] && [ "$COUNT" -gt 256 ]; then
        echo "This suggests scsi_mod.max_luns is still at the default (256)."
        echo "Apply the LUN boost MachineConfig and retry after MCP rollout."
    fi
    echo ""
    echo "Check failed PVCs:"
    echo "  oc get pvc -n $NAMESPACE | grep -v Bound"
    echo ""
    echo "Check CSI provisioner logs:"
    echo "  oc logs -n storage-hitachi deployment/hspc-csi-controller -c hspc-csi-driver --tail=50"
fi

echo "============================================"
echo ""
echo "Cleanup when done:"
echo "  oc delete namespace $NAMESPACE"
echo ""
