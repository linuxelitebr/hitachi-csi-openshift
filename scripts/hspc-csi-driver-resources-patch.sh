#!/usr/bin/env bash
#
# hspc-csi-driver-resources-patch.sh
#
# Override the resources (requests/limits) of the hspc-csi-driver container
# in the hspc-csi-controller Deployment (Hitachi CSI driver).
#
# The Deployment is owned by the HSPC CR and reconciled by
# hspc-operator-controller-manager. The HSPC CR (spec.controller) does NOT
# expose a resources field, so the resources cannot be set declaratively
# via the CR; a direct Deployment patch is the only path. Because the
# operator may re-template (revert) the Deployment, this script scales the
# operator to 0 first, patches, then scales it back (or leaves it down,
# see KEEP_MANAGER_DOWN).
#
# A timestamped backup of the Deployment is taken before any change, and
# the patch is verified both while the operator is down (authoritative) and
# after it is scaled back (where it is polled for an operator revert).
#
# NOTE: with the operator running this change does NOT persist. The operator
# re-templates the Deployment within ~30-60s of restarting and resets the
# resources. The only ways to keep it are KEEP_MANAGER_DOWN=true (the whole
# CSI stack then runs unreconciled) or a VerticalPodAutoscaler, which raises
# requests at pod admission and survives the operator. See
# docs/10-tuning-customization.md.
#
# Usage:
#   ./hspc-csi-driver-resources-patch.sh
#   DRY_RUN=true ./hspc-csi-driver-resources-patch.sh
#   KEEP_MANAGER_DOWN=true ./hspc-csi-driver-resources-patch.sh   # don't scale operator back
#   REQ_CPU=2 REQ_MEM=1Gi LIM_CPU=8 LIM_MEM=4Gi ./hspc-csi-driver-resources-patch.sh
#
# Exit: 0 ok, 1 error, 2 operator reverted after scale-back.

set -euo pipefail

# ======================= CONFIG =======================
TARGET_NS="${TARGET_NS:-storage-hitachi}"
TARGET_DEPLOY="${TARGET_DEPLOY:-hspc-csi-controller}"
TARGET_CONTAINER="${TARGET_CONTAINER:-hspc-csi-driver}"
MANAGER_NS="${MANAGER_NS:-storage-hitachi}"
MANAGER_DEPLOY="${MANAGER_DEPLOY:-hspc-operator-controller-manager}"

REQ_CPU="${REQ_CPU:-1}"
REQ_MEM="${REQ_MEM:-500Mi}"
LIM_CPU="${LIM_CPU:-4}"
LIM_MEM="${LIM_MEM:-2Gi}"

BACKUP_DIR="${BACKUP_DIR:-/tmp}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_MANAGER_DOWN="${KEEP_MANAGER_DOWN:-false}"
KUBECTL="${KUBECTL:-oc}"
WAIT_ITERS="${WAIT_ITERS:-60}"
REVERT_POLL_SECS="${REVERT_POLL_SECS:-120}"        # default mode: how long to watch for an operator revert
REVERT_POLL_INTERVAL="${REVERT_POLL_INTERVAL:-5}"
# ======================================================

ts="$(date +%Y%m%d-%H%M%S)"
backup="${BACKUP_DIR}/${TARGET_DEPLOY}-${ts}.yaml"
orig_replicas=1

log()  { printf '\n==> %s\n' "$*"; }
err()  { printf '\nERROR: %s\n' "$*" >&2; }
ok()   { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }

# If we exit unexpectedly (error or signal) while the operator is scaled down,
# restore it. Set NEED_OPERATOR_RESTORE=false once we have handled it (scaled
# back, or intentionally leaving it down via KEEP_MANAGER_DOWN).
NEED_OPERATOR_RESTORE=false
cleanup() {
  if [ "$NEED_OPERATOR_RESTORE" = "true" ]; then
    NEED_OPERATOR_RESTORE=false
    err "Unexpected exit with ${MANAGER_DEPLOY} scaled down. Restoring to ${orig_replicas} replicas..."
    $KUBECTL -n "$MANAGER_NS" scale deployment "$MANAGER_DEPLOY" --replicas="$orig_replicas" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read_resources() {
  $KUBECTL -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='${TARGET_CONTAINER}')].resources}" 2>/dev/null
}

verify() {
  local got; got="$(read_resources)"
  for kv in "\"cpu\":\"${REQ_CPU}\"" "\"memory\":\"${REQ_MEM}\"" \
            "\"cpu\":\"${LIM_CPU}\"" "\"memory\":\"${LIM_MEM}\""; do
    echo "$got" | grep -q "$kv" || return 1
  done
  return 0
}

log "Pre-flight"
$KUBECTL whoami >/dev/null || { err "Not logged in (oc whoami failed)"; exit 1; }
ok "Authenticated as $($KUBECTL whoami) @ $($KUBECTL whoami --show-server)"
$KUBECTL -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" >/dev/null 2>&1 \
  || { err "Deployment ${TARGET_NS}/${TARGET_DEPLOY} not found"; exit 1; }
