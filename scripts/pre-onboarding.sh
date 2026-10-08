#!/usr/bin/env bash
set -euo pipefail

# Line-buffer logs when stdout is redirected (nohup/tee), so progress survives crashes.
if [[ -z "${STDBUF_DONE:-}" ]] && [[ ! -t 1 ]] && command -v stdbuf >/dev/null 2>&1; then
  export STDBUF_DONE=1
  exec stdbuf -oL -eL "$0" "$@"
fi

# Pre-onboarding orchestration script.
#
# Validates, installs, deploys, and optionally tests a certsuite test bundle
# against guest clusters leased via the guestcluster operator (HCP first, then
# CRC). Each topology uses its own ClusterPool in a source namespace.
#
# Required local tools: oc, opm, yq, jq, python3, curl, tar, and docker|podman.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Fully-qualified guestcluster CRDs (bare "clusterpool" collides with Hive).
CPOOL="clusterpools.guestcluster.opdev.io"
CLEASE="clusterleases.guestcluster.opdev.io"
CINST="clusterinstances.guestcluster.opdev.io"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validate, install, deploy, and test a certsuite test bundle against guest
clusters (HyperShift then CRC) leased via the guestcluster operator, before
onboarding to the Konflux pipeline.

Required inputs:
  --crc-pool NAME             Dedicated crc-topology ClusterPool
  --hcp-pool NAME             Dedicated hcp-topology ClusterPool
  --kubeconfig PATH           Management cluster kubeconfig
  --fbc-url IMAGE             ART-built FBC fragment image (CatalogSource img)
  --test-bundle-url URL       Git URL: url@branch#path
     OR
  --test-bundle-path PATH     Local test-bundle directory (skips download)

Staging credentials (one required):
  --staging-token TOKEN       JWT for registry.stage.redhat.io
  --staging-pull-secret PATH  dockerconfigjson file with stage registry auth

Optional inputs:
  --source-namespace NAME     Namespace of the ClusterPools (default: current context ns)
  --stage-user USER           Stage registry username (default: 20430001|certsuite)
  --package-name NAME         OLM package override (optional; prefer
                              TestBundle spec.packageName, else FBC/catalog)
  --channel-name NAME         OLM channel override (optional; prefer
                              TestBundle spec.channelName, else FBC/catalog)
  --no-certsuite              Skip certsuite (install + deploy + readiness only)
  --certsuite-labels LIST     Comma-separated labels (default: common)
  --certsuite-image IMAGE     Default: quay.io/redhat-best-practices-for-k8s/certsuite:latest
  --container-runtime RT      docker|podman (default: docker)
  --validate-platform PLAT    Platform for FBC/bundle validation pulls
                              (default: linux/amd64; ignores host arch)
  --certsuite-config PATH     Override config path (default: <bundle>/certsuite_config.yml)
  --readiness-timeout SEC     Per-rollout timeout, seconds (default: 300)
  --lease-timeout SEC         Wait for lease Bound (default: 1200)
  --cleanup true|false        Delete leases and script-created resources (default: true)
  --skip-fbc-validate         Skip FBC image pullability checks (not recommended)
  --fbc-validate-all          Check every digest in the FBC (default: selected
                              channel head + related images only)
  -h, --help                  Show this message.

Exit code: non-zero only on hard failures. certsuite test failures are reported
but do not by themselves fail the script.
EOF
}

# Log helpers write to stderr so command substitutions stay clean.
pass() { echo "[$(date -u +%FT%T.%3NZ)] PASS: $1" >&2; }
fail() { echo "[$(date -u +%FT%T.%3NZ)] FAIL: $1" >&2; }
warn() { echo "[$(date -u +%FT%T.%3NZ)] WARN: $1" >&2; }
info() { echo "[$(date -u +%FT%T.%3NZ)] $1" >&2; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    fail "required tool '$1' not found in PATH"
    exit 2
  fi
}

# ── Defaults / flags ───────────────────────────────────────────────────────
CRC_POOL=""
HCP_POOL=""
KUBECONFIG_PATH=""
FBC_URL=""
STAGING_PULL_SECRET=""
STAGING_TOKEN=""
STAGE_USER="20430001|certsuite"
TEST_BUNDLE_URL=""
TEST_BUNDLE_PATH=""
SOURCE_NAMESPACE=""
PACKAGE_NAME_OVERRIDE=""
CHANNEL_NAME_OVERRIDE=""
NO_CERTSUITE=0
CERTSUITE_LABELS="common"
CERTSUITE_IMAGE="quay.io/redhat-best-practices-for-k8s/certsuite:latest"
CONTAINER_RUNTIME="docker"
# FBC/operator indexes are typically amd64-only. Validation must not select the
# host arch (e.g. arm64 on Apple Silicon) from a multi-arch manifest list.
VALIDATE_PLATFORM="linux/amd64"
VALIDATE_ARCH="amd64"
VALIDATE_OS="linux"
CERTSUITE_CONFIG=""
READINESS_TIMEOUT=300
LEASE_TIMEOUT=1200
CLEANUP=true
SKIP_FBC_VALIDATE=0
FBC_VALIDATE_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --crc-pool)             CRC_POOL="${2:-}"; shift 2 ;;
    --hcp-pool)             HCP_POOL="${2:-}"; shift 2 ;;
    --kubeconfig)           KUBECONFIG_PATH="${2:-}"; shift 2 ;;
    --fbc-url)              FBC_URL="${2:-}"; shift 2 ;;
    --staging-pull-secret)  STAGING_PULL_SECRET="${2:-}"; shift 2 ;;
    --staging-token)        STAGING_TOKEN="${2:-}"; shift 2 ;;
    --stage-user)           STAGE_USER="${2:-}"; shift 2 ;;
    --test-bundle-url)      TEST_BUNDLE_URL="${2:-}"; shift 2 ;;
    --test-bundle-path)     TEST_BUNDLE_PATH="${2:-}"; shift 2 ;;
    --source-namespace)     SOURCE_NAMESPACE="${2:-}"; shift 2 ;;
    --package-name)         PACKAGE_NAME_OVERRIDE="${2:-}"; shift 2 ;;
    --channel-name)         CHANNEL_NAME_OVERRIDE="${2:-}"; shift 2 ;;
    --no-certsuite)         NO_CERTSUITE=1; shift ;;
    --certsuite-labels)     CERTSUITE_LABELS="${2:-}"; shift 2 ;;
    --certsuite-image)      CERTSUITE_IMAGE="${2:-}"; shift 2 ;;
    --container-runtime)    CONTAINER_RUNTIME="${2:-}"; shift 2 ;;
    --validate-platform)    VALIDATE_PLATFORM="${2:-}"; shift 2 ;;
    --certsuite-config)     CERTSUITE_CONFIG="${2:-}"; shift 2 ;;
    --readiness-timeout)    READINESS_TIMEOUT="${2:-}"; shift 2 ;;
    --lease-timeout)        LEASE_TIMEOUT="${2:-}"; shift 2 ;;
    --cleanup)              CLEANUP="${2:-}"; shift 2 ;;
    --skip-fbc-validate)    SKIP_FBC_VALIDATE=1; shift ;;
    --fbc-validate-all)     FBC_VALIDATE_ALL=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) fail "unknown option: $1"; usage; exit 2 ;;
  esac
done

MISSING=()
[[ -n "${CRC_POOL}" ]]        || MISSING+=("--crc-pool")
[[ -n "${HCP_POOL}" ]]        || MISSING+=("--hcp-pool")
[[ -n "${KUBECONFIG_PATH}" ]] || MISSING+=("--kubeconfig")
[[ -n "${FBC_URL}" ]]         || MISSING+=("--fbc-url")
if [[ -z "${TEST_BUNDLE_URL}" && -z "${TEST_BUNDLE_PATH}" ]]; then
  MISSING+=("--test-bundle-url|--test-bundle-path")
fi
if [[ -z "${STAGING_TOKEN}" && -z "${STAGING_PULL_SECRET}" ]]; then
  MISSING+=("--staging-token|--staging-pull-secret")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  fail "missing required input(s): ${MISSING[*]}"
  usage >&2
  exit 2
fi

