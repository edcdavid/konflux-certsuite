# Operator Onboarding Guide

This guide walks operator owners through creating a **certsuite test
bundle**, testing it locally, and onboarding their operator to the
Konflux certsuite shared test pipeline.

## What Is a Test Bundle?

A test bundle is a directory in your operator's git repository that
contains everything needed to deploy a **software-only** version of
your operator's workloads for testing. "Software-only" means:

- No specialized hardware (SR-IOV NICs, GPUs, FPGAs, PTP clocks)
- No license keys or entitlements
- No external service dependencies (cloud APIs, databases)
- No PersistentVolumes requiring specific storage classes

The goal is a portable, self-contained set of manifests that deploys
your operator's operands on any OpenShift cluster so the pipeline can
verify the operator is properly deployed and then run certsuite against
it.

The test bundle is **not** responsible for certsuite configuration --
that is managed separately via the `CERTSUITE_CONFIG_SECRET` pipeline
parameter. By default, the pipeline runs **all** certsuite tests
unless a subset is specified via `CERTSUITE_LABELS`.

## Bundle Directory Structure

```
my-operator-test-bundle/
  certsuite-test-bundle.yaml       # Required: bundle metadata
  operands/                        # Required: operand manifests
    my-custom-resource.yaml        #   Your operator's CR instances
    deployment.yaml                #   Any additional workloads
    service.yaml                   #   Services, etc.
  prerequisites/                   # Optional: pre-deploy resources
    namespace.yaml                 #   Namespace labels (e.g. privileged PSA)
    pull-secret.yaml               #   Secrets, ConfigMaps, etc.
  patches/                         # Optional: operator-specific CSV tweaks
    csv.json                       #   RFC 6902 JSON Patch (oc patch --type=json)
```

