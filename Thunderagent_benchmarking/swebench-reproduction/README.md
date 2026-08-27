# Reproducing the ThunderAgent SWE-bench experiment setup

This directory recreates the setup used by the accompanying [ThunderAgent SWE-bench report](../thunderagent-final-swebench-report.md). It contains the pinned workload, serving manifests, Harbor preparation scripts, execution wrapper, and telemetry collector for that experiment only.

Reproduction does not imply that another run will produce the same task outcomes, latency distributions, scheduler activity, or performance improvement. Coding agents, model generation, container execution, and concurrent scheduling all introduce run-to-run variation. These files establish the experimental conditions; they do not prescribe how results must be analyzed.

## Experiment shape

| Item | Configuration |
|---|---|
| Model | `Qwen/Qwen3-Coder-Next` at the revision in [`experiment.env`](experiment.env) |
| Serving arms | Dynamo KV-aware routing and ThunderAgent |
| Replicas per arm | 2 |
| GPUs per replica | 2-way tensor parallelism |
| GPUs per arm | 4 H100 NVL GPUs |
| Total serving GPUs | 8 H100 NVL GPUs |
| Context limit | 65,536 tokens |
| GPU memory utilization | 90% |
| Workload | 90 unique SWE-bench Verified tasks through Pi and Harbor |
| Client concurrency | 32 per arm |
| Per-task limit | 2 vCPUs and 8 GiB memory |
| Agent and verifier timeout | 3,000 seconds, encoded into the generated Harbor tasks |
| Execution | Both arms start together on separate GPU pools and separate driver hosts |

The reference topology used four GPU nodes with two H100 NVL GPUs per node. Each TP2 replica stayed within one node, and pod anti-affinity placed the two replicas for an arm on different nodes. Using a different node shape or allowing tensor-parallel communication across the network changes the experiment.

## Included files

| Path | Purpose |
|---|---|
| [`experiment.env`](experiment.env) | Software, model, workload, and resource pins |
| [`.gitignore`](.gitignore) | Prevents downloaded dependencies, virtual environments, and run artifacts from being committed |
| [`manifests/model-cache.yaml`](manifests/model-cache.yaml) | Preloads the pinned model snapshot on all four GPU nodes |
| [`manifests/baseline.yaml`](manifests/baseline.yaml) | Two-replica Dynamo KV-aware baseline |
| [`manifests/thunderagent.yaml`](manifests/thunderagent.yaml) | Two-replica ThunderAgent deployment |
| [`workload/swebench-90.txt`](workload/swebench-90.txt) | Frozen ordered task list |
| [`scripts/select_tasks.py`](scripts/select_tasks.py) | Regenerates the deterministic repository-proportional sample |
| [`scripts/prepare_harbor.py`](scripts/prepare_harbor.py) | Converts the pinned SWE-bench records into Harbor tasks |
| [`scripts/setup_harbor.sh`](scripts/setup_harbor.sh) | Installs the pinned Harbor adapter and Pi provider on a driver |
| [`scripts/warmup_harbor.sh`](scripts/warmup_harbor.sh) | Pulls and verifies the complete Harbor image cache |
| [`scripts/verify_setup.sh`](scripts/verify_setup.sh) | Checks frozen inputs and deployed topology |
| [`scripts/smoke_test.sh`](scripts/smoke_test.sh) | Runs the non-creating cluster and manifest preflight |
| [`scripts/run_arm.sh`](scripts/run_arm.sh) | Runs one arm from its dedicated driver host |
| [`scripts/capture_environment.sh`](scripts/capture_environment.sh) | Records Kubernetes, operator, node, GPU-driver, and runtime-image versions |
| [`scripts/capture_telemetry.sh`](scripts/capture_telemetry.sh) | Captures raw vLLM, GPU, deployment, and router evidence |

## Prerequisites

### Kubernetes serving cluster

- Kubernetes 1.30 or newer and Helm 3.8 or newer.
- Dynamo Platform chart and operator `1.4.1`, with the `DynamoGraphDeployment` CRD.
- Four GPU nodes, each with two H100 NVL GPUs and enough CPU, memory, shared memory, and local disk for one TP2 worker.
- One non-GPU control node for the Dynamo frontends and ThunderAgent router.
- Access to the pinned NGC runtime image.
- A shared convention that `/var/lib/dynamo-model-cache` is persistent node-local storage.
- `kubectl` and `jq` on the administration host.

### Harbor drivers

Use two independent Linux hosts: one drives the baseline and one drives ThunderAgent. Do not run both arms from one host if the goal is to preserve the reported client-isolation design.

Each driver must provide:

