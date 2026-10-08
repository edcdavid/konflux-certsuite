#!/usr/bin/env bash
set -euo pipefail

# Generates a boilerplate certsuite test bundle directory.
#
# Usage:
#   ./scaffold-test-bundle.sh --name my-operator --output ./certsuite-test-bundle

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate a certsuite test bundle scaffold.

The test bundle describes how to deploy your operator's operands in a
software-only mode for certsuite testing, and includes the certsuite
runtime configuration (certsuite_config.yml).

Options:
  --name NAME          Bundle name (required)
  --namespace NS       Target namespace for install + operands (default: auto)
  --install-mode MODE  OLM install mode: AllNamespaces, OwnNamespace,
                       SingleNamespace, MultiNamespace (default: empty = auto)
  --workload-kind KIND Resource kind to apply discovery labels to
                       (Deployment, DaemonSet, StatefulSet; default: DaemonSet)
  --output DIR         Output directory (default: ./certsuite-test-bundle)
  -h, --help           Show this help message
EOF
}

NAME=""
NAMESPACE=""
INSTALL_MODE=""
WORKLOAD_KIND="DaemonSet"
OUTPUT="./certsuite-test-bundle"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)          NAME="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2"; shift 2 ;;
    --install-mode)  INSTALL_MODE="$2"; shift 2 ;;
    --workload-kind) WORKLOAD_KIND="$2"; shift 2 ;;
    --output)        OUTPUT="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${NAME}" ]]; then
  echo "ERROR: --name is required"
  usage
  exit 1
fi

echo "Scaffolding test bundle: ${NAME}"
echo "  Output:  ${OUTPUT}"

mkdir -p "${OUTPUT}/operands" "${OUTPUT}/prerequisites" "${OUTPUT}/csv-patches"

# ── certsuite-test-bundle.yaml ─────────────────────────────────────────
cat > "${OUTPUT}/certsuite-test-bundle.yaml" <<EOF
apiVersion: certsuite.redhat.com/v1alpha1
kind: TestBundle
metadata:
  name: ${NAME}-test-bundle
  labels:
    app.kubernetes.io/part-of: ${NAME}
spec:
  # Namespace for operator install AND operand deployment.
  # Leave empty to fall back to CSV suggested-namespace, then auto-generate.
  namespace: "${NAMESPACE}"

  # OLM install mode. One of: AllNamespaces, OwnNamespace,
  # SingleNamespace, MultiNamespace.
  # Leave empty to auto-detect from CSV supported modes.
  installMode: "${INSTALL_MODE}"

  description: |
    Software-only test deployment of ${NAME} operands.
    Deploys without hardware or license dependencies.

  # Certsuite discovery labels for the operator CSV and workload pods.
  # Omit to use defaults: CSV gets "operator=target", all DaemonSets get
  # "generic=target" on their pod templates.
  discoveryLabels:
    operator: "redhat-best-practices-for-k8s.com/operator=target"
    pod: "redhat-best-practices-for-k8s.com/generic=target"
    resources:
      - kind: ${WORKLOAD_KIND}

  # Optional CSV patches (JSON6902 or strategic-merge). Example:
  # csvPatches:
  #   - path: csv-patches/00-remove-min-kube-version.json

  readiness:
    timeout: 300
    checks:
      - kind: Deployment
        name: ${NAME}-controller
      # Add more readiness checks as needed
EOF

# ── certsuite_config.yml ───────────────────────────────────────────────
CERTSUITE_NS="${NAMESPACE:-"<REPLACE:operator-namespace>"}"
cat > "${OUTPUT}/certsuite_config.yml" <<EOF
# Certsuite runtime configuration.
# This file is REQUIRED in the test bundle.
# See: https://redhat-best-practices-for-k8s.github.io/certsuite/configuration/
targetNameSpaces:
  - name: "${CERTSUITE_NS}"

podsUnderTestLabels:
  - "redhat-best-practices-for-k8s.com/generic: target"

operatorsUnderTestLabels:
  - "redhat-best-practices-for-k8s.com/operator: target"

# CRD filters -- update with your operator's CRD suffixes
# targetCrdFilters:
#   - nameSuffix: "${NAME}.example.com"
#     scalable: false
EOF

cat > "${OUTPUT}/csv-patches/README.md" <<EOF
# Optional CSV patches

Place JSON6902 (\`.json\` arrays) or strategic-merge YAML patches here.
List them under \`spec.csvPatches\` in certsuite-test-bundle.yaml, or leave
that field empty to auto-load every file in this directory.

See examples/ptp-operator-test-bundle/csv-patches/ for HyperShift examples.
EOF

# ── Example operand manifest ──────────────────────────────────────────
cat > "${OUTPUT}/operands/example-workload.yaml" <<EOF
# TODO: Replace with your operator's actual operand CRs and workloads.
#
# If your operator reconciles Custom Resources that create workloads,
# add the CR manifests here. If the operator does not auto-create
# workloads, add Deployment manifests directly.
#
# Key requirements:
#   - Use software-only configuration (no hardware, no licenses)
#   - Use UBI base images from registry.access.redhat.com
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}-workload
  labels:
    app: ${NAME}-workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${NAME}-workload
  template:
    metadata:
      labels:
        app: ${NAME}-workload
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
EOF

# ── Example prerequisite ───────────────────────────────────────────────
cat > "${OUTPUT}/prerequisites/.gitkeep" <<EOF
EOF

echo ""
echo "Test bundle scaffolded at: ${OUTPUT}"
echo ""
echo "Next steps:"
echo "  1. Replace operands/example-workload.yaml with your operator's CRs"
echo "  2. Update certsuite_config.yml with your namespace and CRD filters"
echo "  3. Add any prerequisite Secrets/ConfigMaps to prerequisites/"
echo "  4. Add optional CSV patches under csv-patches/ if install needs tweaks"
echo "  5. Validate: ./tools/validate-test-bundle.sh ${OUTPUT}"
echo "  6. Test locally against a cluster before onboarding to Konflux"
