#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "inputs" && "$1" != "cluster" && "$1" != "all" ) ]]; then
  echo "Usage: $0 <inputs|cluster|all>" >&2
  exit 64
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../experiment.env
source "$ROOT_DIR/experiment.env"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

verify_inputs() {
  local task_list="$ROOT_DIR/workload/swebench-90.txt"
  local count unique actual_hash
  count=$(awk 'NF && $1 !~ /^#/ {n++} END {print n+0}' "$task_list")
  unique=$(awk 'NF && $1 !~ /^#/ {seen[$1]=1} END {for (id in seen) n++; print n+0}' "$task_list")
  actual_hash=$(sha256_file "$task_list")

  [[ "$count" -eq "$HARBOR_TASKS" ]] || {
    echo "ERROR: expected $HARBOR_TASKS tasks, found $count." >&2
    return 1
  }
  [[ "$unique" -eq "$HARBOR_TASKS" ]] || {
    echo "ERROR: task manifest contains duplicates." >&2
    return 1
  }
  [[ "$actual_hash" == "$SWEBENCH_TASK_LIST_SHA256" ]] || {
    echo "ERROR: task manifest hash does not match experiment.env." >&2
    return 1
  }
  printf '%s  workload/swebench-90.txt\n' "$actual_hash"

  local generated="$ROOT_DIR/.deps/ThunderAgent/examples/datagen/harbor/datasets/swebench"
  if [[ -d "$generated" ]]; then
    local tree_lines tree_hash
    tree_lines=$(
      cd "$generated"
      while IFS= read -r file; do
        printf '%s  %s\n' "$(sha256_file "$file")" "$file"
      done < <(find . -type f -print | LC_ALL=C sort)
    )
    tree_hash=$(printf '%s' "$tree_lines" | sha256_stream)
    [[ "$tree_hash" == "$GENERATED_TASK_TREE_SHA256" ]] || {
      echo "ERROR: generated Harbor task tree hash does not match experiment.env." >&2
      return 1
    }
    printf '%s  generated Harbor task tree\n' "$tree_hash"
  else
    echo "Generated Harbor tasks are not present; run scripts/setup_harbor.sh on each driver."
  fi
}

verify_cluster() {
  command -v kubectl >/dev/null
  command -v jq >/dev/null

  local context_args=()
  if [[ -n "$KUBE_CONTEXT" ]]; then
    context_args=(--context "$KUBE_CONTEXT")
  fi
  kubectl "${context_args[@]}" get namespace "$NAMESPACE" >/dev/null
  kubectl "${context_args[@]}" get crd dynamographdeployments.nvidia.com >/dev/null

  local crd_operator_version operator_count
  crd_operator_version=$(kubectl "${context_args[@]}" get crd \
    dynamographdeployments.nvidia.com \
    -o jsonpath='{.metadata.annotations.dynamo\.nvidia\.com/operator-version}')
  [[ "$crd_operator_version" == "$DYNAMO_PLATFORM_CHART_VERSION" ]] || {
    echo "ERROR: DGD CRD reports operator version '$crd_operator_version'; expected $DYNAMO_PLATFORM_CHART_VERSION." >&2
    return 1
  }

  operator_count=$(kubectl "${context_args[@]}" get deployments -A -o json | \
    jq --arg image "$DYNAMO_OPERATOR_IMAGE" \
      '[.items[].spec.template.spec.containers[] | select(.image == $image)] | length')
  [[ "$operator_count" -ge 1 ]] || {
    echo "ERROR: expected a Dynamo operator deployment using $DYNAMO_OPERATOR_IMAGE." >&2
    return 1
  }
  echo "Dynamo operator and DGD CRD: $DYNAMO_PLATFORM_CHART_VERSION."

  local arm dgd pods_json worker_count gpu_count node_count restart_count router_count
  for arm in baseline thunderagent; do
    dgd="qwen3-coder-next-$arm"
    kubectl "${context_args[@]}" -n "$NAMESPACE" get dynamographdeployment "$dgd" >/dev/null
    pods_json=$(kubectl "${context_args[@]}" -n "$NAMESPACE" get pods \
      -l "nvidia.com/dynamo-namespace=$NAMESPACE-$dgd" -o json)
    worker_count=$(jq '[.items[] | select(.metadata.labels["nvidia.com/dynamo-component-type"] == "decode")] | length' <<<"$pods_json")
    gpu_count=$(jq '[.items[] | select(.metadata.labels["nvidia.com/dynamo-component-type"] == "decode") | .spec.containers[] | (.resources.requests["nvidia.com/gpu"] // "0") | tonumber] | add // 0' <<<"$pods_json")
    node_count=$(jq '[.items[] | select(.metadata.labels["nvidia.com/dynamo-component-type"] == "decode") | .spec.nodeName] | unique | length' <<<"$pods_json")
    restart_count=$(jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0' <<<"$pods_json")

    [[ "$worker_count" -eq "$WORKERS_PER_ARM" ]] || {
      echo "ERROR: $dgd has $worker_count decode workers; expected $WORKERS_PER_ARM." >&2
      return 1
    }
    [[ "$gpu_count" -eq 4 ]] || {
      echo "ERROR: $dgd requests $gpu_count GPUs; expected 4." >&2
      return 1
    }
    [[ "$node_count" -eq 2 ]] || {
      echo "ERROR: $dgd decode workers occupy $node_count nodes; expected 2." >&2
      return 1
    }
    [[ "$restart_count" -eq 0 ]] || {
      echo "ERROR: $dgd has $restart_count container restarts." >&2
      return 1
    }

    if [[ "$arm" == "thunderagent" ]]; then
      router_count=$(jq '[.items[] | select(.metadata.labels["nvidia.com/dynamo-component"] == "ThunderAgentRouter")] | length' <<<"$pods_json")
      [[ "$router_count" -eq 1 ]] || {
        echo "ERROR: expected one ThunderAgentRouter pod; found $router_count." >&2
        return 1
      }
    fi

    echo "$dgd: $worker_count decode workers, $gpu_count GPUs, $node_count nodes, zero restarts."
    jq -r '.items[] | [.metadata.name, .status.phase, (.spec.nodeName // "unassigned")] | @tsv' <<<"$pods_json"
  done
}

case "$1" in
  inputs) verify_inputs ;;
  cluster) verify_cluster ;;
  all)
    verify_inputs
    verify_cluster
    ;;
esac
