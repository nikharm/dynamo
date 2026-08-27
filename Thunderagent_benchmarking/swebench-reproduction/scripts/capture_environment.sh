#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output-directory>" >&2
  exit 64
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../experiment.env
source "$ROOT_DIR/experiment.env"

output_dir=$1
context_args=()
helm_context_args=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  context_args=(--context "$KUBE_CONTEXT")
  helm_context_args=(--kube-context "$KUBE_CONTEXT")
fi

command -v kubectl >/dev/null
command -v helm >/dev/null
command -v jq >/dev/null
mkdir -p "$output_dir"

date -u +%Y-%m-%dT%H:%M:%SZ > "$output_dir/captured-at.txt"
kubectl "${context_args[@]}" version -o yaml > "$output_dir/kubernetes-version.yaml"
helm version --short > "$output_dir/helm-version.txt"
helm "${helm_context_args[@]}" list -A -o json > "$output_dir/helm-releases.json"

kubectl "${context_args[@]}" get nodes -o custom-columns=\
'NAME:.metadata.name,OS_IMAGE:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,CONTAINER_RUNTIME:.status.nodeInfo.containerRuntimeVersion,ARCH:.status.nodeInfo.architecture,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,GPUS:.status.capacity.nvidia\.com/gpu' \
  > "$output_dir/nodes.txt"

kubectl "${context_args[@]}" get crd dynamographdeployments.nvidia.com -o json | \
  jq '{name:.metadata.name,labels:.metadata.labels,annotations:.metadata.annotations,versions:.spec.versions}' \
  > "$output_dir/dynamographdeployment-crd.json"

kubectl "${context_args[@]}" get deployments,daemonsets -A -o json | \
  jq '[.items[]
    | {namespace:.metadata.namespace,name:.metadata.name,kind:.kind,
       images:[.spec.template.spec.containers[].image]}
    | select((.name | ascii_downcase | test("dynamo|nvidia|gpu|grove|kai"))
        or (.images | join(" ") | ascii_downcase | test("dynamo|nvidia|gpu|grove|kai")))]' \
  > "$output_dir/platform-images.json"

for arm in baseline thunderagent; do
  dgd="qwen3-coder-next-$arm"
  kubectl "${context_args[@]}" -n "$NAMESPACE" get dynamographdeployment "$dgd" -o yaml \
    > "$output_dir/$arm-deployment.yaml"
  kubectl "${context_args[@]}" -n "$NAMESPACE" get pods \
    -l "nvidia.com/dynamo-namespace=$NAMESPACE-$dgd" -o json \
    > "$output_dir/$arm-pods.json"

  while IFS= read -r worker; do
    [[ -n "$worker" ]] || continue
    kubectl "${context_args[@]}" -n "$NAMESPACE" exec "$worker" -- \
      nvidia-smi --query-gpu=name,driver_version,memory.total,pci.bus_id \
      --format=csv,noheader \
      > "$output_dir/$worker-gpus.csv"
  done < <(
    jq -r '.items[]
      | select(.metadata.labels["nvidia.com/dynamo-component-type"] == "decode")
      | .metadata.name' "$output_dir/$arm-pods.json" | sort
  )
done

printf 'Cluster environment captured in %s\n' "$output_dir"