`patches/csv.json` is applied once the CSV appears via
`oc patch csv … --type=json --patch-file=…`. Use it for operator-specific
install tweaks (not generic certsuite logic). See
[Why patches/csv.json is needed for ptp-operator](#why-patchescsvjson-is-needed-for-ptp-operator)
for a concrete HyperShift/EaaS example (`/` in JSON Pointer keys is `~1`).

`spec.ocpVersion` (EaaS) selects the HyperShift guest OCP minor. Prefer setting
it when the CSV pins a kube version that older EaaS guests cannot satisfy.

## Step 1: Create the Bundle Manifest

Create `certsuite-test-bundle.yaml` at the root of your bundle directory:

```yaml
apiVersion: certsuite.redhat.com/v1alpha1
kind: TestBundle
metadata:
  name: my-operator-test-bundle
  labels:
    app.kubernetes.io/part-of: my-operator
spec:
  # Leave empty to use the operator's suggested install namespace from the CSV
  namespace: ""

  # OLM OperatorGroup mode for this test (required for correct installs).
  # The CSV lists which modes are *supported*; pick the one certsuite should use.
  # OwnNamespace | SingleNamespace | MultiNamespace | AllNamespaces
  installMode: OwnNamespace

  # Optional (EaaS pipeline): OCP minor version to provision, e.g. "4.22".
  # When set, HyperShift uses this instead of the FBC-derived version.
  # Must appear in the EaaS supported-versions list or the run fails.
  # ocpVersion: "4.22"

  description: |
    Software-only test deployment of my-operator.

  # The pipeline verifies these resources before running certsuite.
  # Deployment, StatefulSet, DaemonSet: rollout readiness (waits for pods).
  # Any other kind: presence check (verifies the resource exists).
  readiness:
    timeout: 300                   # Seconds to wait
    checks:
      - kind: Deployment
        name: my-controller
      - kind: DaemonSet
        name: my-agent
      - kind: MyCustomResource     # Presence check only
        name: test-instance
```

The operator's package name and channel are **not** specified here --
Konflux determines those from the FBC fragment in the Snapshot.

### Supported Check Types

| Kind | Behavior |
|------|----------|
| `Deployment` | Waits for rollout to complete (all pods Ready) |
| `StatefulSet` | Waits for rollout to complete |
| `DaemonSet` | Waits for rollout to complete |
| Any other kind | Verifies the resource exists (namespace-scoped first, then cluster-scoped) |

If no `readiness.checks` are defined, the pipeline auto-discovers all
Deployments in the target namespace and waits for them.

## Step 2: Create Operand Manifests

Place Kubernetes manifests in the `operands/` directory. These are
applied with `oc apply -f operands/` after the operator is installed.

### Custom Resources

If your operator reconciles Custom Resources, create minimal CR
instances that your operator will reconcile. Use test/development
profiles if your operator supports them:

```yaml
# operands/my-app.yaml
apiVersion: myoperator.example.com/v1
kind: MyApp
metadata:
  name: test-instance
spec:
  replicas: 1
  profile: test         # Use a lightweight profile
  storage:
    type: emptyDir      # Avoid PVC requirements
  features:
    hardware-offload: false
    external-auth: false
```

### Direct Workloads

If your operator does not auto-create workloads from CRs, include
explicit Deployment manifests:

```yaml
# operands/workload.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-workload
  labels:
    app: my-workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-workload
  template:
    metadata:
      labels:
        app: my-workload
    spec:
      containers:
        - name: app
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
```

### What to Avoid

| Avoid | Why | Alternative |
|-------|-----|-------------|
| PVCs with specific StorageClasses | May not exist on test cluster | Use `emptyDir` volumes |
| NodeSelectors for specialized hardware | Nodes won't have the hardware | Remove or use `preferredDuringScheduling` |
| External service endpoints | Not available in test env | Use mock services or in-cluster alternatives |
| License/entitlement Secrets | Not shareable | Disable features that require them |

Some operators legitimately require `hostNetwork`, privileged containers,
or other elevated permissions. Certsuite will flag these, but they can be
addressed with exceptions in cert-track-results. Do not change your
operator's actual requirements just to pass validation.

## Step 3: Add Prerequisites (Optional)

If your operands need Secrets, ConfigMaps, or RBAC resources before
they can start, place them in a `prerequisites/` directory:

```yaml
# prerequisites/test-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-operator-test-config
data:
  mode: "test"
  log_level: "debug"
```

These are applied before the operand manifests.

## Step 4: Validate Locally

Use the provided validation tool to check your bundle before pushing:

```bash
# From the konflux-certsuite repository
./tools/validate-test-bundle.sh /path/to/your/test-bundle
```

The tool checks:
- `certsuite-test-bundle.yaml` exists and has required fields
- `operands/` directory exists and contains at least one manifest
- YAML syntax is valid

### Test Against a Local Cluster

For a more thorough local test:

```bash
# 1. Install your operator on a test cluster
# 2. Apply the bundle manifests
oc apply -f my-test-bundle/prerequisites/ 2>/dev/null || true
oc apply -f my-test-bundle/operands/

# 3. Wait for readiness
oc rollout status deployment/my-workload

# 4. Verify the operator reconciled your CRs
oc get <your-cr-kind> -n <namespace>
```

## Step 5: Scaffold with the CLI Tool

To generate a boilerplate test bundle:

```bash
./tools/scaffold-test-bundle.sh \
  --name my-operator \
  --output /path/to/output
```

This creates a complete bundle directory with placeholder manifests
that you can customize.

## Step 6: Onboard to Konflux

### Option A: EaaS (Recommended)

No Secrets or infrastructure to manage. Each run gets a fresh cluster.

1. **Push the test bundle** to your operator's git repository.

2. **Create an IntegrationTestScenario** using the EaaS pipeline.
   See [examples/integration-test-scenario-eaas.yaml](../examples/integration-test-scenario-eaas.yaml).

   The only required parameter is `TEST_BUNDLE_REF`:
   ```yaml
   params:
     - name: TEST_BUNDLE_REF
       value: "https://github.com/org/repo.git#certsuite-test-bundle"
   resolverRef:
     resolver: git
     params:
       - name: url
         value: https://github.com/redhat-best-practices-for-k8s/konflux-certsuite.git
       - name: pathInRepo
         value: pipelines/certsuite-operator-test/0.1/certsuite-operator-test-eaas.yaml
   ```

3. **Merge a change** to your FBC component. The pipeline triggers
   automatically on push events.

### Option B: Shared Cluster

Use when you need a persistent cluster (e.g. hardware tests).

1. **Push the test bundle** to your operator's git repository.

2. **Create Secrets** in your Konflux tenant namespace:

   ```bash
   # Shared cluster kubeconfig
   oc create secret generic shared-cluster-kubeconfig \
     --from-file=kubeconfig=/path/to/kubeconfig \
     -n <tenant-namespace>
   ```

3. **Create an IntegrationTestScenario** using the shared-cluster pipeline.
   See [examples/integration-test-scenario.yaml](../examples/integration-test-scenario.yaml).

   ```yaml
   resolverRef:
     resolver: git
     params:
       - name: pathInRepo
         value: pipelines/certsuite-operator-test/0.1/certsuite-operator-test.yaml
   ```

4. **Merge a change** to your FBC component.

## Example: ptp-operator

The ptp-operator test bundle at
[examples/ptp-operator-test-bundle/](../examples/ptp-operator-test-bundle/)
demonstrates a real-world bundle:

- **PtpOperatorConfig** patches the default config to schedule
  linuxptp-daemon on worker nodes
- **PtpConfig** uses software-only mode (`time_stamping: software`,
  `free_running: 1`) so no PTP-capable NICs are required
- The operator reconciles these CRs and creates the linuxptp-daemon
  DaemonSet, which is enough to verify proper deployment
- **`patches/csv.json`** applies HyperShift-specific CSV tweaks after
  OLM creates the CSV (see below). Optional `spec.ocpVersion` can pin the
  guest minor when EaaS offers it; the PTP example omits it today because
  EaaS tops out at 4.21 while the FBC targets 4.22.

### Why `patches/csv.json` is needed for ptp-operator

EaaS provisions HyperShift **guest** clusters. Those differ from a full
self-managed OpenShift in ways the production PTP CSV does not assume.
The test bundle therefore patches the installed CSV (RFC 6902 JSON Patch
via `oc patch --type=json`) before waiting for `Succeeded`:

| Patch | What it does | Why |
|-------|----------------|-----|
| `remove` `/spec/minKubeVersion` | Drops the CSV kube floor (e.g. `1.35.0`) | OLM refuses install when guest kube is lower (`RequirementsNotMet`). EaaS often maxes out below the FBC target (e.g. supported list ends at 4.21 / kube 1.34 while the 4.22 CSV wants 1.35). Prefer fixing this with `spec.ocpVersion` when EaaS offers that minor; the remove is a safety net when it cannot. |
| `replace` `/spec/install/spec/deployments/0/spec/template/spec/nodeSelector` → `{}` | Clears `node-role.kubernetes.io/master: ""` on the operator Deployment | HyperShift guests typically have **worker** nodes only. A master `nodeSelector` leaves the operator unschedulable. |

These patches belong in the **test bundle**, not in the product CSV:
they are only for certsuite/EaaS validation. Other operators may need
different (or no) patches — add `patches/csv.json` only when the stock
CSV cannot install or schedule on the ephemeral guest.

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| "certsuite-test-bundle.yaml not found" | Wrong `TEST_BUNDLE_REF` path | Check the `#path` fragment in the ref |
| Operands never become Ready | Missing dependencies or bad config | Test locally first (Step 4) |
| EaaS cluster provision timeout | MCE/Hypershift issue | Check Konflux status; retry |
| Lock timeout (shared cluster only) | Another pipeline is running | Increase `LOCK_TIMEOUT` or wait |
| OADP restore fails (shared cluster only) | Backup expired or missing | Recreate the baseline backup |

## Reference

- [Architecture Guide](architecture.md)
- [Certsuite Documentation](https://redhat-best-practices-for-k8s.github.io/certsuite/)
- [Certsuite Configuration](https://redhat-best-practices-for-k8s.github.io/certsuite/configuration/)
- [Certsuite Test Catalog](https://github.com/redhat-best-practices-for-k8s/certsuite/blob/main/CATALOG.md)
