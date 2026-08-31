# Dynamo Agent Optimization Skills

A compact, reproducible record of a Dynamo configuration optimization experiment for `Qwen/Qwen3-32B` on eight H100 GPUs.

Using NVIDIA's Dynamo Agent Optimization Skills, we tested one change at a time against a frozen 5,775-request ToolAgent shape trace. Reducing vLLM `max_num_batched_tokens` from 8,192 to 4,096 increased strict goodput from **1.39999 to 1.75232 requests/s**—a **25.17% improvement**—with zero request errors.

Strict goodput counts only requests satisfying both TTFT `< 5,000 ms` and ITL `< 100 ms`.

The complete objective, setup, iteration history, evidence, limitations, and conclusion are documented in the [experiment report](../dynamo-agent-optimization-final-report.md).

## Repository Layout

The repository uses direct Kubernetes manifests with no custom manifest language or render step:

```text
../dynamo-agent-optimization-final-report.md
             Complete experiment narrative and conclusions
deploy/       One direct DGD YAML per measured configuration
benchmark/    The frozen in-cluster AIPerf Job
model-cache/  PVC and pinned model-download Job
data/         Shape-only workload trace
results/      Sanitized aggregate reference results
scripts/      Offline analysis and repository validation
docs/         Method and result details
run.sh        Small deployment/benchmark driver
```

## Configurations and Results

| Manifest | One-variable change | Strict goodput | Decision |
|---|---|---:|---|
| [`baseline.yaml`](deploy/baseline.yaml) | `max_num_batched_tokens=8192` | 1.39999 req/s | Baseline |
| [`winner-4096.yaml`](deploy/winner-4096.yaml) | `8192 -> 4096` | **1.75232 req/s** | **Promoted** |
| [`router-decay-1.yaml`](deploy/router-decay-1.yaml) | router decay `0 -> 1.0` | 1.54545 req/s | Rejected |
| [`gpu-memory-095.yaml`](deploy/gpu-memory-095.yaml) | GPU memory `0.90 -> 0.95` | 1.74880 req/s, two-run mean | Rejected |

The exact aggregate measurements are in [`results/reference-results.json`](results/reference-results.json). See [methodology](docs/methodology.md) and [results](docs/results.md) for interpretation.

## Reproduce

Prerequisites:

- Kubernetes with the NVIDIA Dynamo operator
- eight H100 GPUs available to the namespace
- a ReadWriteMany storage class with at least 200 GiB
- `kubectl`, `curl`, `jq`, `rg`, Python 3, Ruby, and access to the pinned Dynamo runtime image

First edit `storageClassName` in [`model-cache/cache.yaml`](model-cache/cache.yaml). If the cluster mixes GPU types, add its H100 node selector to each DGD; the manifests deliberately avoid provider-specific labels.

Then create the namespace and model-access Secret without writing the token to the repository:

```bash
export KUBE_CONTEXT=your-context
export NAMESPACE=your-namespace

kubectl --context "$KUBE_CONTEXT" create namespace "$NAMESPACE"
read -s HF_TOKEN
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic model-access \
  --from-literal=HF_TOKEN="$HF_TOKEN"
unset HF_TOKEN
```

Validate the repository, cache the exact model revision, and measure the baseline and winner:

```bash
./scripts/validate-repository.sh
./run.sh model-cache

./run.sh prepare baseline
./run.sh benchmark baseline run-001

./run.sh prepare winner-4096
./run.sh benchmark winner-4096 run-001

./scripts/compare.py \
  artifacts/baseline/run-001/strict-summary.json \
  artifacts/winner-4096/run-001/strict-summary.json
```

`prepare` deploys and smoke-tests the selected DGD, then replaces it once more so measurement begins with fresh worker KV caches. `benchmark` verifies the trace hash, runs the pinned AIPerf workload in-cluster, collects raw artifacts locally, and independently recomputes strict goodput. Local artifacts are ignored by Git.

A reproduction should be evaluated by its controlled within-cluster delta, not by matching the reference environment's absolute throughput.

## Continue the Optimization

To continue with the official skills, clone the Dynamo repository and give the agent [`deploy/winner-4096.yaml`](deploy/winner-4096.yaml) as the confirmed baseline DGD. Keep the trace, model revision, hardware count, SLOs, and benchmark semantics fixed; add one direct YAML manifest per approved candidate and preserve raw run evidence outside Git.

The completed exercise shows that a single scheduler change materially improved SLO attainment. It does not claim that 4,096 is universally optimal: TP2 topology, FlashInfer attention, CPU KV offload, and a reviewed 3,072-token candidate remain open search families.
