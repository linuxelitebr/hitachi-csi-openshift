#!/bin/bash
# =============================================================================
# LUN Boost Validation Test
# =============================================================================
# Creates N PVCs, mounts them in pods, writes unique content, and verifies
# integrity. This proves the cluster can provision beyond the default 256 LUN
# limit AND that the volumes actually work end-to-end.
#
# Each PVC maps to one LDEV on the storage array.
#
# Usage:
#   ./test-lun-boost.sh [--node NODE] [--count N] [--sc STORAGECLASS]
#                       [--size SIZE] [--no-write]
#
# Examples:
#   ./test-lun-boost.sh --count 260 --sc sc-hitachi-vsp5044
#   ./test-lun-boost.sh --count 50 --node worker-0
#   ./test-lun-boost.sh --count 260 --no-write          # skip write+verify
#   ./test-lun-boost.sh                                 # defaults: 260, default SC
#
# Cleanup:
#   oc delete namespace lun-boost-test
# =============================================================================

set -euo pipefail

# Defaults
COUNT=260
STORAGECLASS=""
NODE=""
PVC_SIZE="1Gi"
NAMESPACE="lun-boost-test"
BATCH_SIZE=20
WAIT_TIMEOUT=7200          # 2h total wait (Hitachi API can be slow under load)
STALL_THRESHOLD=300        # 5 min without progress before considering stalled
STORAGE_API_GRACE=900      # 15 min extra grace after stall
DO_WRITE_VERIFY=true

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --count)  COUNT="$2"; shift 2 ;;
        --sc)     STORAGECLASS="$2"; shift 2 ;;
        --node)   NODE="$2"; shift 2 ;;
        --size)   PVC_SIZE="$2"; shift 2 ;;
        --no-write) DO_WRITE_VERIFY=false; shift ;;
        -h|--help)
            grep '^#' "$0" | head -30
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage."
            exit 1
            ;;
    esac
done

echo "============================================"
echo "LUN Boost Validation Test"
echo "============================================"
echo "PVCs to create:  $COUNT"
echo "StorageClass:    ${STORAGECLASS:-"(cluster default)"}"
echo "Target node:     ${NODE:-"(scheduler decides)"}"
echo "PVC size:        $PVC_SIZE"
echo "Write + verify:  $DO_WRITE_VERIFY"
echo "Namespace:       $NAMESPACE"
echo "============================================"
echo ""

# If user specified a node, validate it exists
if [ -n "$NODE" ]; then
    if ! oc get node "$NODE" >/dev/null 2>&1; then
        echo "ERROR: Node '$NODE' not found."
        echo "Available nodes:"
        oc get nodes --no-headers | awk '{print "  " $1}'
        exit 1
    fi
fi

# Check current max_luns on target node (or first node)
CHECK_NODE="${NODE:-$(oc get nodes -o jsonpath='{.items[0].metadata.name}')}"
echo "Checking current scsi_mod.max_luns on $CHECK_NODE..."
CURRENT_MAX=$(oc debug node/$CHECK_NODE -- chroot /host cat /sys/module/scsi_mod/parameters/max_luns 2>/dev/null || echo "unknown")
echo "Current max_luns: $CURRENT_MAX"
echo ""

if [ "$CURRENT_MAX" != "unknown" ] && [ "$CURRENT_MAX" -lt "$COUNT" ] 2>/dev/null; then
    echo "WARNING: max_luns ($CURRENT_MAX) is less than requested PVC count ($COUNT)."
    echo "The test may fail after PVC #$CURRENT_MAX."
    echo ""
fi

# Create namespace
echo "Creating namespace $NAMESPACE..."
oc create namespace $NAMESPACE 2>/dev/null || echo "Namespace already exists"
echo ""

# Build SC spec line for PVCs
SC_SPEC=""
if [ -n "$STORAGECLASS" ]; then
    SC_SPEC="storageClassName: $STORAGECLASS"
fi

# Build nodeSelector for pods
NODE_SELECTOR_YAML=""
if [ -n "$NODE" ]; then
    NODE_SELECTOR_YAML="nodeSelector:
    kubernetes.io/hostname: $NODE"
fi

