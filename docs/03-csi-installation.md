# CSI Operator Installation

The Hitachi Storage Plugin for Containers (HSPC) is installed via OLM (Operator Lifecycle Manager) from the `certified-operators` catalog. This guide covers manual installation with version pinning for production environments.

## Prerequisites

Before installing the CSI operator:

1. Multipath must be configured on all nodes (see [Multipath Configuration](02-multipath.md))
2. FC zoning must be complete (all nodes can see storage ports)
3. Storage pool, resource group, and service account must be ready (see [Storage Preparation](01-storage-preparation.md))

## Step 1: Create the namespace

The namespace needs privileged pod security labels because the CSI node plugin runs privileged containers that access host devices:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: storage-hitachi
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

```bash
oc apply -f namespace.yaml
```

## Step 2: Create the OperatorGroup

The OperatorGroup scopes the operator to its own namespace:

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: storage-hitachi-og
  namespace: storage-hitachi
spec:
  targetNamespaces:
    - storage-hitachi
  upgradeStrategy: Default
```

```bash
oc apply -f operatorgroup.yaml
```

## Step 3: Find available versions

Before creating the Subscription, check which versions are available for your OCP release:

```bash
oc get packagemanifest hspc-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}: {.currentCSV}{"\n"}{end}'
```

Example output:
```
stable: hspc-operator.v1.18.0
```

## Step 4: Create the Subscription

Pin the operator to a specific version using `startingCSV` and `Manual` approval. This prevents OLM from auto-upgrading the operator during cluster updates, which is important for storage drivers in production:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hspc-operator
  namespace: storage-hitachi
  labels:
    operators.coreos.com/hspc-operator.storage-hitachi: ""
spec:
  channel: stable
  installPlanApproval: Manual
  name: hspc-operator
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: hspc-operator.v1.18.0
```

```bash
oc apply -f subscription.yaml
```

## Step 5: Approve the InstallPlan

With Manual approval, OLM creates an InstallPlan but does not execute it until you approve:

```bash
# Wait for the InstallPlan to appear
oc get installplan -n storage-hitachi -w

# Approve it
oc patch installplan <installplan-name> -n storage-hitachi \
  --type=merge -p '{"spec":{"approved":true}}'
```

Then wait for the CSV to reach `Succeeded`:

```bash
oc get csv -n storage-hitachi -w
```

## Step 6: Create the HSPC custom resource

The HSPC CR activates the CSI controller and node plugins:

```yaml
apiVersion: csi.hitachi.com/v1
kind: HSPC
metadata:
  name: hspc
  namespace: storage-hitachi
spec:
  controller: {}
  csiDriver:
    enable: true
  node: {}
```

```bash
oc apply -f hspc.yaml
```

## Step 7: Verify CSI pods

Wait for the controller deployment and node DaemonSet to be ready:

```bash
# Controller (1 replica)
oc get deployment hspc-csi-controller -n storage-hitachi

# Node plugin (one per node)
oc get daemonset hspc-csi-node -n storage-hitachi

# All pods
oc get pods -n storage-hitachi
```

Note: CSI pods may not reach `Ready` state until they can actually communicate with the storage array. In lab environments without real storage connectivity, the pods will show CrashLoopBackOff or Error, which is expected.

## Upgrading the operator

To upgrade to a new version:

1. Update the `startingCSV` in the Subscription
2. A new InstallPlan will be created
3. Approve the new InstallPlan
4. Wait for the new CSV to reach Succeeded

```bash
# Check current version
oc get csv -n storage-hitachi

# Edit subscription to new version
oc edit subscription hspc-operator -n storage-hitachi
# Change startingCSV to the new version

# Or delete and recreate
oc delete subscription hspc-operator -n storage-hitachi
# Apply updated subscription YAML with new startingCSV

# Approve new InstallPlan
oc get installplan -n storage-hitachi
oc patch installplan <new-plan> -n storage-hitachi \
  --type=merge -p '{"spec":{"approved":true}}'
```

If a stale Subscription or InstallPlan from a previous version is stuck, delete it and recreate:

```bash
oc delete subscription hspc-operator -n storage-hitachi
oc delete csv -n storage-hitachi -l operators.coreos.com/hspc-operator.storage-hitachi
# Then reapply the Subscription with the new version
```
