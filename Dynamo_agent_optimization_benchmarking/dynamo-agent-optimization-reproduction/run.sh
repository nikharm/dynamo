#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${NAMESPACE:?export NAMESPACE before running this script}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
DGD_NAME=toolagent-qwen32b
MODEL_ID=Qwen/Qwen3-32B

KUBECTL=(kubectl)
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL+=(--context "$KUBE_CONTEXT")
fi
KUBECTL_NS=("${KUBECTL[@]}" -n "$NAMESPACE")

k() { "${KUBECTL_NS[@]}" "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

usage() {
  cat <<'EOF'
Usage: ./run.sh COMMAND [VARIANT] [RUN_ID]

Commands:
  preflight                  Check namespace, Secret, CRD, and manifests
  model-cache               Create the PVC and download the pinned model
  prepare VARIANT           Deploy, smoke-test, then cold-redeploy a variant
  benchmark VARIANT [ID]    Run AIPerf and collect/audit artifacts
  all VARIANT [ID]          preflight + model-cache + prepare + benchmark

Variants: baseline, winner-4096, router-decay-1, gpu-memory-095
EOF
}

variant_manifest() {
  local variant="$1"
  local manifest="$ROOT/deploy/$variant.yaml"
  [[ -f "$manifest" ]] || die "unknown variant: $variant"
  printf '%s\n' "$manifest"
}

preflight() {
  for command in kubectl curl jq python3 shasum; do need "$command"; done
  "${KUBECTL[@]}" get namespace "$NAMESPACE" >/dev/null
  k get secret model-access >/dev/null || die "missing Secret 'model-access'"

  if ! "${KUBECTL[@]}" get crd dynamographdeployments.nvidia.com >/dev/null 2>&1; then
    echo "WARN: could not confirm the cluster-scoped DGD CRD; server dry-run is authoritative"
  fi
  k apply --dry-run=server -f "$ROOT/deploy/baseline.yaml" >/dev/null
  echo "preflight passed"
}

model_cache() {
  k get secret model-access >/dev/null || die "missing Secret 'model-access'"
  if grep -q 'storageClassName: your-storage-class-name' "$ROOT/model-cache/cache.yaml"; then
    die "edit storageClassName in model-cache/cache.yaml"
  fi
  k apply -f "$ROOT/model-cache/cache.yaml"
  k wait --for=jsonpath='{.status.phase}'=Bound pvc/model-cache --timeout=5m

  if [[ "$(k get job toolagent-model-download -o jsonpath='{.status.succeeded}' 2>/dev/null || true)" == "1" ]]; then
    echo "model download already complete"
    return
  fi
  k delete job toolagent-model-download --ignore-not-found --wait=true
  k apply -f "$ROOT/model-cache/model-download.yaml"
  k wait --for=condition=Complete job/toolagent-model-download --timeout=60m
  echo "model cache ready"
}

deploy_variant() {
  local variant="$1"
  local manifest
  manifest="$(variant_manifest "$variant")"

  k delete dynamographdeployment "$DGD_NAME" --ignore-not-found --wait=true --timeout=20m
  for attempt in $(seq 1 120); do
    local remaining
    remaining="$(k get pods -o name 2>/dev/null | awk -F/ -v prefix="$DGD_NAME-" '$2 ~ "^" prefix {count++} END {print count+0}')"
    [[ "$remaining" -eq 0 ]] && break
    sleep 5
  done
  [[ "${remaining:-1}" -eq 0 ]] || die "previous DGD pods did not terminate"

  k apply -f "$manifest"
  for attempt in $(seq 1 180); do
    local state
    state="$(k get dynamographdeployment "$DGD_NAME" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    if [[ "$state" == "successful" ]]; then
      echo "deployment ready: $variant"
      return
    fi
    [[ "$state" =~ failed|error ]] && die "deployment entered state '$state'"
    sleep 10
  done
  die "deployment did not become successful within 30 minutes"
}

smoke() {
  local local_port="${LOCAL_PORT:-18000}"
  local log_file models_file
  log_file="$(mktemp)"
  models_file="$(mktemp)"
  k port-forward "service/$DGD_NAME-frontend" "$local_port:8000" >"$log_file" 2>&1 &
  local forward_pid=$!
  cleanup_smoke() {
    kill "$forward_pid" 2>/dev/null || true
    rm -f "$log_file" "$models_file"
  }
  trap cleanup_smoke EXIT

  for attempt in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:$local_port/v1/models" >"$models_file" 2>/dev/null && break
    sleep 2
  done
  jq -e --arg model "$MODEL_ID" '.data[] | select(.id == $model)' "$models_file" >/dev/null \
    || die "model endpoint did not expose $MODEL_ID"
  curl -fsS "http://127.0.0.1:$local_port/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: READY\"}],\"max_tokens\":8,\"temperature\":0}" \
    | jq -e '.choices[0].message.content | type == "string"' >/dev/null
  cleanup_smoke
  trap - EXIT
  echo "smoke test passed"
}

prepare() {
  local variant="$1"
  deploy_variant "$variant"
  smoke
  deploy_variant "$variant"
  echo "cold measured state is ready; send no inference traffic before benchmark"
}

benchmark() {
  local variant="$1"
  local run_id="${2:-run-001}"
  variant_manifest "$variant" >/dev/null
  [[ "$run_id" =~ ^[a-z0-9][a-z0-9.-]{0,39}$ ]] || die "invalid run ID"

  local trace="$ROOT/data/toolagent-shape-trace.jsonl.gz"
  local expected=f081d6352e0f02862fb242146372b47ececc6f661e92935c528dcceefbdfcb20
  local actual
  actual="$(shasum -a 256 "$trace" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "trace checksum mismatch"

  k create configmap toolagent-shape-trace \
    --from-file=toolagent-shape-trace.jsonl.gz="$trace" \
    --dry-run=client -o yaml | k apply -f -
  k delete job toolagent-benchmark --ignore-not-found --wait=true
  k apply -f "$ROOT/benchmark/perf.yaml"

  local pod="" phase=""
  for attempt in $(seq 1 180); do
    pod="$(k get pods -l job-name=toolagent-benchmark -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    phase="$(k get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ -n "$pod" && "$phase" == "Running" ]] && break
    [[ "$phase" == "Failed" ]] && die "benchmark pod failed before measurement"
    sleep 5
  done
  [[ -n "$pod" && "$phase" == "Running" ]] || die "benchmark pod did not start"

  local result=""
  for attempt in $(seq 1 480); do
    if k exec "$pod" -- test -f /artifacts/AIPERF_DONE >/dev/null 2>&1; then result=done; break; fi
    if k exec "$pod" -- test -f /artifacts/AIPERF_FAILED >/dev/null 2>&1; then result=failed; break; fi
    sleep 5
  done
  [[ -n "$result" ]] || die "benchmark did not finish within 40 minutes"

  local artifact_dir="$ROOT/artifacts/$variant/$run_id"
  [[ ! -e "$artifact_dir" ]] || die "artifact directory already exists: $artifact_dir"
  mkdir -p "$artifact_dir"
  k cp "$pod:/artifacts/run/." "$artifact_dir"
  k exec "$pod" -- touch /artifacts/COLLECTED
  cp "$(variant_manifest "$variant")" "$artifact_dir/deploy.yaml"

  local profile="$artifact_dir/profile_export.jsonl"
  [[ -f "$profile" ]] || die "profile_export.jsonl was not collected"
  python3 "$ROOT/scripts/analyze-profile.py" "$profile" \
    --output "$artifact_dir/strict-summary.json" \
    --expected-requests 5775 --ttft-ms 5000 --itl-ms 100 --gpu-count 8
  [[ "$result" == "done" ]] || die "AIPerf failed; artifacts preserved at $artifact_dir"
  echo "benchmark complete: $artifact_dir"
}

command="${1:-}"
case "$command" in
  preflight) preflight ;;
  model-cache) model_cache ;;
  prepare) [[ $# -ge 2 ]] || { usage; exit 2; }; prepare "$2" ;;
  benchmark) [[ $# -ge 2 ]] || { usage; exit 2; }; benchmark "$2" "${3:-run-001}" ;;
  all)
    [[ $# -ge 2 ]] || { usage; exit 2; }
    preflight
    model_cache
    prepare "$2"
    benchmark "$2" "${3:-run-001}"
    ;;
  *) usage; exit 2 ;;
esac
