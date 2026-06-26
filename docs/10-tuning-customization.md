# 10. Tuning and customizing the CSI controller

Sooner or later you need to change the `hspc-csi-controller` pod: bump a sidecar timeout
because the Hitachi REST API is slow under load, raise its CPU and memory, or add a
scheduling constraint. Here is what the `HSPC` custom resource actually lets you change, what
it refuses, and the one unsupported escape hatch, all measured on a live cluster (HSPC
operator v1.18.2).

## The mental model: operator vs operand

The `hspc-csi-controller` Deployment is an **operand**. It is created and owned by the
`HSPC` custom resource (you can see the `ownerReferences` point back to `kind: HSPC`), and
the `hspc-operator-controller-manager` reconciles it continuously. That has one hard
consequence:

> Any direct `oc edit deployment hspc-csi-controller` is reverted on the next reconcile
> (an operator restart, an upgrade, or any change to the `HSPC` CR triggers it).

So the supported way to change the controller is through the `HSPC` CR, not the Deployment.

## Tuning reference: every knob, where it lives, how to reach it

This is the full menu of what you might want to tune on the CSI stack, measured on operator
v1.18.2. "How to reach it" is the honest part: most of the interesting knobs are not reachable
through the CR today.

| Knob | Default | Lives in | What it affects | How to change it today |
|------|---------|----------|-----------------|------------------------|
| `affinity` / `tolerations` / `priorityClassName` | none | controller + node pods | scheduling and placement | **CR**, supported and durable |
| CPU / memory `resources` | sidecars 30m/50Mi to 500m/500Mi; driver 1c/500Mi to 4c/2Gi | all containers | resource headroom | No CR knob. A VPA can raise requests at admission if `oc adm top` shows real pressure. Feature request open |
| `csi-provisioner --timeout` | `400s` | csi-provisioner sidecar | gRPC deadline per provision/attach before the sidecar gives up and retries | Not CR-settable. Operator-paused edit (stopgap) or Hitachi |
| `csi-provisioner --worker-threads` | `20` | csi-provisioner sidecar | concurrent provision operations | Same |
| `csi-provisioner --retry-interval-start` / `--retry-interval-max` | `1s` / `5m` (defaults, not set explicitly) | csi-provisioner sidecar | backoff between provision retries (retry already happens by default when the driver returns a retryable gRPC code) | Same |
| `SPC_LUN_MAX` | `256` | hspc-csi-driver (controller) | max LUNs the driver manages | Same |
| `SPC_MAX_CONCURRENT_NODE_OPS` | `20` | hspc-csi-driver (node DaemonSet) | concurrent node-side ops (rescan + NodeStage). Too low serializes mounts, too high floods rescans | Same (node side) |
| `IS_BULK_MAPPING_MODE_ENABLED` | `true` | hspc-csi-driver | bulk LUN mapping | Same |
| NodeStage device-detection timeout | internal, not exposed | hspc-csi-driver (node) | how long NodeStage waits for the multipath device before returning `Aborted` (the `0x0000c008` retry loop) | Not exposed. Hitachi feature request |
| driver-to-VSP REST timeout/retry | internal, not exposed | hspc-csi-driver | how the driver handles a slow array REST API | Not exposed |
| multipath (`no_path_retry`, `path_grouping_policy`, ...) | see the multipath chapter | node OS (`/etc/multipath.conf`) | path failover, queueing, device assembly | **MachineConfig**, supported. See [02-multipath](02-multipath.md) |
| max LUNs per host (`max_luns`) | see the LUN boost chapter | node kernel | how many LUNs the host can see | **MachineConfig**, supported. See [06-lun-boost](06-lun-boost.md) |

Read it as two groups. The supported, durable knobs are scheduling on the CR and anything
delivered by MachineConfig (multipath, LUN boost). Everything that lives inside the
`hspc-csi-controller` and `hspc-csi-node` containers (the sidecar flags, the `SPC_*` env, the
detection and REST timeouts) has no supported path today, because `spec.controller.containers[]`
rejects every container name (see below). For those the choices are the unsupported
operator-paused edit or a feature request to Hitachi.

## What the `HSPC` CR can override

The CR exposes a `controller` (and a matching `node`) override block:

```console
$ oc explain hspc.spec.controller
FIELDS:
  affinity           <Object>
  containers         <[]Object>
  priorityClassName  <string>
  tolerations        <[]Object>
```

So you **can** set, supported and reconcile-proof:

- `affinity`, `tolerations`, `priorityClassName` for the controller pod.

The schema also advertises a per-container `containers[]` override carrying `args`/`env`/`image`
for a "whitelisted" container. In practice, on operator v1.18.2, no real container name is
accepted (measured below), so scheduling is the only override you can rely on today.

## What the CR cannot do (measured)

### It has no `resources` and no `replicas`

```console
$ oc explain hspc.spec.controller.containers.resources
error: field "resources" does not exist
$ oc explain hspc.spec.controller.replicas
error: field "replicas" does not exist
```