- Docker with Compose support.
- Git, curl, jq, and [`uv`](https://docs.astral.sh/uv/) `0.10.7`.
- Python `3.12.12`, installed by `uv` if necessary.
- Network access to its assigned private Dynamo endpoint and to the registries used by SWE-bench task images.
- Synchronized system time.
- Sufficient Docker storage for the complete 90-task image set; 400 GB is a practical minimum.
- Capacity appropriate for 32 containers with 2-vCPU and 8-GiB per-container limits. A 64-vCPU, 256-GiB host avoids making the client an obvious bottleneck.

## 1. Install or verify the pinned Dynamo operator

The `runtimeVersionOverride: "1.4.1"` fields in the deployment manifests select runtime-compatible behavior in an operator that is already installed. They do not install or pin that operator. On a cluster without Dynamo, install the exact platform chart used by this setup:

```bash
export DYNAMO_PLATFORM_VERSION=1.4.1
helm fetch \
  "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${DYNAMO_PLATFORM_VERSION}.tgz"
helm upgrade --install dynamo-platform \
  "dynamo-platform-${DYNAMO_PLATFORM_VERSION}.tgz" \
  --namespace dynamo-system \
  --create-namespace
```

Do not install a second cluster-wide Dynamo operator if the cluster already has one. Verify that the existing release and controller image are `1.4.1`:

```bash
helm list -A | grep dynamo-platform
kubectl get deployments -A -o json | jq -r '
  .items[]
  | select(.metadata.name | contains("dynamo-operator-controller-manager"))
  | [.metadata.namespace, .metadata.name, .spec.template.spec.containers[].image]
  | @tsv'
kubectl get crd dynamographdeployments.nvidia.com
```

The installation pattern follows the official [Dynamo operator installation guide](https://docs.nvidia.com/dynamo/dev/knowledge-base/kubernetes/kubernetes-operator/dynamo-operator).

## 2. Prepare the namespace, node labels, and credentials

The checked-in manifests use the namespace `thunderagent-bench`. If a different namespace is required, update all three manifests and set `NAMESPACE` consistently before running the scripts.

```bash
kubectl create namespace thunderagent-bench
```

Label the control node and four GPU nodes. Replace the example node names with real Kubernetes node names:

```bash
kubectl label node CONTROL_NODE thunderagent.nvidia.com/role=control --overwrite

kubectl label node BASELINE_GPU_NODE_1 BASELINE_GPU_NODE_2 \
  thunderagent.nvidia.com/benchmark-arm=baseline \
  thunderagent.nvidia.com/model-cache=qwen3-coder-next --overwrite

kubectl label node THUNDERAGENT_GPU_NODE_1 THUNDERAGENT_GPU_NODE_2 \
  thunderagent.nvidia.com/benchmark-arm=thunderagent \
  thunderagent.nvidia.com/model-cache=qwen3-coder-next --overwrite
```

Configure NGC image-pull authentication using the cluster's normal mechanism. If Hugging Face authentication is required, create the optional secret referenced by the manifests:

```bash
kubectl -n thunderagent-bench create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="YOUR_HUGGING_FACE_TOKEN"
```

Do not commit credentials or expose either model endpoint publicly.

## 3. Preload the pinned model snapshot

The serving workers run with `HF_HUB_OFFLINE=1`, so preload the model on all four labeled GPU nodes before deploying either arm:

```bash
kubectl apply -f manifests/model-cache.yaml
kubectl -n thunderagent-bench rollout status \
  daemonset/qwen3-coder-next-model-cache --timeout=4h
```

Confirm that the DaemonSet has four ready pods. Then remove the downloader pods; the node-local snapshots remain under `/var/lib/dynamo-model-cache`:

```bash
kubectl -n thunderagent-bench get pods \
  -l app.kubernetes.io/name=qwen3-coder-next-model-cache -o wide
kubectl delete -f manifests/model-cache.yaml
```

## 4. Deploy both serving arms

Before creating the serving resources, ask the live API server and Dynamo admission webhook to validate all three manifests. This also verifies the frozen workload inputs and creates no benchmark resources:

```bash
./scripts/smoke_test.sh preflight
```

Then apply the two serving manifests from this directory:

```bash
kubectl apply -f manifests/baseline.yaml
kubectl apply -f manifests/thunderagent.yaml

kubectl -n thunderagent-bench wait --for=condition=Ready \
  dynamographdeployment/qwen3-coder-next-baseline --timeout=4h
kubectl -n thunderagent-bench wait --for=condition=Ready \
  dynamographdeployment/qwen3-coder-next-thunderagent --timeout=4h

./scripts/verify_setup.sh cluster
```

The verification requires two decode workers on two nodes and four GPUs for each arm, one ThunderAgent router, and zero container restarts.

Record the cluster software and hardware environment after both deployments are ready:

```bash
./scripts/capture_environment.sh artifacts/environment
```

This captures Kubernetes and Helm versions, the Dynamo operator and relevant platform images, node OS/runtime information, the installed DGD CRD, final deployment and pod specifications, and the H100/NVIDIA driver information reported inside each serving worker. The output is run evidence and may contain cluster node or pod names; keep it under the ignored `artifacts/` directory rather than committing it with this setup.

Expose each frontend only through private networking appropriate to the cluster. The two driver hosts each need an OpenAI-compatible endpoint ending in `/v1`. Verify each endpoint independently:

```bash
curl -fsS http://BASELINE_PRIVATE_ENDPOINT/v1/models
curl -fsS http://THUNDERAGENT_PRIVATE_ENDPOINT/v1/models
```

## 5. Prepare the identical Harbor workload on both drivers

Copy this entire `swebench-reproduction` directory to both driver hosts. On each host:

```bash
curl -LsSf https://astral.sh/uv/0.10.7/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
./scripts/setup_harbor.sh
./scripts/warmup_harbor.sh
```

`setup_harbor.sh` fetches only the pinned ThunderAgent Harbor-adapter and Pi-provider commits into `.deps/`, creates `.venv/`, generates the 90 tasks, and verifies both the task-list and generated-tree hashes. It also writes the resolved Python package set to `.deps/driver-packages.txt`. Compare that file between the two drivers before starting the run; it must be identical.

The original experiment pinned the Harbor source commit and SWE-bench package but did not retain a complete lock of every transitive Python package. The package snapshot makes this limitation visible and prevents the two arms from silently using different driver environments; it does not claim that a later package resolution is byte-for-byte identical to the original driver installation.

The checked-in task list is authoritative. To independently regenerate the selection without replacing it:

```bash
.venv/bin/python scripts/select_tasks.py \
  --dataset-revision c104f840cc67f8b6eec6f759ebc8b2693d585d4a \
  --tasks 90 \
  --seed thunderagent-realistic-20260826 > /tmp/swebench-90.txt

diff -u workload/swebench-90.txt /tmp/swebench-90.txt
```

The diff should be empty.

## 6. Start telemetry collection

Run one collector per arm from a host with Kubernetes access. These commands continue until interrupted and write raw CSV samples plus final deployment and pod logs:

```bash
./scripts/capture_telemetry.sh baseline artifacts/baseline/run-001/cluster
./scripts/capture_telemetry.sh thunderagent artifacts/thunderagent/run-001/cluster
```

Run them in separate terminals or under a process supervisor before starting Harbor.

## 7. Start the two Harbor arms together

Use a common future epoch timestamp so both independent drivers begin at approximately the same time. Ensure both hosts use synchronized clocks.

On the baseline driver:

```bash
START_AT_EPOCH=COMMON_START_EPOCH \
DYNAMO_API_BASE=http://BASELINE_PRIVATE_ENDPOINT/v1 \
./scripts/run_arm.sh baseline run-001
```

On the ThunderAgent driver:

```bash
START_AT_EPOCH=COMMON_START_EPOCH \
DYNAMO_API_BASE=http://THUNDERAGENT_PRIVATE_ENDPOINT/v1 \
./scripts/run_arm.sh thunderagent run-001
```

The wrapper uses the same frozen 90-task set and resource settings for both arms. Harbor runs 32 tasks concurrently, so exact task launch and completion order can vary between hosts; task identity, count, and generated content are the controlled inputs. The wrapper sets `DYN_AGENT_SESSION_FINAL=0` for the KV-aware baseline and `DYN_AGENT_SESSION_FINAL=1` for ThunderAgent. Harbor results and run metadata are written under `artifacts/<arm>/run-001/` on the corresponding driver.

Do not reuse a warmed model endpoint for one arm while cold-starting the other, change concurrency between arms, or place unrelated GPU workloads on the four serving nodes during measurement.

## 8. Confirm the mechanism was exercised

This is a setup check, not an expected numerical result:

- Both arms should remain healthy with two TP2 workers and no restarts.
- vLLM telemetry should show substantial KV-cache utilization during the run.
- The ThunderAgent router log should contain pressure detection and pause/resume activity if the workload creates enough pressure in that run.
- Driver hosts should not swap, exhaust Docker storage, or become the obvious throughput bottleneck.

If a run does not develop KV pressure or ThunderAgent does not pause/resume work, record that outcome. Do not alter the configuration after observing results and present the changed run as a reproduction of this setup.

## 9. Preserve artifacts

At minimum, retain:

- Both Harbor job directories and `run-metadata.json` files.
- `harbor.log` from each driver.
- `driver-host.txt` and `driver-vmstat.log` from each driver.
- The cluster environment snapshot from `scripts/capture_environment.sh`.
- Both serving and GPU telemetry CSV files.
- Final DynamoGraphDeployment YAML.
- Baseline frontend and worker logs.
- ThunderAgent frontend, router, and worker logs.
- Pod placement, restart counts, and any infrastructure errors.

These files intentionally do not include an analysis program. Consumers can apply their own task-outcome, latency, throughput, or scheduler analysis while keeping the experimental inputs auditable.

## 10. Cleanup

Remove only the two benchmark deployments:

```bash
kubectl delete -f manifests/baseline.yaml
kubectl delete -f manifests/thunderagent.yaml
```

The node-local model cache is not deleted by these commands. Remove it separately only if that destructive cleanup is intended.