case "${CONTAINER_RUNTIME}" in
  docker|podman) ;;
  *) fail "invalid --container-runtime '${CONTAINER_RUNTIME}' (expected docker|podman)"; exit 2 ;;
esac

# Derive arch/os from --validate-platform (e.g. linux/amd64 → amd64 / linux).
if [[ "${VALIDATE_PLATFORM}" == */* ]]; then
  VALIDATE_OS="${VALIDATE_PLATFORM%%/*}"
  VALIDATE_ARCH="${VALIDATE_PLATFORM#*/}"
  VALIDATE_ARCH="${VALIDATE_ARCH%%/*}"  # drop variant if present (linux/arm64/v8)
fi
# Help opm / docker / podman prefer the validation platform over the host arch.
export DOCKER_DEFAULT_PLATFORM="${DOCKER_DEFAULT_PLATFORM:-${VALIDATE_PLATFORM}}"

# Pull / create with an explicit platform so multi-arch indexes do not fail on
# arm64 hosts when only amd64 is published.
container_pull() {
  local img="${1:?}"
  "${CONTAINER_RUNTIME}" pull --platform "${VALIDATE_PLATFORM}" "${img}"
}

container_create() {
  local name="${1:?}" img="${2:?}"
  "${CONTAINER_RUNTIME}" create --platform "${VALIDATE_PLATFORM}" --name "${name}" "${img}"
}

# skopeo inspect forced to the validation arch (raw first, then full).
skopeo_inspect_validate() {
  local img="${1:?}"
  skopeo inspect \
    --override-arch "${VALIDATE_ARCH}" \
    --override-os "${VALIDATE_OS}" \
    --authfile "${STAGING_DOCKERCONFIG}" \
    --raw "docker://${img}" >/dev/null 2>&1 \
  || skopeo inspect \
    --override-arch "${VALIDATE_ARCH}" \
    --override-os "${VALIDATE_OS}" \
    --authfile "${STAGING_DOCKERCONFIG}" \
    "docker://${img}" >/dev/null 2>&1
}

for tool in oc opm yq jq python3 curl tar; do require_cmd "${tool}"; done
# Container runtime needed for certsuite and/or FBC /configs extraction.
if [[ "${NO_CERTSUITE}" -eq 0 || "${SKIP_FBC_VALIDATE}" -eq 0 ]]; then
  if [[ "${CONTAINER_RUNTIME}" == "docker" ]]; then require_cmd docker; else require_cmd podman; fi
fi

# ── Work area ───────────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
RESULTS_DIR="${WORKDIR}/results"
BUNDLE_DIR="${WORKDIR}/test-bundle"
STAGING_DOCKERCONFIG="${WORKDIR}/staging-dockerconfig.json"
mkdir -p "${RESULTS_DIR}" "${BUNDLE_DIR}"

# Track resources for cleanup. Format: kind|name|namespace|kubeconfig|scope
# scope: mgmt | guest
CLEANUP_ITEMS=()
ACTIVE_LEASES=()          # "name|namespace"
GUEST_KUBECONFIGS=()      # topology=path
MGMT_KUBECONFIG=""
CURRENT_GUEST_KUBECONFIG=""
CURRENT_TOPOLOGY=""
CURRENT_INSTALL_NS=""

register_cleanup() {
  CLEANUP_ITEMS+=("$1")
}

with_mgmt_kubeconfig() {
  local saved="${KUBECONFIG:-}"
  export KUBECONFIG="${MGMT_KUBECONFIG}"
  "$@"
  local rc=$?
  export KUBECONFIG="${saved}"
  return "${rc}"
}

cleanup() {
  [[ "${CLEANUP}" == "true" ]] || { info "Cleanup disabled (--cleanup false)"; return 0; }
  info "Running cleanup..."

  # Always restore mgmt kubeconfig for lease deletes.
  export KUBECONFIG="${MGMT_KUBECONFIG}"

  local entry lease_name lease_ns
  for entry in "${ACTIVE_LEASES[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    lease_name="${entry%%|*}"
    lease_ns="${entry#*|}"
    info "Deleting ClusterLease ${lease_name} in ${lease_ns} (releases guest cluster)"
    oc delete "${CLEASE}" "${lease_name}" -n "${lease_ns}" --ignore-not-found=true --wait=false 2>/dev/null || true
  done

  # Best-effort guest-side cleanup using recorded guest kubeconfigs.
  local gk topo_path topo gkc item kind name ns kcfg scope
  for topo_path in "${GUEST_KUBECONFIGS[@]:-}"; do
    [[ -z "${topo_path}" ]] && continue
    topo="${topo_path%%=*}"
    gkc="${topo_path#*=}"
    [[ -f "${gkc}" ]] || continue
    export KUBECONFIG="${gkc}"
    if ! oc whoami &>/dev/null; then
      warn "guest ${topo} unreachable; skipping guest cleanup"
      continue
    fi
    if [[ "${topo}" == "crc" ]]; then
      oc delete imagedigestmirrorset konflux-certsuite-stage-idms --ignore-not-found=true 2>/dev/null || true
    fi
  done

  export KUBECONFIG="${MGMT_KUBECONFIG}"
  for item in "${CLEANUP_ITEMS[@]:-}"; do
    [[ -z "${item}" ]] && continue
    IFS='|' read -r kind name ns kcfg scope <<< "${item}"
    info "Cleanup: ${kind}/${name} (ns=${ns:-cluster} scope=${scope})"
    if [[ "${scope}" == "guest" && -n "${kcfg}" && -f "${kcfg}" ]]; then
      export KUBECONFIG="${kcfg}"
    else
      export KUBECONFIG="${MGMT_KUBECONFIG}"
    fi
    if [[ -n "${ns}" ]]; then
      oc delete "${kind}" "${name}" -n "${ns}" --ignore-not-found=true --wait=false 2>/dev/null || true
    else
      oc delete "${kind}" "${name}" --ignore-not-found=true --wait=false 2>/dev/null || true
    fi
  done

  export KUBECONFIG="${MGMT_KUBECONFIG}"
  rm -rf "${WORKDIR}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Staging dockerconfigjson ────────────────────────────────────────────────
build_staging_dockerconfig() {
  if [[ -n "${STAGING_PULL_SECRET}" ]]; then
    [[ -f "${STAGING_PULL_SECRET}" ]] || { fail "--staging-pull-secret not found: ${STAGING_PULL_SECRET}"; exit 2; }
    cp "${STAGING_PULL_SECRET}" "${STAGING_DOCKERCONFIG}"
    # Ensure stage registry key exists when a token was also provided.
    if [[ -n "${STAGING_TOKEN}" ]]; then
      python3 - "${STAGING_DOCKERCONFIG}" "${STAGE_USER}" "${STAGING_TOKEN}" <<'PY'
import json, sys, base64
path, user, token = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
data.setdefault("auths", {})["registry.stage.redhat.io"] = {
    "auth": auth,
    "email": "serviceaccount@redhat.com",
}
with open(path, "w") as f:
    json.dump(data, f)
PY
    fi
    return
  fi

  python3 - "${STAGING_DOCKERCONFIG}" "${STAGE_USER}" "${STAGING_TOKEN}" <<'PY'
import json, sys, base64
path, user, token = sys.argv[1], sys.argv[2], sys.argv[3]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
data = {
    "auths": {
        "registry.stage.redhat.io": {
            "auth": auth,
            "email": "serviceaccount@redhat.com",
        }
    }
}
with open(path, "w") as f:
    json.dump(data, f)
PY
}

# ── Bundle download / local path ────────────────────────────────────────────
source "${SCRIPT_DIR}/parse-git-ref.sh"

download_ref() {
  local tmp archive
  tmp="$(mktemp -d)"
  archive="${tmp}/repo.tar.gz"
  if ! curl --retry 3 --retry-delay 2 -fsSL \
    "${GIT_URL}/archive/${GIT_REF}.tar.gz" -o "${archive}"; then
    fail "failed to download ${GIT_URL}/archive/${GIT_REF}.tar.gz"
    rm -rf "${tmp}"; exit 1
  fi
  if ! tar xz -C "${tmp}" --strip-components=1 -f "${archive}"; then
    fail "invalid git archive from ${GIT_URL}@${GIT_REF}"
    rm -rf "${tmp}"; exit 1
  fi
  rm -f "${archive}"
  echo "${tmp}"
}

prepare_bundle() {
  if [[ -n "${TEST_BUNDLE_PATH}" ]]; then
    [[ -d "${TEST_BUNDLE_PATH}" ]] || { fail "--test-bundle-path not a directory: ${TEST_BUNDLE_PATH}"; exit 2; }
    cp -a "${TEST_BUNDLE_PATH}/." "${BUNDLE_DIR}/"
    info "Using local test bundle: ${TEST_BUNDLE_PATH}"
  else
    parse_git_ref "${TEST_BUNDLE_URL}"
    info "Downloading test bundle from ${GIT_URL}@${GIT_REF} path=${GIT_PATH}"
    local tmp
    tmp="$(download_ref)"
    if [[ ! -d "${tmp}/${GIT_PATH}" ]]; then
      fail "bundle path '${GIT_PATH}' not found in archive"
      rm -rf "${tmp}"; exit 1
    fi
    cp -a "${tmp}/${GIT_PATH}/." "${BUNDLE_DIR}/"
    rm -rf "${tmp}"
  fi

  if [[ ! -f "${BUNDLE_DIR}/certsuite-test-bundle.yaml" ]]; then
    fail "certsuite-test-bundle.yaml not found in test bundle"
    exit 1
  fi
  pass "test bundle ready at ${BUNDLE_DIR}"

  info "Validating test bundle..."
  if ! "${REPO_ROOT}/tools/validate-test-bundle.sh" "${BUNDLE_DIR}"; then
    fail "test bundle validation failed; aborting"
    exit 1
  fi
  pass "test bundle validated"
}

# ── guestcluster lease helpers ──────────────────────────────────────────────
# Sets LEASE_KUBECONFIG_OUT (do not call via $() — must mutate ACTIVE_LEASES).
LEASE_KUBECONFIG_OUT=""
lease_cluster() {
  local pool_name="$1" topology="$2"
  local lease_name="${topology}-certsuite-$$"
  local lease_kubeconfig="${WORKDIR}/kubeconfig-${topology}"
  LEASE_KUBECONFIG_OUT=""

  export KUBECONFIG="${MGMT_KUBECONFIG}"
  info "Leasing a ${topology} guest cluster from ClusterPool '${pool_name}' in ns '${SOURCE_NAMESPACE}' ..."

  local pool_type
  pool_type="$(oc get "${CPOOL}" "${pool_name}" -n "${SOURCE_NAMESPACE}" \
    -o jsonpath='{.spec.type}' 2>/dev/null || echo '')"
  if [[ "${pool_type}" != "${topology}" ]]; then
    fail "ClusterPool '${pool_name}' has spec.type='${pool_type:-<unset>}' but requested topology '${topology}'"
    exit 1
  fi

  oc apply -f - <<EOF
apiVersion: guestcluster.opdev.io/v1alpha1
kind: ClusterLease
metadata:
  name: ${lease_name}
  namespace: ${SOURCE_NAMESPACE}
spec:
  poolRef:
    name: ${pool_name}
  ttl: 2h
  requestedBy: konflux-certsuite-pre-onboarding
EOF
  ACTIVE_LEASES+=("${lease_name}|${SOURCE_NAMESPACE}")
  info "Created ClusterLease '${lease_name}' in namespace '${SOURCE_NAMESPACE}'"

  info "Waiting up to ${LEASE_TIMEOUT}s for lease '${lease_name}' to become Bound ..."
  if ! oc wait --for=jsonpath='{.status.phase}'=Bound \
    "${CLEASE}/${lease_name}" -n "${SOURCE_NAMESPACE}" \
    --timeout="${LEASE_TIMEOUT}s"; then
    fail "lease '${lease_name}' did not become Bound within ${LEASE_TIMEOUT}s (phase=$(oc get "${CLEASE}" "${lease_name}" -n "${SOURCE_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo unset))"
    exit 1
  fi

  local kubeconfig_secret
  kubeconfig_secret="$(oc get "${CLEASE}" "${lease_name}" -n "${SOURCE_NAMESPACE}" \
    -o jsonpath='{.status.kubeconfigSecretRef.name}')"
  if [[ -z "${kubeconfig_secret}" ]]; then
    fail "lease '${lease_name}' is Bound but status.kubeconfigSecretRef.name is empty"
    exit 1
  fi
  info "Lease '${lease_name}' Bound; kubeconfig secret: ${kubeconfig_secret}"

  oc get secret "${kubeconfig_secret}" -n "${SOURCE_NAMESPACE}" \
    -o jsonpath='{.data.kubeconfig}' | base64 -d > "${lease_kubeconfig}"
  chmod 600 "${lease_kubeconfig}"

  # Durable local copy for interactive debugging (overwritten each lease).
  local local_kubeconfig="${REPO_ROOT}/config.test"
  cp -f "${lease_kubeconfig}" "${local_kubeconfig}"
  chmod 600 "${local_kubeconfig}"
  info "Wrote ${topology} guest kubeconfig to ${local_kubeconfig} (KUBECONFIG=${local_kubeconfig})"

  # Record bound instance for HCP HostedCluster discovery.
  local instance_name
  instance_name="$(oc get "${CLEASE}" "${lease_name}" -n "${SOURCE_NAMESPACE}" \
    -o jsonpath='{.status.instanceRef.name}')"
  echo "${instance_name}" > "${WORKDIR}/instance-${topology}"

  GUEST_KUBECONFIGS+=("${topology}=${lease_kubeconfig}")
  LEASE_KUBECONFIG_OUT="${lease_kubeconfig}"
}

release_topology_lease() {
  local topology="$1"
  export KUBECONFIG="${MGMT_KUBECONFIG}"
  local entry lease_name lease_ns remaining=()
  for entry in "${ACTIVE_LEASES[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    lease_name="${entry%%|*}"
    lease_ns="${entry#*|}"
    if [[ "${lease_name}" == ${topology}-certsuite-* ]]; then
      info "Releasing ${topology} ClusterLease '${lease_name}' in ${lease_ns}"
      oc delete "${CLEASE}" "${lease_name}" -n "${lease_ns}" --ignore-not-found=true --wait=false || true
    else
      remaining+=("${entry}")
    fi
  done
  ACTIVE_LEASES=()
  if [[ ${#remaining[@]} -gt 0 ]]; then
    ACTIVE_LEASES=("${remaining[@]}")
  fi
}

# ── Stage mirroring ─────────────────────────────────────────────────────────
apply_crc_stage_mirroring() {
  info "Applying stage ImageDigestMirrorSet on CRC guest ..."
  oc apply -f - <<'IDMS_EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: konflux-certsuite-stage-idms
spec:
  imageDigestMirrors:
    - source: registry.redhat.io
      mirrors:
        - registry.stage.redhat.io
IDMS_EOF
}

apply_hcp_stage_mirroring() {
  local topology="$1"
  local instance_name hc_name hc_ns ps_name
  instance_name="$(cat "${WORKDIR}/instance-${topology}" 2>/dev/null || true)"
  [[ -n "${instance_name}" ]] || { fail "no bound instance recorded for ${topology}"; exit 1; }

  export KUBECONFIG="${MGMT_KUBECONFIG}"
  hc_ns="${SOURCE_NAMESPACE}"
  hc_name="$(oc get hostedcluster -n "${hc_ns}" -o json 2>/dev/null | jq -r --arg inst "${instance_name}" '
    .items[]
    | select(.metadata.ownerReferences[]? | select(.kind=="ClusterInstance" and .name==$inst))
    | .metadata.name' | head -1)"
  if [[ -z "${hc_name}" || "${hc_name}" == "null" ]]; then
    # Fallback: match gc-<instance>-* naming used by guestcluster.
    hc_name="$(oc get hostedcluster -n "${hc_ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
      | tr ' ' '\n' | grep -E "^gc-${instance_name}-" | head -1 || true)"
  fi
  if [[ -z "${hc_name}" ]]; then
    fail "could not find HostedCluster for ClusterInstance '${instance_name}' in ${hc_ns}"
    exit 1
  fi
  info "Patching HostedCluster '${hc_name}' in ${hc_ns} with stage imageContentSources ..."

  # Add imageContentSources entry if missing (tolerate null/absent ICS).
  local has_ics
  has_ics="$(oc get hostedcluster "${hc_name}" -n "${hc_ns}" -o json 2>/dev/null | jq -r '
    (.spec.imageContentSources // [])
    | any(.[]; .source=="registry.redhat.io"
          and ((.mirrors // []) | index("registry.stage.redhat.io") != null))
  ' 2>/dev/null || echo false)"
  if [[ "${has_ics}" != "true" ]]; then
    local ics_len
    ics_len="$(oc get hostedcluster "${hc_name}" -n "${hc_ns}" -o json 2>/dev/null | jq -r '(.spec.imageContentSources // []) | length' 2>/dev/null || echo 0)"
    if [[ "${ics_len}" != "0" ]]; then
      oc patch hostedcluster "${hc_name}" -n "${hc_ns}" --type=json -p '[
        {"op":"add","path":"/spec/imageContentSources/-","value":{"mirrors":["registry.stage.redhat.io"],"source":"registry.redhat.io"}}
      ]' || warn "HostedCluster imageContentSources patch failed"
    else
      oc patch hostedcluster "${hc_name}" -n "${hc_ns}" --type=merge -p '{
        "spec":{"imageContentSources":[{"mirrors":["registry.stage.redhat.io"],"source":"registry.redhat.io"}]}
      }' || warn "HostedCluster imageContentSources merge patch failed"
    fi
  else
    info "HostedCluster already has stage imageContentSources"
  fi

  # Merge stage auth into HostedCluster pull secret.
  ps_name="$(oc get hostedcluster "${hc_name}" -n "${hc_ns}" -o jsonpath='{.spec.pullSecret.name}')"
  if [[ -n "${ps_name}" ]]; then
    info "Merging stage auth into HostedCluster pull secret '${ps_name}' ..."
    python3 - "${MGMT_KUBECONFIG}" "${hc_ns}" "${ps_name}" "${STAGING_DOCKERCONFIG}" <<'PY'
import json, sys, base64, subprocess, os
kubeconfig, ns, secret, staging_path = sys.argv[1:5]
env = os.environ.copy()
env["KUBECONFIG"] = kubeconfig

def oc_json(*args):
    out = subprocess.check_output(["oc", *args], env=env)
    return json.loads(out)

secret_obj = oc_json("get", "secret", secret, "-n", ns, "-o", "json")
raw = secret_obj["data"].get(".dockerconfigjson") or secret_obj["data"].get(".dockercfg")
data = json.loads(base64.b64decode(raw).decode())
with open(staging_path) as f:
    staging = json.load(f)
data.setdefault("auths", {}).update(staging.get("auths", {}))
new_b64 = base64.b64encode(json.dumps(data).encode()).decode()
patch = json.dumps({"data": {".dockerconfigjson": new_b64}})
subprocess.check_call(["oc", "patch", "secret", secret, "-n", ns, "--type=merge", "-p", patch], env=env)
print("patched", secret)
PY
  else
    warn "HostedCluster '${hc_name}' has no spec.pullSecret.name"
  fi
}

patch_guest_cluster_pull_secret() {
  info "Merging stage auth into guest openshift-config/pull-secret ..."
  if ! oc get secret pull-secret -n openshift-config &>/dev/null; then
    warn "guest openshift-config/pull-secret not found; skipping"
    return 0
  fi
  python3 - "${KUBECONFIG}" "${STAGING_DOCKERCONFIG}" <<'PY'
import json, sys, base64, subprocess, os
kubeconfig, staging_path = sys.argv[1:3]
env = os.environ.copy()
env["KUBECONFIG"] = kubeconfig
secret = json.loads(subprocess.check_output(
    ["oc", "get", "secret", "pull-secret", "-n", "openshift-config", "-o", "json"],
    env=env,
))
raw = secret.get("data", {}).get(".dockerconfigjson") or secret.get("data", {}).get(".dockercfg")
if not raw:
    raise SystemExit("guest pull-secret has no .dockerconfigjson data")
data = json.loads(base64.b64decode(raw).decode())
with open(staging_path) as f:
    staging = json.load(f)
data.setdefault("auths", {}).update(staging.get("auths", {}))
new_b64 = base64.b64encode(json.dumps(data).encode()).decode()
patch = json.dumps({"data": {".dockerconfigjson": new_b64}})
subprocess.check_call(
    ["oc", "patch", "secret", "pull-secret", "-n", "openshift-config", "--type=merge", "-p", patch],
    env=env,
)
print("patched guest pull-secret", file=sys.stderr)
PY
}

ensure_staging_secret_in_ns() {
  local ns="$1"
  info "Creating staging-pull-secret in namespace '${ns}' ..."
  oc create secret generic staging-pull-secret \
    --from-file=.dockerconfigjson="${STAGING_DOCKERCONFIG}" \
    --type=kubernetes.io/dockerconfigjson \
    -n "${ns}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  register_cleanup "secret|staging-pull-secret|${ns}|${KUBECONFIG}|guest"
}

attach_pull_secret_to_sa() {
  local ns="$1" sa="$2"
  [[ -n "${sa}" ]] || sa="default"
  if ! oc get sa "${sa}" -n "${ns}" &>/dev/null; then
    warn "ServiceAccount '${sa}' not found in ${ns}; skipping imagePullSecrets attach"
    return 0
  fi
  oc patch sa "${sa}" -n "${ns}" --type=json -p '[
    {"op":"add","path":"/imagePullSecrets","value":[{"name":"staging-pull-secret"}]}
  ]' 2>/dev/null || oc patch sa "${sa}" -n "${ns}" --type=merge \
    -p '{"imagePullSecrets":[{"name":"staging-pull-secret"}]}' 2>/dev/null || true
}

# ── FBC image pullability validation ────────────────────────────────────────
# Collect image refs from the FBC (opm render, else extract /configs from the
# catalog image). Rewrite registry.redhat.io → registry.stage.redhat.io and
# verify each digest is pullable before leasing any guest cluster.
# Write newline-delimited pullspecs for the FBC into $1.
# Default: selected channel head (+ related images). --fbc-validate-all: every digest.
collect_fbc_image_refs() {
  local refs_file="$1"
  : > "${refs_file}"

  local pkg_filter="${PACKAGE_NAME_OVERRIDE:-}"
  local ch_filter="${CHANNEL_NAME_OVERRIDE:-}"
  local render_out=""
  local used_opm=0

  if render_out="$(opm render "${FBC_URL}" 2>/dev/null)"; then
    used_opm=1
    if [[ "${FBC_VALIDATE_ALL}" -eq 1 ]]; then
      echo "${render_out}" | jq -r '
        select(.schema == "olm.bundle")
        | (.image // empty), (.relatedImages[]?.image // empty)
      ' 2>/dev/null >> "${refs_file}" || true
    else
      # Resolve default channel when not overridden.
      if [[ -z "${ch_filter}" ]]; then
        if [[ -n "${pkg_filter}" ]]; then
          ch_filter="$(echo "${render_out}" | jq -r --arg p "${pkg_filter}" '
            select(.schema == "olm.package" and .name == $p) | .defaultChannel // empty
          ' 2>/dev/null | head -1 || true)"
        else
          ch_filter="$(echo "${render_out}" | jq -r '
            select(.schema == "olm.package") | .defaultChannel // empty
          ' 2>/dev/null | head -1 || true)"
          pkg_filter="$(echo "${render_out}" | jq -r '
            select(.schema == "olm.package") | .name // empty
          ' 2>/dev/null | head -1 || true)"
        fi
      fi
      ch_filter="${ch_filter:-stable}"

      local head_bundle
      head_bundle="$(echo "${render_out}" | jq -r --arg p "${pkg_filter}" --arg c "${ch_filter}" '
        select(.schema == "olm.channel"
               and (.package == $p or $p == "")
               and .name == $c)
        | .entries[-1].name // .entries[0].name // empty
      ' 2>/dev/null | head -1 || true)"

      if [[ -n "${head_bundle}" ]]; then
        info "FBC validate targeting channel=${ch_filter} bundle=${head_bundle}"
        echo "${render_out}" | jq -r --arg b "${head_bundle}" '
          select(.schema == "olm.bundle" and .name == $b)
          | (.image // empty), (.relatedImages[]?.image // empty)
        ' 2>/dev/null >> "${refs_file}" || true
        echo "${render_out}" | jq -r --arg b "${head_bundle}" '
          select(.schema == "olm.bundle" and .name == $b) | .properties[]?
          | select(.type == "olm.bundle.object") | .value.data
        ' 2>/dev/null | while read -r b64; do
          if [[ -z "${b64}" || "${b64}" == "null" ]]; then
            continue
          fi
          echo "${b64}" | base64 -d 2>/dev/null | jq -r '
            select(.kind == "ClusterServiceVersion")
            | (.spec.relatedImages[]?.image // empty),
              (.spec.install.spec.deployments[]?.spec.template.spec.containers[]?.image // empty),
              (.spec.install.spec.deployments[]?.spec.template.spec.initContainers[]?.image // empty)
          ' 2>/dev/null || true
        done >> "${refs_file}" || true
      else
        warn "could not resolve channel head from opm render; collecting all bundle images"
        echo "${render_out}" | jq -r '
          select(.schema == "olm.bundle")
          | (.image // empty), (.relatedImages[]?.image // empty)
        ' 2>/dev/null >> "${refs_file}" || true
      fi
    fi
  else
    warn "opm render unavailable for image collection; extracting /configs from FBC image"
  fi

  # Extract /configs from the catalog image (needed when opm fails, and to catch
  # refs not present in olm.bundle.image alone).
  local cname extract_dir
  cname="fbc-extract-$$-$RANDOM"
  extract_dir="$(mktemp -d "${WORKDIR}/fbc-extract.XXXXXX")"
  if container_pull "${FBC_URL}" >/dev/null 2>&1 \
    && container_create "${cname}" "${FBC_URL}" >/dev/null 2>&1; then
    if "${CONTAINER_RUNTIME}" cp "${cname}:/configs" "${extract_dir}/configs" >/dev/null 2>&1 \
      && [[ -d "${extract_dir}/configs" ]]; then
      if [[ "${used_opm}" -eq 0 || "${FBC_VALIDATE_ALL}" -eq 1 ]]; then
        # Prefer python selection of channel-head images from declarative configs.
        python3 - "${extract_dir}/configs" "${refs_file}" "${pkg_filter}" "${ch_filter:-stable}" "${FBC_VALIDATE_ALL}" <<'PY'
import json, os, re, sys
from pathlib import Path
configs, refs_path, pkg, channel, validate_all = sys.argv[1:6]
validate_all = validate_all == "1"
img_re = re.compile(r'registry\.(?:stage\.)?redhat\.io/[^"\s,]+')
blobs = []
for p in Path(configs).rglob("*"):
    if not p.is_file():
        continue
    try:
        text = p.read_text(errors="ignore")
    except Exception:
        continue
    # NDJSON / JSON objects
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            blobs.append(json.loads(line))
        except Exception:
            pass
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            blobs.append(obj)
        elif isinstance(obj, list):
            blobs.extend([x for x in obj if isinstance(x, dict)])
    except Exception:
        pass

images = set()
if validate_all or not blobs:
    for p in Path(configs).rglob("*"):
        if p.is_file():
            try:
                images.update(img_re.findall(p.read_text(errors="ignore")))
            except Exception:
                pass
else:
    packages = [b for b in blobs if b.get("schema") == "olm.package"]
    channels = [b for b in blobs if b.get("schema") == "olm.channel"]
    bundles = [b for b in blobs if b.get("schema") == "olm.bundle"]
    if not pkg and packages:
        pkg = packages[0].get("name", "")
        if not channel:
            channel = packages[0].get("defaultChannel") or "stable"
    head = None
    for ch in channels:
        if ch.get("name") == channel and (not pkg or ch.get("package") == pkg):
            entries = ch.get("entries") or []
            if entries:
                head = entries[-1].get("name")
            break
    for b in bundles:
        if head and b.get("name") != head:
            continue
        if b.get("image"):
            images.add(b["image"])
        for ri in b.get("relatedImages") or []:
            if ri.get("image"):
                images.add(ri["image"])
        # Fallback scrape inside this bundle blob
        images.update(img_re.findall(json.dumps(b)))
        if head:
            break
    if not images:
        for p in Path(configs).rglob("*"):
            if p.is_file():
                try:
                    images.update(img_re.findall(p.read_text(errors="ignore")))
                except Exception:
                    pass

with open(refs_path, "a") as f:
    for img in sorted(images):
        f.write(img + "\n")
PY
      fi
    fi
    "${CONTAINER_RUNTIME}" rm -f "${cname}" >/dev/null 2>&1 || true
  else
    warn "could not pull/extract FBC image '${FBC_URL}' with ${CONTAINER_RUNTIME}"
  fi
  rm -rf "${extract_dir}" 2>/dev/null || true

  # Include the FBC catalog image itself.
  echo "${FBC_URL}" >> "${refs_file}"

  # Normalize: drop empties/duplicates, strip docker:// prefix.
  local tmp
  tmp="$(mktemp "${WORKDIR}/fbc-refs.XXXXXX")"
  sed -E 's#^docker://##' "${refs_file}" \
    | grep -E '.' \
    | sort -u > "${tmp}"
  mv "${tmp}" "${refs_file}"
}

# Map a pullspec to the registry that should serve it during pre-onboarding.
# ART FBCs declare registry.redhat.io digests that live on stage for pre-GA.
stage_pullspec_for() {
  local img="$1"
  if [[ "${img}" == registry.redhat.io/* ]]; then
    echo "${img/registry.redhat.io/registry.stage.redhat.io}"
  else
    echo "${img}"
  fi
}

image_pullable() {
  local img="$1"
  if command -v skopeo >/dev/null 2>&1; then
    if skopeo_inspect_validate "${img}"; then
      return 0
    fi
    return 1
  fi
  # Fallback: pull with --platform (ignore host arch).
  if container_pull "${img}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

validate_fbc_images() {
  if [[ "${SKIP_FBC_VALIDATE}" -eq 1 ]]; then
    warn "Skipping FBC image pullability validation (--skip-fbc-validate)"
    return 0
  fi

  info "Validating FBC image pullability for '${FBC_URL}' (platform ${VALIDATE_PLATFORM}) ..."
  require_cmd "${CONTAINER_RUNTIME}"
  if ! command -v skopeo >/dev/null 2>&1; then
    warn "skopeo not found; falling back to ${CONTAINER_RUNTIME} pull --platform ${VALIDATE_PLATFORM} (slower)"
  fi

  local refs_file
  refs_file="${WORKDIR}/fbc-image-refs.txt"
  collect_fbc_image_refs "${refs_file}"

  local count
  count="$(wc -l < "${refs_file}" | tr -d ' ')"
  if [[ "${count}" -eq 0 ]]; then
    fail "no image references found in FBC '${FBC_URL}'"
    exit 1
  fi
  info "Found ${count} unique image reference(s) to verify"

  local img check failed=0 ok=0
  local report="${WORKDIR}/fbc-pull-report.txt"
  : > "${report}"
  while IFS= read -r img; do
    [[ -n "${img}" ]] || continue
    check="$(stage_pullspec_for "${img}")"
    if image_pullable "${check}"; then
      echo "OK   ${check}" >> "${report}"
      info "  OK  ${check}"
      ok=$((ok + 1))
    else
      echo "FAIL ${check}" >> "${report}"
      if [[ "${img}" != "${check}" ]]; then
        fail "  missing on stage: ${check} (declared as ${img})"
      else
        fail "  not pullable: ${check}"
      fi
      failed=$((failed + 1))
    fi
  done < "${refs_file}"

  info "FBC pull check: ok=${ok} failed=${failed} (report: ${report})"
  if [[ "${failed}" -gt 0 ]]; then
    fail "FBC '${FBC_URL}' references ${failed} image(s) that are not pullable from stage"
    fail "Pick a fresher FBC tag (test-art list --live) or wait for stage to publish the digests"
    exit 1
  fi
  pass "All FBC-referenced images are pullable"
}

# ── FBC / operator install ──────────────────────────────────────────────────
# Prefer local opm render; fall back to PackageManifest discovery (test-art style)
# when opm cannot pull multi-arch FBC images on the host.
try_opm_render_metadata() {
  # Precedence applied at the end: CLI > TestBundle > FBC render.
  BUNDLE_CSV_NAME=""
  CSV_SUGGESTED_NS=""
  CSV_INSTALL_MODES=""

  local render_out
  if ! render_out="$(opm render "${FBC_URL}" 2>/dev/null)"; then
    warn "opm render failed for '${FBC_URL}' (will use TestBundle / PackageManifest)"
    PACKAGE_NAME="${PACKAGE_NAME_OVERRIDE:-${BUNDLE_PACKAGE_NAME:-}}"
    CHANNEL_NAME="${CHANNEL_NAME_OVERRIDE:-${BUNDLE_CHANNEL_NAME:-}}"
    return 1
  fi

  local pkg channel csv_name suggested_ns install_modes
  pkg="$(echo "${render_out}" | jq -r 'select(.schema == "olm.package") | .name' 2>/dev/null | head -1 || true)"
  if [[ -z "${pkg}" || "${pkg}" == "null" ]]; then
    pkg="$(echo "${render_out}" | jq -r 'select(.schema == "olm.channel") | .package' 2>/dev/null | head -1 || true)"
  fi
  channel="$(echo "${render_out}" | jq -r 'select(.schema == "olm.channel") | .name' 2>/dev/null | head -1 || true)"
  # Prefer package defaultChannel when present
  local default_ch
  default_ch="$(echo "${render_out}" | jq -r 'select(.schema == "olm.package") | .defaultChannel // empty' 2>/dev/null | head -1 || true)"
  [[ -n "${default_ch}" && "${default_ch}" != "null" ]] && channel="${default_ch}"
  csv_name="$(echo "${render_out}" | jq -r 'select(.schema == "olm.bundle") | .name' 2>/dev/null | head -1 || true)"
  suggested_ns="$(echo "${render_out}" | jq -r '
    select(.schema == "olm.bundle") | .properties[]?
    | select(.type == "olm.bundle.object") | .value.data' 2>/dev/null \
    | base64 -d 2>/dev/null \
    | jq -r 'select(.kind == "ClusterServiceVersion")
      | .metadata.annotations["operatorframework.io/suggested-namespace"] // empty' 2>/dev/null \
    | head -1 || true)"
  install_modes="$(echo "${render_out}" | jq -r '
    select(.schema == "olm.bundle") | .properties[]?
    | select(.type == "olm.bundle.object") | .value.data' 2>/dev/null \
    | base64 -d 2>/dev/null \
    | jq -r 'select(.kind == "ClusterServiceVersion")
      | .spec.installModes[]? | select(.supported == true) | .type' 2>/dev/null || true)"

  PACKAGE_NAME="${PACKAGE_NAME_OVERRIDE:-${BUNDLE_PACKAGE_NAME:-${pkg}}}"
  CHANNEL_NAME="${CHANNEL_NAME_OVERRIDE:-${BUNDLE_CHANNEL_NAME:-${channel}}}"
  BUNDLE_CSV_NAME="${csv_name}"
  CSV_SUGGESTED_NS="${suggested_ns}"
  CSV_INSTALL_MODES="${install_modes}"
  return 0
}

discover_package_from_catalog() {
  local catsrc_name="$1" catsrc_ns="$2"
  info "Discovering PackageManifest from CatalogSource '${catsrc_name}' (ns ${catsrc_ns}) ..."
  local i pkg channel suggested_ns pm_json
  for i in $(seq 1 60); do
    # Prefer namespaced PackageManifests (HyperShift / newer OCP); fall back cluster-wide.
    pkg="$(oc get packagemanifest -n "${catsrc_ns}" -l "catalog=${catsrc_name}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${pkg}" ]]; then
      pkg="$(oc get packagemanifest -l "catalog=${catsrc_name}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    if [[ -z "${pkg}" ]]; then
      # Last resort: match by catalog display / source fields.
      pkg="$(oc get packagemanifest -n "${catsrc_ns}" -o json 2>/dev/null | jq -r --arg c "${catsrc_name}" '
        .items[]
        | select((.metadata.labels.catalog // "") == $c
                 or (.status.catalog.source // "") == $c)
        | .metadata.name' 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "${pkg}" ]]; then
      pm_json="$(oc get packagemanifest -n "${catsrc_ns}" "${pkg}" -o json 2>/dev/null \
        || oc get packagemanifest "${pkg}" -o json 2>/dev/null || echo '{}')"
      channel="$(echo "${pm_json}" | jq -r '.status.defaultChannel // .status.channels[0].name // empty' 2>/dev/null || true)"
      suggested_ns="$(echo "${pm_json}" | jq -r '
        .status.channels[0].currentCSVDesc.annotations["operatorframework.io/suggested-namespace"] // empty' 2>/dev/null || true)"
      PACKAGE_NAME="${PACKAGE_NAME_OVERRIDE:-${BUNDLE_PACKAGE_NAME:-${pkg}}}"
      CHANNEL_NAME="${CHANNEL_NAME_OVERRIDE:-${BUNDLE_CHANNEL_NAME:-${channel:-stable}}}"
      CSV_SUGGESTED_NS="${CSV_SUGGESTED_NS:-${suggested_ns}}"
      export PACKAGE_NAME CHANNEL_NAME CSV_SUGGESTED_NS
      info "Discovered package=${PACKAGE_NAME} channel=${CHANNEL_NAME} suggestedNs=${CSV_SUGGESTED_NS:-<none>}"
      return 0
    fi
    sleep 5
  done
  if [[ -n "${PACKAGE_NAME_OVERRIDE:-${BUNDLE_PACKAGE_NAME:-}}" ]]; then
    PACKAGE_NAME="${PACKAGE_NAME_OVERRIDE:-${BUNDLE_PACKAGE_NAME}}"
    CHANNEL_NAME="${CHANNEL_NAME_OVERRIDE:-${BUNDLE_CHANNEL_NAME:-stable}}"
    export PACKAGE_NAME CHANNEL_NAME
    warn "PackageManifest not found; using TestBundle/CLI package=${PACKAGE_NAME} channel=${CHANNEL_NAME}"
    return 0
  fi
  fail "no PackageManifest for catalog=${catsrc_name}; set TestBundle spec.packageName or pass --package-name"
  exit 1
}

install_operator() {
  local topology="$1"
  info "Installing operator from FBC '${FBC_URL}' on ${topology} cluster ..."

  export BUNDLE_DIR
  # Resolve namespace / installMode / package / channel from the test bundle first.
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/resolve-bundle-config.sh"

  try_opm_render_metadata || true
  # Precedence: CLI override > TestBundle > FBC/opm (already applied in try_opm) > later catalog discovery
  PACKAGE_NAME="${PACKAGE_NAME_OVERRIDE:-${BUNDLE_PACKAGE_NAME:-${PACKAGE_NAME:-}}}"
  CHANNEL_NAME="${CHANNEL_NAME_OVERRIDE:-${BUNDLE_CHANNEL_NAME:-${CHANNEL_NAME:-}}}"
  [[ -n "${CHANNEL_NAME:-}" && "${CHANNEL_NAME}" != "null" ]] || CHANNEL_NAME=""
  export PACKAGE_NAME CHANNEL_NAME BUNDLE_CSV_NAME CSV_SUGGESTED_NS CSV_INSTALL_MODES

  local install_ns="${BUNDLE_NAMESPACE:-${CSV_SUGGESTED_NS:-}}"
  if [[ -z "${install_ns}" ]]; then
    install_ns="$(oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  generateName: oo-${topology}-
EOF
)"
    register_cleanup "namespace|${install_ns}||${KUBECONFIG}|guest"
  elif ! oc get namespace "${install_ns}" &>/dev/null; then
    oc create namespace "${install_ns}"
    register_cleanup "namespace|${install_ns}||${KUBECONFIG}|guest"
  fi
  CURRENT_INSTALL_NS="${install_ns}"
  info "Install namespace: ${install_ns}"

  ensure_staging_secret_in_ns "${install_ns}"

  # OperatorGroup (mode-aware from resolver).
  local og_name og_op og_meta og_spec=""
  og_name="$(oc -n "${install_ns}" get operatorgroup -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo '')"
  if [[ -n "${og_name}" ]]; then
    og_op="apply"; og_meta="name: ${og_name}"
  else
    og_op="create"; og_meta="generateName: oo-${topology}-"
  fi
  if [[ -n "${OG_TARGET_NS:-}" ]]; then
    og_spec="targetNamespaces:
    - ${OG_TARGET_NS}"
  fi
  oc "${og_op}" -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  ${og_meta}
  namespace: ${install_ns}
spec:
  ${og_spec}
EOF

  # CatalogSource in openshift-marketplace (test-art pattern). Avoids installing the
  # large FBC registry pod into the operator namespace on memory-tight HCP workers.
  local catsrc_ns="openshift-marketplace"
  local catsrc_name="art-fbc-${PACKAGE_NAME_OVERRIDE:-${topology}}"
  catsrc_name="$(echo "${catsrc_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63)"
  info "Applying CatalogSource '${catsrc_name}' in ${catsrc_ns} ..."
  oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${catsrc_name}
  namespace: ${catsrc_ns}
spec:
  sourceType: grpc
  image: ${FBC_URL}
  displayName: "Certsuite Test Catalog"
  publisher: "konflux-certsuite"
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
  register_cleanup "catalogsource|${catsrc_name}|${catsrc_ns}|${KUBECONFIG}|guest"
  info "Waiting for CatalogSource '${catsrc_name}' READY ..."
  local state=""
  local i
  for i in $(seq 1 90); do
    state="$(oc get catalogsource "${catsrc_name}" -n "${catsrc_ns}" \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo '')"
    if [[ "${state}" == "READY" ]]; then
      break
    fi
    sleep 10
  done
  if [[ "${state}" != "READY" ]]; then
    fail "CatalogSource '${catsrc_name}' did not become READY (state=${state:-unset})"
    oc get catalogsource "${catsrc_name}" -n "${catsrc_ns}" -o yaml >&2 || true
    oc get pods -n "${catsrc_ns}" -l "olm.catalogSource=${catsrc_name}" -o wide >&2 || true
    exit 1
  fi

  if [[ -z "${PACKAGE_NAME:-}" || "${PACKAGE_NAME}" == "null" ]]; then
    discover_package_from_catalog "${catsrc_name}" "${catsrc_ns}"
  else
    CHANNEL_NAME="${CHANNEL_NAME:-stable}"
    info "Using package=${PACKAGE_NAME} channel=${CHANNEL_NAME}"
  fi
  if [[ -z "${PACKAGE_NAME:-}" || "${PACKAGE_NAME}" == "null" ]]; then
    fail "OLM package name unresolved; set TestBundle spec.packageName/channelName or pass --package-name/--channel-name"
    exit 1
  fi
  CHANNEL_NAME="${CHANNEL_NAME:-stable}"

  # Subscription
  local sub_name starting_csv_line=""
  if [[ -n "${BUNDLE_CSV_NAME:-}" && "${BUNDLE_CSV_NAME}" != "null" ]]; then
    starting_csv_line="startingCSV: ${BUNDLE_CSV_NAME}"
  fi
  sub_name="$(oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  generateName: oo-${topology}-
  namespace: ${install_ns}
spec:
  channel: ${CHANNEL_NAME}
  installPlanApproval: Automatic
  name: ${PACKAGE_NAME}
  source: ${catsrc_name}
  sourceNamespace: ${catsrc_ns}
  ${starting_csv_line}
EOF
)"
  register_cleanup "subscription|${sub_name}|${install_ns}|${KUBECONFIG}|guest"

  info "Waiting for OLM to create a CSV ..."
  local csv=""
  for i in $(seq 1 90); do
    csv="$(oc get subscription "${sub_name}" -n "${install_ns}" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo '')"
    if [[ -n "${csv}" ]] && oc get csv "${csv}" -n "${install_ns}" &>/dev/null; then
      break
    fi
    if [[ -n "${BUNDLE_CSV_NAME:-}" ]] && oc get csv "${BUNDLE_CSV_NAME}" -n "${install_ns}" &>/dev/null; then
      csv="${BUNDLE_CSV_NAME}"
      break
    fi
    sleep 5
  done
  if [[ -z "${csv}" ]]; then
    fail "OLM did not create a CSV for subscription '${sub_name}'"
    oc get subscription "${sub_name}" -n "${install_ns}" -o yaml >&2 || true
    exit 1
  fi
  info "CSV created: ${csv}"

  # Attach staging pull secret to CSV deployment SA(s).
  local sa_name
  sa_name="$(oc get csv "${csv}" -n "${install_ns}" -o jsonpath='{.spec.install.spec.deployments[0].spec.template.spec.serviceAccountName}' 2>/dev/null || echo '')"
  if [[ -z "${sa_name}" ]]; then
    sa_name="default"
  fi
  attach_pull_secret_to_sa "${install_ns}" "${sa_name}"
  attach_pull_secret_to_sa "${install_ns}" "default"

  CSV_NAME="${csv}" INSTALL_NAMESPACE="${install_ns}" BUNDLE_DIR="${BUNDLE_DIR}" \
    bash "${SCRIPT_DIR}/apply-csv-patches.sh" || warn "CSV patch step reported an error"

  # OLM may have already created Deployments from the unpatched CSV. Clear any
  # leftover master nodeSelectors so single-worker / HCP guests can schedule.
  local dep
  for dep in $(oc get deploy -n "${install_ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    if oc get deploy "${dep}" -n "${install_ns}" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null | grep -q 'master'; then
      info "Clearing master nodeSelector on deployment/${dep}"
      oc patch deploy "${dep}" -n "${install_ns}" --type=json \
        -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' 2>/dev/null \
        || warn "failed to clear nodeSelector on deployment/${dep}"
    fi
  done

  info "Waiting for CSV '${csv}' Succeeded ..."
  local csv_phase=""
  for i in $(seq 1 90); do
    csv_phase="$(oc get csv "${csv}" -n "${install_ns}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    if [[ "${csv_phase}" == "Succeeded" ]]; then
      break
    fi
    if [[ "${csv_phase}" == "Failed" ]]; then
      fail "CSV '${csv}' failed: $(oc get csv "${csv}" -n "${install_ns}" -o jsonpath='{.status.message}' 2>/dev/null)"
      exit 1
    fi
    sleep 10
  done
  if [[ "${csv_phase}" != "Succeeded" ]]; then
    fail "timed out waiting for CSV '${csv}' to reach Succeeded (phase=${csv_phase:-unset})"
    exit 1
  fi

  # Discovery labels
  local label_key label_val pod_label_key pod_label_val names rname lower_names
  label_key="${DISCOVERY_OPERATOR_LABEL%%=*}"
  label_val="${DISCOVERY_OPERATOR_LABEL#*=}"
  oc label csv "${csv}" -n "${install_ns}" \
    "${label_key}=${label_val}" --overwrite 2>&1 || true

  pod_label_key="${DISCOVERY_POD_LABEL%%=*}"
  pod_label_val="${DISCOVERY_POD_LABEL#*=}"
  for resource_kind in ${DISCOVERY_RESOURCE_KINDS}; do
    lower_names="$(echo "${resource_kind}" | tr '[:upper:]' '[:lower:]')"
    names="$(oc get "${lower_names}" -n "${install_ns}" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo '')"
    for rname in ${names}; do
      oc patch "${lower_names}" "${rname}" -n "${install_ns}" --type=merge \
        -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"${pod_label_key}\":\"${pod_label_val}\"}}}}}" 2>&1 || true
      oc rollout status "${lower_names}/${rname}" -n "${install_ns}" --timeout=120s 2>&1 || true
    done
  done

  INSTALL_NAMESPACE="${install_ns}"
  export INSTALL_NAMESPACE
  pass "Operator installed in namespace '${install_ns}' on ${topology}"
}

# ── Operand deployment ──────────────────────────────────────────────────────
deploy_operands() {
  local topology="$1"
  info "Deploying operands from ${BUNDLE_DIR} on ${topology} cluster ..."

  local target_ns="${BUNDLE_NAMESPACE:-${INSTALL_NAMESPACE:-default}}"
  if ! oc get namespace "${target_ns}" &>/dev/null; then
    oc create namespace "${target_ns}"
    register_cleanup "namespace|${target_ns}||${KUBECONFIG}|guest"
  fi

  local prereqs_dir="${BUNDLE_DIR}/prerequisites"
  if [[ -d "${prereqs_dir}" ]]; then
    info "Applying prerequisites ..."
    local f
    for f in "${prereqs_dir}"/*.yaml "${prereqs_dir}"/*.yml; do
      [[ -f "${f}" ]] || continue
      info "  Applying: $(basename "${f}")"
      oc apply -n "${target_ns}" -f "${f}"
    done
  fi

  local operands_dir="${BUNDLE_DIR}/operands"
  if [[ ! -d "${operands_dir}" ]]; then
    fail "operands/ directory not found in ${BUNDLE_DIR}"
    exit 1
  fi

  info "Applying operand manifests ..."
  local f
  for f in "${operands_dir}"/*.yaml "${operands_dir}"/*.yml; do
    [[ -f "${f}" ]] || continue
    info "  Applying: $(basename "${f}")"
    oc apply -n "${target_ns}" -f "${f}"
  done

  export TARGET_NS="${target_ns}"
}

wait_for_readiness() {
  local topology="$1" target_ns="$2"
  info "Waiting for readiness on ${topology} cluster (ns ${target_ns}, timeout ${READINESS_TIMEOUT}s) ..."
  BUNDLE_DIR="${BUNDLE_DIR}" TARGET_NS="${target_ns}" READINESS_TIMEOUT="${READINESS_TIMEOUT}" \
    bash "${SCRIPT_DIR}/wait-for-readiness.sh"
}

run_certsuite() {
  local topology="$1"
  local suite_dir="${RESULTS_DIR}/${topology}"
  mkdir -p "${suite_dir}"

  local config_file="${CERTSUITE_CONFIG:-${BUNDLE_DIR}/certsuite_config.yml}"
  if [[ ! -f "${config_file}" ]]; then
    fail "certsuite config not found at ${config_file}"
    exit 1
  fi

  local kube_config="${WORKDIR}/kubeconfig-${topology}"
  info "Running certsuite on ${topology} cluster (labels: ${CERTSUITE_LABELS}) ..."

  set +e
  "${CONTAINER_RUNTIME}" run --rm \
    --network host \
    -e KUBECONFIG=/root/.kube/config \
    -v "${kube_config}:/root/.kube/config:ro" \
    -v "${config_file}:/tmp/certsuite_config.yml:ro" \
    -v "${suite_dir}:/workspace/results" \
    "${CERTSUITE_IMAGE}" \
    run --label-filter "${CERTSUITE_LABELS}" \
      --output-dir /workspace/results \
      --config-file /tmp/certsuite_config.yml 2>&1 | tee "${suite_dir}/certsuite.log"
  local rc=$?
  set -e

  if [[ ! -f "${suite_dir}/claim.json" ]]; then
    fail "no claim.json produced for ${topology} suite (certsuite may have failed)"
    exit 1
  fi

  local total passed failed skipped
  total="$(jq '.claim.results | length' "${suite_dir}/claim.json" 2>/dev/null || echo '?')"
  passed="$(jq '[.claim.results[] | select(.state == "passed")] | length' "${suite_dir}/claim.json" 2>/dev/null || echo '?')"
  failed="$(jq '[.claim.results[] | select(.state == "failed")] | length' "${suite_dir}/claim.json" 2>/dev/null || echo '?')"
  skipped="$(jq '[.claim.results[] | select(.state == "skipped")] | length' "${suite_dir}/claim.json" 2>/dev/null || echo '?')"
  info "certsuite results [${topology}]: total=${total} passed=${passed} failed=${failed} skipped=${skipped}"

  if [[ "${rc}" -ne 0 ]]; then
    warn "certsuite exited ${rc} for ${topology} (reported, not fatal)"
  fi
}

# ── Topology orchestration ──────────────────────────────────────────────────
run_topology() {
  local topology="$1" pool_name="$2"

  info "==================================================================="
  info "# Topology: ${topology} (pool: ${pool_name})"
  info "==================================================================="

  lease_cluster "${pool_name}" "${topology}"
  local lease_kubeconfig="${LEASE_KUBECONFIG_OUT}"
  if [[ -z "${lease_kubeconfig}" || ! -f "${lease_kubeconfig}" ]]; then
    fail "lease_cluster did not produce a kubeconfig for ${topology}"
    exit 1
  fi
  CURRENT_TOPOLOGY="${topology}"
  CURRENT_GUEST_KUBECONFIG="${lease_kubeconfig}"

  export KUBECONFIG="${lease_kubeconfig}"
  info "Using leased ${topology} cluster kubeconfig (${lease_kubeconfig})"
  oc whoami >/dev/null || { fail "cannot connect to leased ${topology} cluster"; exit 1; }

  # Stage mirroring differs by topology.
  if [[ "${topology}" == "hcp" ]]; then
    apply_hcp_stage_mirroring "${topology}"
    export KUBECONFIG="${lease_kubeconfig}"
  else
    apply_crc_stage_mirroring
  fi
  patch_guest_cluster_pull_secret || warn "guest pull-secret patch failed"

  install_operator "${topology}"

  deploy_operands "${topology}"
  local target_ns="${TARGET_NS:-}"
  if [[ -z "${target_ns}" ]]; then
    fail "operand deployment did not resolve a target namespace"
    exit 1
  fi

  wait_for_readiness "${topology}" "${target_ns}"

  if [[ "${NO_CERTSUITE}" -eq 0 ]]; then
    run_certsuite "${topology}"
  else
    info "Skipping certsuite for ${topology} (--no-certsuite)"
  fi

  # Release this topology's lease before moving to the next.
  release_topology_lease "${topology}"
  pass "Topology ${topology} completed"
}

# ── Main ────────────────────────────────────────────────────────────────────
build_staging_dockerconfig
prepare_bundle

# Fail fast: verify FBC + all declared registry.redhat.io digests on stage
# before leasing any guest cluster.
validate_fbc_images

MGMT_KUBECONFIG="$(cd "$(dirname "${KUBECONFIG_PATH}")" && pwd)/$(basename "${KUBECONFIG_PATH}")"
[[ -f "${MGMT_KUBECONFIG}" ]] || { fail "--kubeconfig not found: ${KUBECONFIG_PATH}"; exit 2; }
export KUBECONFIG="${MGMT_KUBECONFIG}"
info "Using management cluster kubeconfig: ${MGMT_KUBECONFIG}"
oc whoami >/dev/null || { fail "cannot connect to management cluster (bad --kubeconfig)"; exit 1; }

if [[ -z "${SOURCE_NAMESPACE}" ]]; then
  SOURCE_NAMESPACE="$(oc config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
  [[ -n "${SOURCE_NAMESPACE}" ]] || SOURCE_NAMESPACE="default"
fi
info "Source namespace for leases/pools: ${SOURCE_NAMESPACE}"

export READINESS_TIMEOUT

info "==================================================================="
info "# Pre-onboarding validation starting"
if [[ "${NO_CERTSUITE}" -eq 0 ]]; then
  info "# Running certsuite (labels: ${CERTSUITE_LABELS})"
else
  info "# Skipping certsuite (--no-certsuite)"
fi
info "==================================================================="

# HCP first, then CRC (release happens inside each run_topology).
run_topology "hcp" "${HCP_POOL}"
run_topology "crc" "${CRC_POOL}"

# Persist results outside workdir before EXIT cleanup removes it.
FINAL_RESULTS="${REPO_ROOT}/pre-onboarding-results-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${FINAL_RESULTS}"
cp -a "${RESULTS_DIR}/." "${FINAL_RESULTS}/" 2>/dev/null || true
info "==================================================================="
info "# Pre-onboarding validation complete. Results in ${FINAL_RESULTS}"
info "==================================================================="