There is **no supported way to set the CPU/memory requests/limits** of the controller (or
node) pods, and no way to scale the controller. The defaults are fixed:

| container | requests | limits |
|---|---|---|
| csi-provisioner / external-attacher / csi-resizer / csi-snapshotter / liveness-probe | cpu 30m, mem 50Mi | cpu 500m, mem 500Mi |
| hspc-csi-driver | cpu 1, mem 500Mi | cpu 4, mem 2Gi |

### `containers[]` rejects every container name (sidecars and the driver)

This is the trap. `spec.controller.containers[]` only accepts the operator's **whitelisted**
container(s). The standard CSI sidecars (`csi-provisioner`, `external-attacher`,
`csi-resizer`, `csi-snapshotter`) are **not** on that list. Setting one anyway does not just
get ignored, it puts the operator into a reconcile error loop:

```console
$ oc patch hspc hspc -n storage-hitachi --type=merge -p \
  '{"spec":{"controller":{"containers":[{"name":"csi-provisioner","args":["--timeout=600s", ...]}]}}}'
hspc.csi.hitachi.com/hspc patched

$ oc logs deploy/hspc-operator-controller-manager -n storage-hitachi | tail
ERROR  controllers.HSPC  Failed to created HSPC instance  {"error": "invalid container \"csi-provisioner\" found"}
ERROR  Reconciler error  {"controller":"hspc", ... "error": "invalid container \"csi-provisioner\" found"}
```

The controller Deployment is left unchanged and the operator stops reconciling cleanly until
you remove the bad override. **If you hit this, revert immediately:**

```console
$ oc patch hspc hspc -n storage-hitachi --type=json -p '[{"op":"remove","path":"/spec/controller/containers"}]'
```

The same rejection happens for the **`hspc-csi-driver`** container itself. Setting
`containers:[{name: hspc-csi-driver, env: [...]}]` (restating the existing env and only
changing `SPC_LUN_MAX`) returns `invalid container "hspc-csi-driver" found` and breaks
reconcile the same way:

```console
$ oc logs deploy/hspc-operator-controller-manager -n storage-hitachi | tail
ERROR  controllers.HSPC  Reconciler error  {"error": "invalid container \"hspc-csi-driver\" found"}
$ oc patch hspc hspc -n storage-hitachi --type=json -p '[{"op":"remove","path":"/spec/controller/containers"}]'
```

So on operator v1.18.2 **no container name is accepted** by `spec.controller.containers[]`,
neither the sidecars nor the driver, and `.name` has no documented valid value
(`oc explain hspc.spec.controller.containers.name` returns an empty description). The CSI sidecar
flags (`--timeout`, `--worker-threads`, `--retry-interval-*`) and the driver `env` (`SPC_*`) are
therefore **not** tunable through the CR.

This is where the docs and the implementation disagree, and it is worth knowing before you spend
a day on it. Hitachi product documentation shows a `containers[]` customization using exactly the
names `csi-provisioner` and `hspc-csi-driver`, but the installed operator is
`hspc-operator.v1.18.2`, the newest in the Red Hat certified `stable` channel, and it rejects
both. So this is not a "you are behind" problem. The likely explanations: the customization lives
in the Hitachi-registry distribution rather than the certified `stable` channel, the valid
container name differs in this version, or it is a documentation gap. The question to put to
Hitachi: which version and distribution accept `spec.controller.containers[]`, and what is the
valid container name? Until they answer, do not assume an upgrade fixes it.

## The unsupported escape hatch: pause the operator

If you truly must change a sidecar flag (for example, raise `csi-provisioner --timeout` from
its default of `400s` because the array REST API is slow under load), the only thing that
works is to pause the operator and edit the operand by hand. **It is not supported, and it
does not survive the operator coming back.** Measured, step by step:

**1. Pause the operator.**

```console
$ oc scale deploy hspc-operator-controller-manager -n storage-hitachi --replicas=0
```

**2. Edit the sidecar args directly.** Restate every arg, the list is replaced wholesale.

```console
$ oc patch deploy hspc-csi-controller -n storage-hitachi --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"csi-provisioner","args":[
     "--csi-address=/csi/csi-controller.sock","--timeout=600s","--v=5",
     "--worker-threads=20","--default-fstype=ext4","--retry-interval-max=10m"]}]}}}}'
```

**3. While the operator is off, it sticks.**

```console
$ oc get deploy hspc-csi-controller -o json | jq '...csi-provisioner.args'
["--timeout=600s", "--retry-interval-max=10m", ...]
```

**4. Bring the operator back.**

```console
$ oc scale deploy hspc-operator-controller-manager -n storage-hitachi --replicas=1
```

**5. About 12 seconds later, the operator reverts it to the default.**

```console
$ oc get deploy hspc-csi-controller -o json | jq '...csi-provisioner.args'
["--timeout=400s", ...]
```

So this only holds while the operator stays at `0`, which means no reconciliation, no
self-healing, and a broken upgrade path for the whole CSI stack (the controller, the
telemetry controller, the `hspc-csi-node` DaemonSet, the RBAC). Treat it as a temporary
stopgap, not a steady state.