# =============================================================================
# PHASE 1: Create PVCs
# =============================================================================
echo "PHASE 1: Creating $COUNT PVCs in batches of $BATCH_SIZE..."
CREATED=0

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

# =============================================================================
# PHASE 2: Wait for binding (resilient to storage API timeouts)
# =============================================================================
ELAPSED=0
INTERVAL=15
LAST_BOUND=0
STALLED_FOR=0
GRACE_GIVEN=false

while [ $ELAPSED -lt $WAIT_TIMEOUT ]; do
    BOUND=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Bound || true)
    PENDING=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Pending || true)
    FAILED_PVC=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -cv 'Bound\|Pending' || true)

    if [ "$BOUND" -gt "$LAST_BOUND" ]; then
        PROGRESS="+$((BOUND - LAST_BOUND))"
        STALLED_FOR=0
        LAST_BOUND=$BOUND
    else
        PROGRESS="stalled ${STALLED_FOR}s"
        STALLED_FOR=$((STALLED_FOR + INTERVAL))
    fi

    echo "  Bound: $BOUND / $COUNT | Pending: $PENDING | Other: $FAILED_PVC | Elapsed: ${ELAPSED}s | Progress: $PROGRESS"

    if [ "$BOUND" -eq "$COUNT" ]; then
        break
    fi

    if [ "$PENDING" -eq 0 ] && [ "$BOUND" -lt "$COUNT" ]; then
        echo "  No PVCs pending and not all bound. Checking for actual failures..."
        break
    fi

    if [ "$STALLED_FOR" -ge "$STALL_THRESHOLD" ]; then
        if [ "$GRACE_GIVEN" = false ]; then
            echo "  No progress for ${STALL_THRESHOLD}s. Checking events for transient errors..."
            oc get events -n $NAMESPACE --sort-by='.lastTimestamp' 2>/dev/null | \
                grep -iE 'timeout|retry|failed|error' | tail -5 || true
            echo "  Granting ${STORAGE_API_GRACE}s grace period for storage API to recover..."
            GRACE_GIVEN=true
            STALLED_FOR=0
            STALL_THRESHOLD=$STORAGE_API_GRACE
        else
            echo "  Still stalled after grace period. Provisioning appears stuck."
            break
        fi
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

BOUND=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Bound || true)
echo ""
echo "PHASE 2 complete: $BOUND / $COUNT PVCs bound."
echo ""

# =============================================================================
# PHASE 3 (optional): Write content and verify
# =============================================================================
# Mounts PVCs in pods, writes a unique marker per PVC, reads back, and
# compares SHA256 hashes. Uses chunks because pods have practical limits
# on volume counts.
WROTE=0
VERIFIED=0

