#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ( "$1" != "baseline" && "$1" != "thunderagent" ) ]]; then
  echo "Usage: $0 <baseline|thunderagent> <output-directory>" >&2
  exit 64
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../experiment.env
source "$ROOT_DIR/experiment.env"

arm=$1
output_dir=$2
interval=${TELEMETRY_INTERVAL_SECONDS:-15}
dgd="qwen3-coder-next-$arm"
context_args=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  context_args=(--context "$KUBE_CONTEXT")
fi

mkdir -p "$output_dir"
kubectl "${context_args[@]}" -n "$NAMESPACE" get dynamographdeployment "$dgd" -o yaml > "$output_dir/deployment-start.yaml"
kubectl "${context_args[@]}" -n "$NAMESPACE" get pods \
  -l "nvidia.com/dynamo-namespace=$NAMESPACE-$dgd" -o wide > "$output_dir/pods-start.txt"

all_pods=()
while IFS= read -r pod; do
  [[ -n "$pod" ]] && all_pods+=("$pod")
done < <(
  kubectl "${context_args[@]}" -n "$NAMESPACE" get pods \
    -l "nvidia.com/dynamo-namespace=$NAMESPACE-$dgd" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
)

workers=()
while IFS= read -r pod; do
  [[ -n "$pod" ]] && workers+=("$pod")
done < <(
  kubectl "${context_args[@]}" -n "$NAMESPACE" get pods \
    -l "nvidia.com/dynamo-component-type=decode,nvidia.com/dynamo-namespace=$NAMESPACE-$dgd" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
)
[[ ${#workers[@]} -eq 2 ]] || {
  echo "ERROR: expected two decode workers for $dgd; found ${#workers[@]}." >&2
  exit 1
}

serving_csv="$output_dir/serving-telemetry.csv"
gpu_csv="$output_dir/gpu-telemetry.csv"
printf 'timestamp_utc,pod,kv_cache_usage,requests_running,requests_waiting,preemptions_total,prompt_tokens_total,generation_tokens_total\n' > "$serving_csv"
printf 'timestamp_utc,pod,gpu_index,gpu_utilization_percent,memory_used_mib,memory_total_mib\n' > "$gpu_csv"

for pod in "${workers[@]}"; do
  kubectl "${context_args[@]}" -n "$NAMESPACE" exec "$pod" -- \
    sh -lc 'curl -fsS http://127.0.0.1:9090/metrics' \
    > "$output_dir/$pod-metrics-start.prom"
done

capture_final() {
  kubectl "${context_args[@]}" -n "$NAMESPACE" get dynamographdeployment "$dgd" -o yaml > "$output_dir/deployment-final.yaml" 2>/dev/null || true
  kubectl "${context_args[@]}" -n "$NAMESPACE" get pods \
    -l "nvidia.com/dynamo-namespace=$NAMESPACE-$dgd" -o wide > "$output_dir/pods-final.txt" 2>/dev/null || true
  local pod
  for pod in "${all_pods[@]}"; do
    kubectl "${context_args[@]}" -n "$NAMESPACE" logs "$pod" > "$output_dir/$pod.log" 2>&1 || true
  done
  for pod in "${workers[@]}"; do
    kubectl "${context_args[@]}" -n "$NAMESPACE" exec "$pod" -- \
      sh -lc 'curl -fsS http://127.0.0.1:9090/metrics' \
      > "$output_dir/$pod-metrics-final.prom" 2>/dev/null || true
  done
}
trap capture_final EXIT
trap 'exit 130' INT TERM

while true; do
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for pod in "${workers[@]}"; do
    if metrics=$(kubectl "${context_args[@]}" -n "$NAMESPACE" exec "$pod" -- \
      sh -lc 'curl -fsS http://127.0.0.1:9090/metrics' 2>/dev/null); then
      values=$(awk '
        /^vllm:kv_cache_usage_perc{/ {kv=$NF}
        /^vllm:num_requests_running{/ {running=$NF}
        /^vllm:num_requests_waiting{/ {waiting=$NF}
        /^vllm:num_preemptions_total{/ {preemptions=$NF}
        /^vllm:prompt_tokens_total{/ {prompt=$NF}
        /^vllm:generation_tokens_total{/ {generation=$NF}
        END {printf "%g,%g,%g,%g,%g,%g", kv, running, waiting, preemptions, prompt, generation}
      ' <<<"$metrics")
      printf '%s,%s,%s\n' "$timestamp" "$pod" "$values" >> "$serving_csv"
    else
      printf '# sample failed at %s for %s\n' "$timestamp" "$pod" >> "$serving_csv"
    fi

    if gpu_rows=$(kubectl "${context_args[@]}" -n "$NAMESPACE" exec "$pod" -- \
      nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total \
      --format=csv,noheader,nounits 2>/dev/null); then
      while IFS= read -r row; do
        printf '%s,%s,%s\n' "$timestamp" "$pod" "${row// /}" >> "$gpu_csv"
      done <<<"$gpu_rows"
    fi
  done
  sleep "$interval"
done
