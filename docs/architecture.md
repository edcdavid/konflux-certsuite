# Architecture Guide

This document describes the Konflux Certsuite test pipelines, how
clusters are provisioned or managed, and how results flow to storage.

There are two pipeline variants:
- **EaaS** (recommended) -- ephemeral cluster per run, no infrastructure to manage
- **Shared Cluster** -- persistent cluster with locking and OADP cleanup

For a detailed before/after comparison of the EaaS OLM + mirror redesign,
see [eaas-olm-mirrors-before-after.md](eaas-olm-mirrors-before-after.md).

## EaaS Pipeline (Recommended)

Each run provisions a fresh Hypershift cluster via Konflux EaaS. No
kubeconfig secrets, no locks, no cleanup -- the cluster is destroyed
automatically when the PipelineRun completes.

```mermaid
flowchart TD
    A[parse-metadata] --> B[provision-eaas-space]
    B --> C[get-unreleased-bundle]
    C --> D[pick-cluster-params]
    D --> E[provision-cluster]
    E --> F["deploy-and-test\n(mirrors + OLM + operands + certsuite + optional OCI push)"]
```

| Stage | What it does |
|-------|-------------|
| `provision-eaas-space` | Allocates an EaaS space for cluster provisioning |
| `get-unreleased-bundle` | Extracts the operator bundle from the FBC fragment |
| `pick-cluster-params` | Selects OCP version and architecture from supported list |
| `provision-cluster` | Creates an ephemeral Hypershift AWS cluster |
| `deploy-and-test` | Gets kubeconfig, auto-generates/applies CRI-O registry mirrors from FBC+Snapshot, deploys operator via plain OLM (CatalogSource image + Subscription), deploys operands, runs certsuite, optionally pushes results tarball to OCI (`OCI_REF` + `CREDENTIALS_SECRET_NAME`) |

## Shared Cluster Pipeline

Uses a pre-existing cluster accessed via kubeconfig Secret. Includes
Lease-based queueing and OADP backup/restore for multi-tenant safety.
(Unchanged by the EaaS OLM/mirrors redesign.)

```mermaid
flowchart TD
    A[parse-metadata] --> B[get-unreleased-bundle]
    B --> C[acquire-cluster-lock]
    C --> D[oadp-restore-pre]
    C --> E[deploy-operator]
    E --> F[deploy-operands]
    F --> G[run-certsuite]
    G --> H[collect-results]

    H --> I{finally}

    subgraph finally [Finally Block]
        J[cleanup-operator]
        K[oadp-restore-post]
        L[release-cluster-lock]
        J --> K --> L
    end

    I --> J
```

### Stage Details

| # | Task | Purpose |
|---|------|---------|
| 1 | `parse-metadata` | Extract FBC image, git URL, and revision from the Konflux Snapshot |
| 2 | `get-unreleased-bundle` | Retrieve the unreleased operator bundle from the FBC fragment |
| 3 | `acquire-cluster-lock` | Create a Kubernetes Lease to serialize access to the shared cluster |
| 4 | `oadp-restore-pre` | Restore the cluster to the clean baseline using OADP |
| 5 | `deploy-operator` | Install the operator via OLM (CatalogSource, Subscription, CSV) |
| 6 | `deploy-operands` | Apply the test bundle's operand manifests and wait for readiness |
| 7 | `run-certsuite` | Execute certsuite suites specified by the `CERTSUITE_LABELS` param |
| 8 | `collect-results` | POST claim.json to cert-track-results, push tarball to OCI registry |

## Concurrency: Lease-Based Queueing

Multiple Konflux projects can share the same test cluster. A Kubernetes
Lease in the `certsuite-locks` namespace acts as a mutex:

```mermaid
sequenceDiagram
    participant P1 as PipelineRun A
    participant K8s as Shared Cluster
    participant P2 as PipelineRun B

    P1->>K8s: Create Lease (holder=A)
    K8s-->>P1: Created

    P2->>K8s: Create Lease (holder=B)
    K8s-->>P2: AlreadyExists

    loop Poll every 15s
        P2->>K8s: GET Lease
        K8s-->>P2: holder=A
    end

    P1->>K8s: Delete Lease (finally)
    K8s-->>P1: Deleted

    P2->>K8s: Create Lease (holder=B)
    K8s-->>P2: Created
```

**Stale lock protection**: each Lease carries a `leaseDurationSeconds` (TTL).
If a pipeline crashes without running its `finally` block, the next pipeline
detects the expired lease and deletes it automatically.

## OADP Backup / Restore

The pipeline uses OADP (OpenShift API for Data Protection, built on Velero)
to snapshot and restore cluster state:

```mermaid
flowchart LR
    subgraph baseline [One-Time Setup]
        Clean[Clean Cluster] --> Backup[OADP Backup CR]
    end

    subgraph pretest [Before Each Test]
        RestorePre[OADP Restore CR] --> DeployOp[Deploy Operator]
    end

    subgraph posttest [After Each Test]
        Cleanup[Delete Operator Resources] --> RestorePost[OADP Restore CR]
    end

    Backup -.->|referenced by| RestorePre
    Backup -.->|referenced by| RestorePost
```

