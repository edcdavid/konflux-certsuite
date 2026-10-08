#!/usr/bin/env bash
# Reads certsuite-test-bundle.yaml and exports install config variables.
#
# Required env before sourcing:
#   BUNDLE_DIR  — path to the fetched test bundle directory
#
# Optional env (CSV-based fallbacks):
#   CSV_SUGGESTED_NS  — CSV suggested-namespace annotation value
#   CSV_INSTALL_MODES — newline-separated list of supported CSV installModes
#
# Exports:
#   BUNDLE_NAMESPACE, BUNDLE_INSTALL_MODE, OG_TARGET_NS,
#   BUNDLE_PACKAGE_NAME, BUNDLE_CHANNEL_NAME,
#   DISCOVERY_OPERATOR_LABEL, DISCOVERY_POD_LABEL, DISCOVERY_RESOURCE_KINDS

set -euo pipefail

BUNDLE_FILE="${BUNDLE_DIR}/certsuite-test-bundle.yaml"
[[ -f "${BUNDLE_FILE}" ]] || { echo "ERROR: certsuite-test-bundle.yaml not found in ${BUNDLE_DIR}" >&2; exit 1; }

_yq() { yq e "$1" "${BUNDLE_FILE}" 2>/dev/null || echo ""; }

# ── OLM package / channel (optional; prefer over CLI when set) ────────
# Accept packageName/channelName or shorter package/channel aliases.
BUNDLE_PACKAGE_NAME=$(_yq '.spec.packageName // .spec.package // ""')
BUNDLE_CHANNEL_NAME=$(_yq '.spec.channelName // .spec.channel // ""')
if [[ -z "${BUNDLE_PACKAGE_NAME}" || "${BUNDLE_PACKAGE_NAME}" == "null" ]]; then
  BUNDLE_PACKAGE_NAME=$(awk '
    /^spec:/ { in_spec=1; next }
    in_spec && /^[^ ]/ { in_spec=0 }
    in_spec && /^[[:space:]]+(packageName|package):[[:space:]]*/ {
      sub(/^[[:space:]]+(packageName|package):[[:space:]]*/, "", $0)
      gsub(/["'\'']/, "", $0)
      print; exit
    }
  ' "${BUNDLE_FILE}" 2>/dev/null || true)
fi
if [[ -z "${BUNDLE_CHANNEL_NAME}" || "${BUNDLE_CHANNEL_NAME}" == "null" ]]; then
  BUNDLE_CHANNEL_NAME=$(awk '
    /^spec:/ { in_spec=1; next }
    in_spec && /^[^ ]/ { in_spec=0 }
    in_spec && /^[[:space:]]+(channelName|channel):[[:space:]]*/ {
      sub(/^[[:space:]]+(channelName|channel):[[:space:]]*/, "", $0)
      gsub(/["'\'']/, "", $0)
      print; exit
    }
  ' "${BUNDLE_FILE}" 2>/dev/null || true)
fi
[[ "${BUNDLE_PACKAGE_NAME}" == "null" ]] && BUNDLE_PACKAGE_NAME=""
[[ "${BUNDLE_CHANNEL_NAME}" == "null" ]] && BUNDLE_CHANNEL_NAME=""
export BUNDLE_PACKAGE_NAME BUNDLE_CHANNEL_NAME

# ── Namespace ────────────────────────────────────────────────────────
BUNDLE_NAMESPACE=$(_yq '.spec.namespace // ""')
# Fallback when yq is missing/incompatible (python-yq does not support `yq e`).
if [[ -z "${BUNDLE_NAMESPACE}" || "${BUNDLE_NAMESPACE}" == "null" ]]; then
  BUNDLE_NAMESPACE=$(awk '
    /^spec:/ { in_spec=1; next }
    in_spec && /^[^ ]/ { in_spec=0 }
    in_spec && /^[[:space:]]+namespace:[[:space:]]*/ {
      sub(/^[[:space:]]+namespace:[[:space:]]*/, "", $0)
      gsub(/["'\'']/, "", $0)
      print; exit
    }
  ' "${BUNDLE_FILE}" 2>/dev/null || true)
fi
[[ -z "${BUNDLE_NAMESPACE}" || "${BUNDLE_NAMESPACE}" == "null" ]] && BUNDLE_NAMESPACE="${CSV_SUGGESTED_NS:-}"
export BUNDLE_NAMESPACE

# ── Install mode ─────────────────────────────────────────────────────
BUNDLE_INSTALL_MODE=$(_yq '.spec.installMode // ""')
if [[ -z "${BUNDLE_INSTALL_MODE}" || "${BUNDLE_INSTALL_MODE}" == "null" ]]; then
  BUNDLE_INSTALL_MODE=""
  if [[ -n "${CSV_INSTALL_MODES:-}" ]]; then
    for MODE in AllNamespaces OwnNamespace SingleNamespace MultiNamespace; do
      if echo "${CSV_INSTALL_MODES}" | grep -q "${MODE}"; then
        BUNDLE_INSTALL_MODE="${MODE}"
        break
      fi
    done
  fi
fi
BUNDLE_INSTALL_MODE="${BUNDLE_INSTALL_MODE:-OwnNamespace}"
export BUNDLE_INSTALL_MODE

# ── OperatorGroup target namespaces ──────────────────────────────────
case "${BUNDLE_INSTALL_MODE}" in
  AllNamespaces)    OG_TARGET_NS="" ;;
  OwnNamespace)    OG_TARGET_NS="${BUNDLE_NAMESPACE}" ;;
  SingleNamespace)
    [[ -z "${BUNDLE_NAMESPACE}" ]] && { echo "ERROR: installMode=SingleNamespace requires spec.namespace" >&2; exit 1; }
    OG_TARGET_NS="${BUNDLE_NAMESPACE}" ;;
  MultiNamespace)  echo "ERROR: installMode=MultiNamespace is not yet supported" >&2; exit 1 ;;
  *)               echo "ERROR: Unknown installMode '${BUNDLE_INSTALL_MODE}'" >&2; exit 1 ;;
esac
export OG_TARGET_NS

# ── Discovery labels ─────────────────────────────────────────────────
DISCOVERY_OPERATOR_LABEL=$(_yq '.spec.discoveryLabels.operator // ""')
DISCOVERY_POD_LABEL=$(_yq '.spec.discoveryLabels.pod // ""')
DISCOVERY_RESOURCE_KINDS=$(_yq '.spec.discoveryLabels.resources[].kind // ""' | tr '\n' ' ')

[[ -z "${DISCOVERY_OPERATOR_LABEL}" || "${DISCOVERY_OPERATOR_LABEL}" == "null" ]] && \
  DISCOVERY_OPERATOR_LABEL="redhat-best-practices-for-k8s.com/operator=target"
[[ -z "${DISCOVERY_POD_LABEL}" || "${DISCOVERY_POD_LABEL}" == "null" ]] && \
  DISCOVERY_POD_LABEL="redhat-best-practices-for-k8s.com/generic=target"
[[ -z "${DISCOVERY_RESOURCE_KINDS}" || "${DISCOVERY_RESOURCE_KINDS}" == "null " ]] && \
  DISCOVERY_RESOURCE_KINDS="DaemonSet"
DISCOVERY_RESOURCE_KINDS=$(echo "${DISCOVERY_RESOURCE_KINDS}" | xargs)
export DISCOVERY_OPERATOR_LABEL DISCOVERY_POD_LABEL DISCOVERY_RESOURCE_KINDS

echo "[$(date -u +%FT%T.%3NZ)] Bundle config resolved:"
echo "  namespace:      ${BUNDLE_NAMESPACE:-<auto>}"
echo "  package:        ${BUNDLE_PACKAGE_NAME:-<from FBC/catalog>}"
echo "  channel:        ${BUNDLE_CHANNEL_NAME:-<from FBC/catalog>}"
echo "  installMode:    ${BUNDLE_INSTALL_MODE}"
echo "  OG targets:     ${OG_TARGET_NS:-<cluster-wide>}"
echo "  operator label: ${DISCOVERY_OPERATOR_LABEL}"
echo "  pod label:      ${DISCOVERY_POD_LABEL}"
echo "  label kinds:    ${DISCOVERY_RESOURCE_KINDS}"
