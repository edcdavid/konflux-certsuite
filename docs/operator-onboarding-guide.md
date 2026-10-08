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

The test bundle also includes `certsuite_config.yml`, which tells
certsuite where to find the operator's workloads (namespaces, labels,
CRD filters). By default, the pipeline runs the `common` certsuite
tests unless a different subset is specified via `CERTSUITE_LABELS`.

## Bundle Directory Structure

```
my-operator-test-bundle/
  certsuite-test-bundle.yaml       # Required: bundle metadata
  certsuite_config.yml             # Required: certsuite runtime config
  operands/                        # Required: operand manifests
    my-custom-resource.yaml        #   Your operator's CR instances
    deployment.yaml                #   Any additional workloads
    service.yaml                   #   Services, etc.
  prerequisites/                   # Optional: pre-deploy resources
    pull-secret.yaml               #   Secrets, ConfigMaps, etc.
  csv-patches/                     # Optional: CSV patches (JSON6902 / strategic-merge)
    00-remove-min-kube-version.json
```

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
  # Namespace for operator install AND operand deployment.
  # Package/channel are auto-discovered from the FBC / PackageManifest.
  # Leave empty to fall back to CSV suggested-namespace, then auto-generate.
  namespace: ""

  # OLM install mode. One of: AllNamespaces, OwnNamespace, SingleNamespace.
  # MultiNamespace is not yet supported by the pipeline and will fail at
  # deploy time -- do not use it.
  # Leave empty to auto-detect from CSV supported modes
  # (prefers AllNamespaces, then OwnNamespace).
  installMode: ""

  description: |
    Software-only test deployment of my-operator.

  # Certsuite discovery labels applied after operator install.
  # Omit to use defaults: CSV gets "operator=target", all DaemonSets get
  # "generic=target" on their pod templates.
  discoveryLabels:
    operator: "redhat-best-practices-for-k8s.com/operator=target"
    pod: "redhat-best-practices-for-k8s.com/generic=target"
    resources:
      - kind: Deployment       # Which resource kinds to label

  # Optional: CSV patches applied after OLM creates the CSV and before
  # waiting for Succeeded. Prefer listing paths here; if omitted, the
  # pipeline auto-loads csv-patches/* when that directory exists.
  # csvPatches:
  #   - path: csv-patches/00-remove-min-kube-version.json

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

### Install Configuration

| Field | Values | Default | Description |
|-------|--------|---------|-------------|
| `namespace` | Any string | CSV `suggested-namespace`, then auto-generate `oo-*` | Namespace for both operator install and operand deployment |
| `installMode` | `AllNamespaces`, `OwnNamespace`, `SingleNamespace` | Auto-detect from CSV (prefers AllNamespaces, then OwnNamespace) | Determines the OperatorGroup target namespaces |

> **Note:** `MultiNamespace` is **not yet supported** by the pipeline. Even
> though it's accepted by the CSV's supported install modes, setting it as
> your bundle's `installMode` will make the pipeline fail at deploy time
> with `installMode=MultiNamespace is not yet supported`. If your operator
> only supports `MultiNamespace`, contact the certsuite pipeline maintainers
> before onboarding.

### Discovery Labels

The pipeline applies discovery labels so certsuite can find the operator
CSV and its workload pods. You can customize which labels and which
resource types get labeled:

| Field | Default | Description |
|-------|---------|-------------|
| `discoveryLabels.operator` | `redhat-best-practices-for-k8s.com/operator=target` | Label applied to the installed CSV |
| `discoveryLabels.pod` | `redhat-best-practices-for-k8s.com/generic=target` | Label applied to workload pod templates |
| `discoveryLabels.resources[].kind` | `DaemonSet` | Resource types to label (`Deployment`, `DaemonSet`, `StatefulSet`) |

If your operator's workloads are Deployments (not DaemonSets), set
`resources` to `[{kind: Deployment}]`. For operators with both, list
both kinds.

### Optional CSV patches

Any install-time CSV tweaks (for example HyperShift constraints such as
removing `minKubeVersion` or a master `nodeSelector`) belong in the test
bundle — not in the shared pipeline.

Supported patch forms:

| Form | Detection | Application |
|------|-----------|-------------|
| JSON6902 | `.json` array, or YAML list of `{op,path,...}` | Applied locally, then `oc replace` |
| Strategic merge | YAML/JSON object | `oc patch --local --type=strategic` |

See [examples/ptp-operator-test-bundle/csv-patches/](../examples/ptp-operator-test-bundle/csv-patches/)
for the PTP HyperShift reference patches.

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

## Step 3: Create `certsuite_config.yml`

This file is **required** in the test bundle. It tells certsuite where to
find your operator's workloads at runtime:

