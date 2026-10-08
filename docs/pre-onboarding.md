# Pre-Onboarding: Local Validation Against Guest Clusters

Use `scripts/pre-onboarding.sh` to validate an operator certsuite test bundle
against real guest clusters **before** onboarding to the Konflux pipeline.

The script leases a HyperShift (HCP) guest, installs the operator from an ART
staging FBC, deploys operands, optionally runs certsuite, releases the lease,
then repeats on a CRC (single-node) guest.

## Prerequisites

### Local tools

- `oc`, `opm`, `yq` (mikefarah), `jq`, `python3`, `curl`, `tar`
- `docker` or `podman` (FBC `/configs` extraction; also certsuite)
- `skopeo` (recommended for fast FBC image pull checks)

OLM package/channel are auto-discovered (not set in the TestBundle):

1. `opm render` of the FBC (when available)
2. Guest `PackageManifest` after the CatalogSource is READY
3. `--package-name` / `--channel-name` (optional CLI overrides only)

### Management cluster

- A kubeconfig with access to a cluster running the
  [guestcluster](https://github.com/opdev/guestcluster) operator
- A source namespace labeled `guestcluster.opdev.io/enabled: "true"`
- Two dedicated pools in that namespace:
  - a `crc` `ClusterPool` (e.g. `crc-pool`)
  - an `hcp` `ClusterPool` (e.g. `hcp-pool`)
- A `pull-secret` Secret in the source namespace (or
  `template.pullSecretRef` on the pools) so instances can provision

> **Note:** On clusters that also install Hive, prefer the fully-qualified
> resource names (`clusterpools.guestcluster.opdev.io`,
> `clusterleases.guestcluster.opdev.io`). The script always uses these.

### Staging registry credentials

ART FBC catalogs reference images as `registry.redhat.io/...@sha256:...` that
actually live on `registry.stage.redhat.io` for pre-GA content. You need a
[Stage Registry Service Account](https://access.stage.redhat.com/terms-based-registry/)
token (JWT).

Pass either:

- `--staging-token <JWT>` (optional `--stage-user`, default `20430001|certsuite`), or
- `--staging-pull-secret <path>` to a dockerconfigjson that already contains
  `registry.stage.redhat.io` auth

### FBC image

Resolve an ART FBC pullspec (example with [test-art](https://github.com/)):

```bash
cd /path/to/test-art
./install-art-operator.py install ptp-operator -r 4.22 --dry-run
```

Example pullspec:

```text
quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:ocp__4.22__ose-ptp-rhel9-operator
```

Match the FBC OCP minor version to your guest pool where possible. The sample
PTP bundle includes CSV patches that relax `minKubeVersion` / master
nodeSelectors for older HyperShift guests.

### FBC pullability check (fail-fast)

Before leasing any guest, the script validates that images needed to install
from the FBC are pullable with stage credentials:

1. Collect refs via `opm render` and/or by extracting `/configs` from the FBC
   catalog image.
2. By default, only the **selected channel head** bundle (plus relatedImages /
   CSV images) is checked. Pass `--fbc-validate-all` to check every historical
   digest in the fragment.
3. Rewrite `registry.redhat.io/...` → `registry.stage.redhat.io/...`.
4. `skopeo inspect` each digest (falls back to `docker`/`podman` pull).

If any digest returns **manifest unknown** (common when stage lags ART), the
script exits before creating leases. Resolve a fresher FBC tag or wait for
stage publication. Use `--skip-fbc-validate` only for debugging.

## Workflow

```text
local: validate FBC image digests on registry.stage.redhat.io
mgmt: create ClusterLease (hcp) → Bound + kubeconfig
  guest: stage mirror (HostedCluster ICS + pull-secret on mgmt)
  guest: CatalogSource / Subscription / CSV / operands / readiness [/ certsuite]
mgmt: delete ClusterLease (release HCP)
mgmt: create ClusterLease (crc) → Bound + kubeconfig
  guest: ImageDigestMirrorSet + pull-secret
  guest: install / deploy / readiness [/ certsuite]
mgmt: delete ClusterLease (release CRC)
```

### Stage mirroring by topology

| Topology | How stage registry is wired |
|----------|-----------------------------|
| **CRC** | Guest-scoped `ImageDigestMirrorSet` + patch guest `openshift-config/pull-secret` |
| **HCP** | Patch `HostedCluster.spec.imageContentSources` and the HostedCluster pull Secret on the **management** cluster (guest IDMS is admission-blocked) + patch guest pull-secret |

Both topologies also create a `staging-pull-secret` in the operator install
namespace and attach it to the operator ServiceAccount.

The FBC `CatalogSource` is created in `openshift-marketplace` (same as test-art)
so the large catalog registry pod is not scheduled into the operator namespace.
HCP workers need enough memory (recommend ≥16Gi) for the FBC image (~800Mi).

## Usage

```bash
./scripts/pre-onboarding.sh \
  --source-namespace pre-onboarding \
  --crc-pool crc-pool \
  --hcp-pool hcp-pool \
  --kubeconfig "${MGMT_KUBECONFIG}" \
  --fbc-url quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:ocp__4.22__ose-ptp-rhel9-operator \
  --staging-token "$(cat /path/to/stage-jwt.txt)" \
  --test-bundle-path examples/ptp-operator-test-bundle \
  --no-certsuite

# Lifecycle Agent example (Idle ImageBasedUpgrade, no seed generation):
#   --test-bundle-path examples/lifecycle-agent-test-bundle
```

### Common flags

| Flag | Purpose |
|------|---------|
| `--test-bundle-path` | Local bundle dir (skips git download; useful while debugging) |
| `--test-bundle-url` | `https://github.com/org/repo.git@branch#path/to/bundle` |
| `--no-certsuite` | Install + deploy + readiness only |
| `--package-name` / `--channel-name` | Optional overrides; default is FBC / PackageManifest discovery |
| `--cleanup false` | Keep leases / resources after the run (debug) |
| `--lease-timeout` | Seconds to wait for lease `Bound` (default `1200`) |
| `--skip-fbc-validate` | Skip stage pull checks for FBC-referenced images |
| `--fbc-validate-all` | Check every digest in the FBC (not just channel head) |

### Exit codes

- Non-zero: bad args, bundle validation failure, lease/deploy/readiness hard failures, missing `claim.json`
- Zero even if certsuite reports failed tests (failures are printed; mirrors pipeline `onError: continue`)

Results are copied to `pre-onboarding-results-<timestamp>/` under the repo root.

After each lease becomes Bound, the guest kubeconfig is also written to
`config.test` at the repo root (overwritten per topology) for local `oc`
testing (`export KUBECONFIG=$PWD/config.test`).

## Troubleshooting

### Lease never becomes Bound

- Confirm the pool has a Ready spare:  
  `oc get clusterinstances.guestcluster.opdev.io -n <ns>`
- CRC provisioning can take 15–25 minutes (golden image clone + VM + crc-agent).
- HCP needs a Ready HostedCluster **and** NodePool workers.

### Hive CRD collision

`oc get clusterpool` may show Hive pools. Always use:

```bash
oc get clusterpools.guestcluster.opdev.io -n pre-onboarding
oc get clusterleases.guestcluster.opdev.io -n pre-onboarding
```

### ImagePullBackOff on bundle/operand images

- First re-run without `--skip-fbc-validate` — the local check should catch
  missing stage digests before leasing
- CRC: verify `ImageDigestMirrorSet/konflux-certsuite-stage-idms` exists on the guest
- HCP: verify HostedCluster `spec.imageContentSources` includes stage, and the
  HostedCluster pull Secret has `registry.stage.redhat.io` auth
- Confirm `--staging-token` / dockerconfigjson is valid (`skopeo login
  registry.stage.redhat.io`)
- If validation fails with `manifest unknown`, pick another FBC tag:
  `./install-art-operator.py list --live` then `install ptp-operator -r <ver> --dry-run`

### Subscription has no CSV

- Check CatalogSource connection state and PackageManifest
- Confirm the FBC exposes a PackageManifest (or pass `--package-name` / `--channel-name`)
- Inspect InstallPlan / bundle unpack pods for pull errors

### Cleanup

With `--cleanup true` (default), the script deletes ClusterLeases (releasing
guest instances) and best-effort deletes guest IDMS / secrets / namespaces it
created. Use `--cleanup false` to inspect a failed guest.
