#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  smoke_test.sh preflight
EOF
  exit 64
}

[[ $# -ge 1 ]] || usage

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../experiment.env
source "$ROOT_DIR/experiment.env"

mode=$1
context_args=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  context_args=(--context "$KUBE_CONTEXT")
fi

run_preflight() {
  [[ $# -eq 0 ]] || usage
  command -v kubectl >/dev/null
  command -v jq >/dev/null

  "$SCRIPT_DIR/verify_setup.sh" inputs
  kubectl "${context_args[@]}" get namespace "$NAMESPACE" >/dev/null
  kubectl "${context_args[@]}" get crd dynamographdeployments.nvidia.com >/dev/null

  local manifest manifest_namespace
  for manifest in model-cache.yaml baseline.yaml thunderagent.yaml; do
    manifest_namespace=$(awk '$1 == "namespace:" {print $2; exit}' "$ROOT_DIR/manifests/$manifest")
    [[ "$manifest_namespace" == "$NAMESPACE" ]] || {
      echo "ERROR: manifests/$manifest uses namespace '$manifest_namespace'; expected '$NAMESPACE'." >&2
      return 1
    }
    kubectl "${context_args[@]}" apply --dry-run=server \
      -f "$ROOT_DIR/manifests/$manifest" >/dev/null
    echo "Server dry-run accepted manifests/$manifest"
  done

  echo "Preflight passed without creating benchmark resources."
}

[[ "$mode" == "preflight" ]] || usage
shift
run_preflight "$@"