**What OADP restores**: namespace-scoped resources (Deployments, Services,
ConfigMaps, Secrets, PVCs) and cluster-scoped resources (CRDs,
ClusterRoles). It does *not* restore etcd or OpenShift platform operators.

**What the cleanup task removes**: the explicit OLM resources (Subscription,
CSV, CatalogSource, OperatorGroup), operator-installed CRDs, and the
install/operand namespaces. OADP restore then handles any remaining drift.

## Registry mirrors (EaaS, auto-generated)

When Konflux quay images are not pullable as `registry.redhat.io@sha256:...`
on HyperShift guests (where IDMS/ITMS/ICP often cannot remap digests), the
**EaaS** pipeline auto-generates digest-only CRI-O mirrors inside
`deploy-and-test` before plain OLM deploy:

1. `opm render` the FBC and collect `registry.redhat.io` images from the
   matched `olm.bundle` (`relatedImages`, CSV, bundle `.image`).
2. Resolve each digest to a quay repo via the full Snapshot
   `components[].containerImage` index when present.
3. Fall back to quay tenant repository lookup (tenant derived from the FBC
   pullspec) plus a public fallback for `kube-rbac-proxy`.
4. Apply a privileged DaemonSet in `certsuite-registry-mirrors` that writes
   `/etc/containers/registries.conf.d` and reloads CRI-O.

No ITS parameter is required. If no RHIO relatedImages are found, the
DaemonSet is skipped. EaaS guests are destroyed after the run, so mirror
cleanup is unnecessary. The shared-cluster pipeline does not use this path.

## Operator Test Bundle

The test bundle is a directory (hosted in a git repo or OCI image) that
operator owners create. It tells the pipeline how to deploy operands in
a software-only mode and verify the operator is properly deployed. The
bundle is **not** responsible for certsuite configuration -- that is
managed separately via the `CERTSUITE_CONFIG_SECRET` pipeline parameter.

```
my-operator-test-bundle/
  certsuite-test-bundle.yaml    # Bundle metadata (namespace, installMode, readiness)
  prerequisites/                # (optional) Secrets, ConfigMaps, namespace labels
    secret.yaml
  patches/                      # (optional) operator-specific CSV JSON Patch
    csv.json                    #   oc patch --type=json --patch-file=…
  operands/                     # Kubernetes manifests for operand instances
    my-custom-resource.yaml
    deployment.yaml
    service.yaml
```

`spec.installMode` tells certsuite which OLM OperatorGroup mode to configure
for the run (`OwnNamespace`, `SingleNamespace`, `MultiNamespace`, or
`AllNamespaces`). That is distinct from the CSV `installModes` list, which
only declares what the operator *supports*.

`spec.ocpVersion` (optional, EaaS only) is the OCP minor version to provision
(e.g. `4.22`). When set, it overrides FBC-based version selection so the guest
matches the operator’s expected Kubernetes level. If omitted, the pipeline
keeps the FBC-derived version (with the usual EaaS supported-list fallback).

The bundle is fetched by the `deploy-operands` task using the
`TEST_BUNDLE_REF` pipeline parameter. By default, the pipeline runs
**all** certsuite tests. Pass `CERTSUITE_LABELS` to run only a subset.

See the [Operator Onboarding Guide](operator-onboarding-guide.md) for
how to create a bundle, and the
[ptp-operator example](../examples/ptp-operator-test-bundle/) for a
real-world reference.

## Results Flow

```mermaid
flowchart TD
    CS[Certsuite Run] --> Claim[claim.json]
    Claim --> API["POST /api/v1/claim"]
    Claim --> OCI[OCI Push]

    subgraph certtrack [cert-track-results]
        API --> Parse[Parse claim.json]
        Parse --> Snapshot[ClaimSnapshot]
        Parse --> Tests[Test Records]
        Snapshot --> Retention[Retention Policy]
        Retention -->|older than 3rd| Strip["Strip configurations + nodes"]
        Retention -->|preserved=true| Keep[Keep Full Data]
    end
```

### Retention Policy

For each `(operator, release)` pair:

1. The **3 newest** ClaimSnapshots retain full debug data (`configurations`
   and `nodes` sections from claim.json).
2. Older snapshots have `configurations` and `nodes` set to NULL to save
   space. Per-test fields (`checkDetails`, `capturedTestOutput`) are always
   kept.
3. Users can mark a snapshot as **preserved** via the cert-track-results UI
   to exempt it from stripping.

## Adding a New Operator

1. Create a [test bundle](#operator-test-bundle) in your operator's
   repository.
2. Validate it locally with `tools/validate-test-bundle.sh`.
3. Create an `IntegrationTestScenario` in your Konflux tenant config.
   See [examples/integration-test-scenario.yaml](../examples/integration-test-scenario.yaml).
4. Ensure the required Secrets exist in your tenant namespace:
   - EaaS: `quay-dockerconfig` (or similar) when using `OCI_REF` /
     `CREDENTIALS_SECRET_NAME` for results push
   - Shared cluster: also `shared-cluster-kubeconfig`, and optionally
     `cert-track-api-token`
5. Merge a change to your FBC component -- the pipeline triggers
   automatically on push events.