```yaml
# certsuite_config.yml
targetNameSpaces:
  - name: my-operator-ns        # Must match spec.namespace in the bundle manifest

podsUnderTestLabels:
  - "redhat-best-practices-for-k8s.com/generic: target"

operatorsUnderTestLabels:
  - "redhat-best-practices-for-k8s.com/operator: target"

# CRD filters -- list your operator's CRD suffixes
targetCrdFilters:
  - nameSuffix: "myoperator.example.com"
    scalable: false
```

| Field | Description |
|-------|-------------|
| `targetNameSpaces` | Namespaces where certsuite looks for workloads. Must match the install namespace. |
| `podsUnderTestLabels` | Labels identifying pods to test. Must match `discoveryLabels.pod` in the bundle manifest. |
| `operatorsUnderTestLabels` | Labels identifying the operator CSV. Must match `discoveryLabels.operator`. |
| `targetCrdFilters` | CRD name suffixes owned by your operator (for CRD-related tests). |

See [Certsuite Configuration](https://redhat-best-practices-for-k8s.github.io/certsuite/configuration/)
for all available fields.

## Step 4: Add Prerequisites (Optional)

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

## Step 5: Validate Locally

Use the provided validation tool to check your bundle before pushing:

```bash
# From the konflux-certsuite repository
./tools/validate-test-bundle.sh /path/to/your/test-bundle
```

The tool checks:
- `certsuite-test-bundle.yaml` exists and has required fields
- `certsuite_config.yml` exists
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

## Step 6: Scaffold with the CLI Tool

To generate a boilerplate test bundle:

```bash
./tools/scaffold-test-bundle.sh \
  --name my-operator \
  --namespace my-operator-ns \
  --workload-kind Deployment \
  --output /path/to/your-operator-repo/certsuite-test-bundle
```

This creates a complete bundle directory (including `certsuite_config.yml`)
with placeholder manifests that you can customize.

## Step 7: Onboard to Konflux

### Option A: EaaS (Recommended)

No kubeconfig, locks, or OADP to manage. Each run gets a fresh cluster.
OCI results push is optional and needs a registry Secret only if you enable it.

1. **Push the test bundle** to your operator's git repository.

2. **(Optional) Create a registry pull secret.** Only needed if your
   tenant's ServiceAccount (`konflux-integration-runner`) doesn't already
   have credentials linked for `registry.redhat.io`. Most setups already
   have SA-linked credentials, so you can skip this step. If needed:

   ```bash
   oc create secret docker-registry my-redhat-pull-secret \
     --docker-server=registry.redhat.io \
     --docker-username=<user> \
     --docker-password=<token> \
     -n <tenant-namespace>
   ```
   Then add `REGISTRY_PULL_SECRET: "my-redhat-pull-secret"` to your ITS params.

3. **Create an IntegrationTestScenario.** Three ways:
   - **Konflux UI** — go to your Application → Integration tests → Add
   - **CLI** — `oc apply -f integration-test-scenario-eaas.yaml -n <tenant-namespace>`
   - **GitOps** — add the YAML to your tenants-config repository

   See [examples/integration-test-scenario-eaas.yaml](../examples/integration-test-scenario-eaas.yaml).

   Typical parameters for unreleased operators:
   ```yaml
   params:
     - name: TEST_BUNDLE_REF
       value: "https://github.com/org/repo.git@branch#certsuite-test-bundle"
     # Auto-discovered from TEST_BUNDLE_REF repo when empty; set explicitly
     # only if the mirror-set file is in a different repo or path.
     - name: IMAGES_MIRROR_SET_REF
       value: "https://github.com/org/repo.git@branch#.tekton/images-mirror-set.yaml"
     - name: OCI_PUSH_SECRET
       value: "my-component-push-secret"
   resolverRef:
     resolver: git
     params:
       - name: url
         value: https://github.com/redhat-best-practices-for-k8s/konflux-certsuite.git
       - name: revision
         value: main
       - name: pathInRepo
         value: pipelines/certsuite-operator-test/0.1/certsuite-operator-test-eaas.yaml
   ```

4. **(Optional) Configure OCI results storage.** By default, results can be
   pushed to the component Quay repo with `OCI_PUSH_SECRET`. To use a
   dedicated external registry instead:

   ```bash
   oc create secret docker-registry certsuite-results-push-secret \
     --docker-server=<registry-host> \
     --docker-username=<username> \
     --docker-password=<token-or-password> \
     -n <tenant-namespace>
   ```

   ```yaml
   params:
     - name: TEST_BUNDLE_REF
       value: "https://github.com/org/repo.git#certsuite-test-bundle"
     - name: OCI_RESULTS_REPO
       value: "quay.io/<org>/certsuite-results"   # bare repo, no tag/digest
     - name: OCI_RESULTS_SECRET
       value: "certsuite-results-push-secret"
     # ocp-release / ocp-version-actual are derived at runtime from the FBC
     # fragment and the provisioned EaaS cluster; do not pass OCP_RELEASE.
   ```

   See [OCI Results Storage](../pipelines/certsuite-operator-test/0.1/README.md#oci-results-storage)
   for tag formats, validation rules, and download instructions.

5. **Merge a change** to your FBC component. The pipeline triggers
   automatically whenever Konflux creates a new Snapshot for the component
   named in the ITS `contexts` field (typically on push to the FBC repo).

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

## Image Mirroring for Unreleased Operators

Unreleased operators publish images to internal registries (e.g.
`registry-proxy.engineering.redhat.com`) that are not reachable from the
EaaS cluster. The pipeline handles this transparently using
`images-mirror-set.yaml`:

1. Place `.tekton/images-mirror-set.yaml` in the same git repository and
   branch referenced by `TEST_BUNDLE_REF`.
2. The pipeline auto-discovers the file and converts it to Hypershift
   `imageContentSources` at cluster-provision time, mapping internal
   registry paths to their external mirror.

Example file (`.tekton/images-mirror-set.yaml`):
```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: my-operator-mirrors
spec:
  imageDigestMirrors:
    - source: registry-proxy.engineering.redhat.com/rh-osbs/my-operator
      mirrors:
        - brew.registry.redhat.io/rh-osbs/my-operator
```

If the mirror set lives in a **different** repo from the test bundle, use
the `IMAGES_MIRROR_SET_REF` parameter to point to it explicitly.

## Test Labels (CERTSUITE_LABELS)

By default the pipeline runs the `common` test suite. Use the
`CERTSUITE_LABELS` parameter to select different test categories:

> **Warning:** Never set `CERTSUITE_LABELS` to an empty string (`""`) for
> the EaaS pipeline. Unlike some other certsuite integrations, the EaaS
> pipeline passes an empty value straight through to `certsuite run
> --label-filter ""`, which puts certsuite into **diagnostic mode and
> launches zero test cases** -- silently, with no pipeline failure. Simply
> omit the parameter (or leave it unset) to use the `common` default.

| Label | Description |
|-------|-------------|
| `common` | Default subset of non-intrusive best-practice checks |
| `access-control` | RBAC, security context, capabilities |
| `affiliated-certification` | Helm chart and operator certification status |
| `lifecycle` | Deployment scaling, pod recreation, graceful shutdown |
| `networking` | Network policies, dual-stack, multus |
| `observability` | Logging, termination messages |
| `operator` | OLM install modes, CSV conditions |
| `performance` | Resource limits, scheduling |
| `platform-alteration` | Platform integrity checks |
| `manageability` | Container port naming |
| `preflight` | Container image compliance |
| `all` | Run everything |

Multiple labels: `"networking,lifecycle"` runs both suites.

Expressions: `"access-control && !access-control-sys-admin-capability"` excludes
specific checks.

Full catalog: [CATALOG.md](https://github.com/redhat-best-practices-for-k8s/certsuite/blob/main/CATALOG.md)

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

## Example: lifecycle-agent

The lifecycle-agent test bundle at
[examples/lifecycle-agent-test-bundle/](../examples/lifecycle-agent-test-bundle/)
covers a Deployment-based operator:

- Installs into `openshift-lifecycle-agent` (`OwnNamespace`)
- Package/channel come from the FBC / PackageManifest (not the TestBundle)
- Applies an **ImageBasedUpgrade** CR left in `Idle` so the controller
  reconciles without seed generation or an image-based upgrade
- Does **not** deploy `SeedGenerator` (that would attempt host seed work)

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| "certsuite-test-bundle.yaml not found" | Wrong `TEST_BUNDLE_REF` path | Check the `#path` fragment in the ref |
| "certsuite_config.yml not found" | Missing config in test bundle | Add `certsuite_config.yml` to the bundle root (see Step 3) |
| `get-unreleased-bundle` auth error | Missing or wrong pull secret | Create a `dockerconfigjson` Secret for `registry.redhat.io` and set `REGISTRY_PULL_SECRET` |
| ImagePullBackOff in EaaS cluster | Unreleased images not mirrored | Add `.tekton/images-mirror-set.yaml` (see Image Mirroring section) |
| Operands never become Ready | Missing dependencies or bad config | Test locally first (Step 5: Validate Locally) |
| EaaS cluster provision timeout | MCE/Hypershift issue | Check Konflux status; retry |
| Lock timeout (shared cluster only) | Another pipeline is running | Increase `LOCK_TIMEOUT` or wait |
| OADP restore fails (shared cluster only) | Backup expired or missing | Recreate the baseline backup |

## Reference

- [Architecture Guide](architecture.md)
- [Certsuite Documentation](https://redhat-best-practices-for-k8s.github.io/certsuite/)
- [Certsuite Configuration](https://redhat-best-practices-for-k8s.github.io/certsuite/configuration/)
- [Certsuite Test Catalog](https://github.com/redhat-best-practices-for-k8s/certsuite/blob/main/CATALOG.md)