## Tuning provisioning API access: timeouts, retries, concurrency

When the motivation is "the array REST API is slow under load, so provisioning times out or
fails", the knobs are CSI sidecar flags plus the driver's internal REST handling. The sidecar
flags are reachable only through the operator-paused escape hatch above, until Hitachi exposes
them on the CR.

| Flag (container) | Default | What it does | When to raise it |
|---|---|---|---|
| `csi-provisioner --timeout` | `400s` | gRPC deadline per CreateVolume/DeleteVolume before the sidecar gives up and retries | the array genuinely needs longer than 400s per provision |
| `csi-provisioner --retry-interval-start` | `1s` | first backoff after a failed provision | a gentler initial retry on transient errors |
| `csi-provisioner --retry-interval-max` | `5m` | cap on the backoff between retries | let a slow-to-recover array have longer gaps |
| `csi-provisioner --worker-threads` | `20` | concurrent provision operations | raise for throughput, lower to ease load on a struggling array |
| `external-attacher --timeout` | `400s` | deadline per attach/detach (ControllerPublish/Unpublish) | slow attach under load |
| `csi-resizer --timeout` | `400s` | deadline per volume expand | slow resize |
| `csi-snapshotter --timeout` | `400s` | deadline per snapshot | slow snapshot |

Example: tune the `csi-provisioner` for a slow-but-eventually-successful array. Apply it with the
operator paused (the escape hatch above), restating the whole args list because the patch
replaces it wholesale:

```console
$ oc patch deploy hspc-csi-controller -n storage-hitachi --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"csi-provisioner","args":[
     "--csi-address=/csi/csi-controller.sock",
     "--timeout=600s",
     "--retry-interval-start=10s",
     "--retry-interval-max=10m",
     "--worker-threads=20",
     "--v=5",
     "--default-fstype=ext4"]}]}}}}'
```

One thing to keep in mind before you tune retries: the `csi-provisioner` already retries a failed
provision on its own, with that backoff, as long as the driver returns a retryable gRPC code. If
the driver returns a non-retryable code for a failure, no amount of retry tuning makes it retry.
That distinction is on the driver side, not in these flags.

The driver has knobs too, but they are `env` on the `hspc-csi-driver` container (`SPC_LUN_MAX`,
`SPC_MAX_CONCURRENT_NODE_OPS`, `IS_BULK_MAPPING_MODE_ENABLED`), reachable only through the same
escape hatch (the CR rejects the driver name). The driver-to-VSP REST call timeout and retry are
internal and not exposed at all. The StorageClass and Secret carry only connection parameters
(`url`, `user`, `password`, `resourceGroupID`, `poolID`, `portID`, `serialNumber`), no timeout or
retry.

## Raising controller resources with a VerticalPodAutoscaler

Measure first. On the controller I checked, the `hspc-csi-driver` sat at 0m CPU against a 1-core
request, so there was nothing to raise. Run `oc adm top pods -n storage-hitachi` and only go
further if you see real pressure.

If you do, a VPA is the resilient way to raise the requests without pausing the operator. It
mutates the pod at admission, and the operator owns the Deployment template rather than the
admitted pod, so its reconcile does not undo the change. It needs the Red Hat VerticalPodAutoscaler
operator (`redhat-operators`, channel `stable`).

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: hspc-csi-controller-vpa
  namespace: storage-hitachi
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hspc-csi-controller
  updatePolicy:
    updateMode: Initial
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        mode: "Off"
      - containerName: hspc-csi-driver
        mode: Auto
        minAllowed: { cpu: "1500m", memory: "1Gi" }
        maxAllowed: { cpu: "4", memory: "2Gi" }
```

How it behaves:

- `updateMode: Initial` sets the requests when the pod is created, with no disruptive eviction.
  Trigger it with `oc rollout restart deploy/hspc-csi-controller`.
- `containerName: "*"` set to `Off` scopes the VPA to the `hspc-csi-driver` container only, so the
  sidecars are left alone.
- `minAllowed` is the floor the admission controller injects.

Measured: after a rollout the new pod came up with the driver request at `1500m`/`1Gi` while the
Deployment template stayed at the operator's `1` core. Forcing an operator reconcile and another
rollout kept the pod at `1500m`/`1Gi`. The VPA and the operator do not fight, because they act on
different layers.

## Recommendation

- **Scheduling** (placement, priority): set it on the `HSPC` CR. Supported and durable.
- **CPU and memory**: measure first (the driver I checked sat at 0m CPU). If there is real
  pressure, raise it with a VPA rather than pausing the operator, per the section above.
- **Sidecar timeout/retry**: the only lever today is the operator-paused edit above, a
  stopgap, not a durable fix. Push Hitachi to expose these settings on the CRD. The
  reproducible `oc explain` evidence on this page is what gets it onto their backlog.

> Validated on HSPC operator v1.18.2 (certified-operators, channel `stable`), OpenShift, on
> 2026-06-26. The CR rejected the sidecar override, the scale-to-0 edit applied and then was
> reverted by the operator within seconds of it returning.