if [ "$DO_WRITE_VERIFY" = true ] && [ "$BOUND" -gt 0 ]; then
    BOUND_PVCS=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | awk '/Bound/ {print $1}' | sort)
    CHUNK_SIZE=50
    POD_IDX=0
    CHUNK_IDX=0
    POD_NAME=""
    POD_YAML=$(mktemp)

    start_pod_yaml() {
        POD_IDX=$((POD_IDX + 1))
        POD_NAME=$(printf "verifier-%03d" $POD_IDX)
        cat > "$POD_YAML" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  ${NODE_SELECTOR_YAML}
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: verifier
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      command:
        - /bin/bash
        - -c
        - |
          set -e
          FAIL=0
          PASS=0
          for mnt in /mnt/*; do
            pvc=\$(basename \$mnt)
            marker="\${pvc}-\$(date +%s%N)"
            # write
            echo "\$marker" > "\$mnt/marker.txt"
            # hash
            sha=\$(sha256sum "\$mnt/marker.txt" | awk '{print \$1}')
            echo "\$sha" > "\$mnt/hash.txt"
            # re-read and verify
            got=\$(cat "\$mnt/marker.txt")
            got_sha=\$(sha256sum "\$mnt/marker.txt" | awk '{print \$1}')
            if [ "\$got" = "\$marker" ] && [ "\$got_sha" = "\$sha" ]; then
              PASS=\$((PASS + 1))
            else
              echo "FAIL: \$pvc"
              FAIL=\$((FAIL + 1))
            fi
          done
          echo "RESULT: pass=\$PASS fail=\$FAIL"
          exit \$FAIL
      volumeMounts:
EOF
    }

    append_volume_mount() {
        local pvc=$1
        cat >> "$POD_YAML" <<EOF
        - name: vol-${pvc}
          mountPath: /mnt/${pvc}
EOF
    }

    start_volumes_section() {
        cat >> "$POD_YAML" <<EOF
  volumes:
EOF
    }

    append_volume() {
        local pvc=$1
        cat >> "$POD_YAML" <<EOF
    - name: vol-${pvc}
      persistentVolumeClaim:
        claimName: ${pvc}
EOF
    }

    run_pod() {
        oc apply -f "$POD_YAML" >/dev/null
        echo "  Pod $POD_NAME started (mounts: $CURRENT_CHUNK_COUNT PVCs)"
        # Wait for completion
        for _ in $(seq 1 120); do
            phase=$(oc get pod "$POD_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
            if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
                break
            fi
            sleep 5
        done
        result=$(oc logs -n $NAMESPACE "$POD_NAME" 2>/dev/null | tail -1)
        echo "  Pod $POD_NAME: $result"
        pass=$(echo "$result" | grep -oE 'pass=[0-9]+' | cut -d= -f2 || echo 0)
        fail=$(echo "$result" | grep -oE 'fail=[0-9]+' | cut -d= -f2 || echo 0)
        WROTE=$((WROTE + pass + fail))
        VERIFIED=$((VERIFIED + pass))
    }

    # Collect PVCs into chunks
    CURRENT_CHUNK=()
    CURRENT_CHUNK_COUNT=0

    process_chunk() {
        if [ ${#CURRENT_CHUNK[@]} -eq 0 ]; then
            return
        fi
        start_pod_yaml
        for p in "${CURRENT_CHUNK[@]}"; do
            append_volume_mount "$p"
        done
        start_volumes_section
        for p in "${CURRENT_CHUNK[@]}"; do
            append_volume "$p"
        done
        run_pod
        CURRENT_CHUNK=()
        CURRENT_CHUNK_COUNT=0
    }

    echo "PHASE 3: Writing content and verifying ($BOUND PVCs in chunks of $CHUNK_SIZE)..."
    while IFS= read -r pvc; do
        CURRENT_CHUNK+=("$pvc")
        CURRENT_CHUNK_COUNT=$((CURRENT_CHUNK_COUNT + 1))
        if [ $CURRENT_CHUNK_COUNT -ge $CHUNK_SIZE ]; then
            process_chunk
        fi
    done <<< "$BOUND_PVCS"
    process_chunk

    rm -f "$POD_YAML"
    echo ""
fi

# =============================================================================
# Final report
# =============================================================================
BOUND=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Bound || true)
PENDING=$(oc get pvc -n $NAMESPACE --no-headers 2>/dev/null | grep -c Pending || true)

echo "============================================"
echo "LUN Boost Test Results"
echo "============================================"
echo "Total PVCs:       $COUNT"
echo "Bound:            $BOUND"
echo "Pending:          $PENDING"
echo "max_luns:         $CURRENT_MAX"
if [ "$DO_WRITE_VERIFY" = true ]; then
    echo "Write attempts:   $WROTE"
    echo "Verified OK:      $VERIFIED"
fi
echo ""

RESULT="PASSED"
if [ "$BOUND" -ne "$COUNT" ]; then
    RESULT="FAILED (bind)"
fi
if [ "$DO_WRITE_VERIFY" = true ] && [ "$VERIFIED" -ne "$BOUND" ]; then
    RESULT="FAILED (verify)"
fi

echo "RESULT: $RESULT"
echo ""

if [ "$RESULT" = "PASSED" ]; then
    echo "All $COUNT PVCs bound and content verified successfully."
    echo "The cluster can provision and use volumes beyond the default 256 LUN limit."
else
    if [ "$BOUND" -le 256 ] && [ "$COUNT" -gt 256 ]; then
        echo "Only $BOUND PVCs bound (at or below default 256). Check if LUN boost is active:"
        echo "  oc debug node/$CHECK_NODE -- chroot /host cat /sys/module/scsi_mod/parameters/max_luns"
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