ok "Target: ${TARGET_NS}/${TARGET_DEPLOY}"
$KUBECTL -n "$MANAGER_NS" get deployment "$MANAGER_DEPLOY" >/dev/null 2>&1 \
  || { err "Controller-manager ${MANAGER_NS}/${MANAGER_DEPLOY} not found. Discover with:
       oc get deploy -A | grep -iE 'hspc|hitachi|controller-manager'"; exit 1; }
ok "Manager: ${MANAGER_NS}/${MANAGER_DEPLOY}"

log "Target: req ${REQ_CPU}/${REQ_MEM}  lim ${LIM_CPU}/${LIM_MEM}"
log "Current ${TARGET_CONTAINER} resources:"; read_resources; echo

if verify; then
  ok "Already at target resources. Nothing to do."
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  if [ "$KEEP_MANAGER_DOWN" = "true" ]; then after="leave manager down"; else after="scale manager back, then poll for a revert"; fi
  log "DRY_RUN=true. Would: backup -> scale ${MANAGER_DEPLOY} to 0 -> wait -> patch ${TARGET_CONTAINER} -> ${after} -> verify"
  exit 0
fi

log "Backup -> ${backup}"
$KUBECTL -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o yaml > "$backup"
ok "Backup written"

orig_replicas="$($KUBECTL -n "$MANAGER_NS" get deployment "$MANAGER_DEPLOY" -o jsonpath='{.spec.replicas}')"
orig_replicas="${orig_replicas:-1}"
log "Scaling ${MANAGER_DEPLOY} from ${orig_replicas} to 0"
$KUBECTL -n "$MANAGER_NS" scale deployment "$MANAGER_DEPLOY" --replicas=0
NEED_OPERATOR_RESTORE=true

log "Waiting for ${MANAGER_DEPLOY} pods to terminate..."
for i in $(seq 1 "$WAIT_ITERS"); do
  cur="$($KUBECTL -n "$MANAGER_NS" get deployment "$MANAGER_DEPLOY" -o jsonpath='{.status.replicas}' 2>/dev/null)"
  { [ -z "$cur" ] || [ "$cur" = "0" ]; } && { ok "Manager down"; break; }
  sleep 2
  [ "$i" = "$WAIT_ITERS" ] && { err "Timeout waiting for manager scale-down"; exit 1; }
done

log "Patching ${TARGET_CONTAINER}"
$KUBECTL -n "$TARGET_NS" patch deployment "$TARGET_DEPLOY" --type=strategic -p "{
  \"spec\": {\"template\": {\"spec\": {\"containers\": [
    {\"name\": \"${TARGET_CONTAINER}\", \"resources\": {
      \"requests\": {\"cpu\": \"${REQ_CPU}\", \"memory\": \"${REQ_MEM}\"},
      \"limits\":   {\"cpu\": \"${LIM_CPU}\", \"memory\": \"${LIM_MEM}\"}
    }}
  ]}}}
}"

log "Verify (manager still down)"
if verify; then ok "Patch applied: $(read_resources)"; else
  fail "Patch did not land: $(read_resources)"
  err "Restore: oc -n ${TARGET_NS} apply -f ${backup}"; exit 1
fi

if [ "$KEEP_MANAGER_DOWN" = "true" ]; then
  NEED_OPERATOR_RESTORE=false   # leaving it down is intentional here
  log "KEEP_MANAGER_DOWN=true: leaving ${MANAGER_DEPLOY} at 0 replicas"
  err "NOTE: CSI reconcile is paused for the WHOLE stack (controller, node DaemonSet,
       telemetry, RBAC) while the operator is down. Scale it back when ready:
       oc -n ${MANAGER_NS} scale deployment ${MANAGER_DEPLOY} --replicas=${orig_replicas}"
  ok "Done (manager intentionally down). Backup: ${backup}"
  exit 0
fi

log "Scaling ${MANAGER_DEPLOY} back to ${orig_replicas}"
$KUBECTL -n "$MANAGER_NS" scale deployment "$MANAGER_DEPLOY" --replicas="$orig_replicas"
NEED_OPERATOR_RESTORE=false

log "Waiting for ${MANAGER_DEPLOY} to be Ready before checking for a revert..."
$KUBECTL -n "$MANAGER_NS" rollout status deployment "$MANAGER_DEPLOY" --timeout=120s || true

# The operator reverts the Deployment only after it boots and reconciles, which
# takes ~30-60s and varies run to run, so a fixed wait misses it. Poll instead.
log "Polling up to ${REVERT_POLL_SECS}s for an operator revert"
reverted=false
deadline=$(( $(date +%s) + REVERT_POLL_SECS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! verify; then reverted=true; break; fi
  sleep "$REVERT_POLL_INTERVAL"
done

if [ "$reverted" = "true" ]; then
  fail "Operator REVERTED the patch: $(read_resources)"
  err "With the operator running, this change does NOT persist. To keep it, either re-run
       with KEEP_MANAGER_DOWN=true (the whole CSI stack then runs unreconciled), or use a
       VerticalPodAutoscaler, which raises requests at pod admission and survives the
       operator (see docs/10-tuning-customization.md). Backup: ${backup}"
  exit 2
else
  ok "Resources still at target after ${REVERT_POLL_SECS}s with the operator running."
  ok "Done. Backup: ${backup}"
  exit 0
fi
