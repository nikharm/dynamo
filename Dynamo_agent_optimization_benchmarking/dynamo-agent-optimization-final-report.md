# Experiment Report: Optimizing Dynamo for a ToolAgent Workload

## Executive Summary

This experiment optimized a Dynamo deployment serving `Qwen/Qwen3-32B` on eight H100 GPUs. The objective was to maximize strict goodput under a fixed ToolAgent request schedule while maintaining zero request errors.

The best measured configuration reduced vLLM `max_num_batched_tokens` from 8,192 to 4,096. Strict goodput increased from 1.399988 to 1.752324 requests per second, a 25.17% improvement. The winning run completed all 5,775 requests without errors, and 2,131 requests met both latency thresholds.

Two subsequent changes failed to improve the winner. Increasing router decay to 1.0 reduced strict goodput by 11.81%. Raising GPU memory utilization from 0.90 to 0.95 produced a two-run mean 0.20% below the winner. Both were rejected.

## Objective

The verbatim goal captured at the start of the experiment was:

> Maximize AIPerf goodput requests/second at the frozen fixed-schedule rate of 4.826758331048411 requests/second; each good request must have TTFT < 5000 ms and ITL < 100 ms. Error-free serving is a secondary requirement.

The operational performance question was:

> At the fixed ToolAgent arrival schedule, which Dynamo/vLLM configuration maximizes requests per second that simultaneously meet TTFT `< 5,000 ms` and ITL `< 100 ms`, with zero request errors?

Strict goodput was independently calculated as:

```text
requests with HTTP 200, no cancellation, TTFT < 5,000 ms, and ITL < 100 ms
--------------------------------------------------------------------------------
                              benchmark duration
```

The strict `<` comparisons are intentional. AIPerf 0.10.0 reports native goodput with inclusive `<=` thresholds, so the raw profile was audited and recalculated with [`scripts/analyze-profile.py`](dynamo-agent-optimization-reproduction/scripts/analyze-profile.py).

## Experimental Setup

| Dimension | Fixed value |
|---|---|
| Model | `Qwen/Qwen3-32B` |
| Model revision | `9216db5781bf21249d130ec9da846c4624c16137` |
| Runtime | Dynamo vLLM 1.4.1 / vLLM 0.26.0 |
| Dynamo source and skillpack | `5f3329390639f620ceeac305e6a341fd344f2fb6` |
| Hardware | Eight H100 GPUs |
| Topology | Eight TP1 workers, one GPU per worker |
| Precision | FP8 weights and FP8 KV cache |
| Context limit | 131,072 tokens with YaRN scaling retained |
| Workload | 5,775-request ToolAgent shape trace |
| Schedule | Original timestamps over 1,196.248 seconds |
| Offered rate | 4.826758 requests/s |
| Endpoint | Streaming chat completions |
| Benchmark | AIPerf 0.10.0, seed 42, `ignore_eos=true` |
| Good-request SLO | TTFT `< 5,000 ms` and ITL `< 100 ms` |

The workload file preserves request timing, input and output token lengths, and prefix-sharing structure. It contains no prompts, generated responses, identities, request IDs, credentials, or infrastructure identifiers. Its checksums and schema are documented in [`data/README.md`](dynamo-agent-optimization-reproduction/data/README.md).

## Baseline

The baseline used the direct DGD in [`deploy/baseline.yaml`](dynamo-agent-optimization-reproduction/deploy/baseline.yaml). Its principal serving settings were:

| Setting | Baseline value |
|---|---:|
| Worker topology | 8 replicas × TP1 |
| `max_num_batched_tokens` | 8,192 |
| `gpu_memory_utilization` | 0.90 |
| Router mode | KV-aware |
| Router overlap-score decay | 0 |
| vLLM block size | 64 |
| Async scheduling | Enabled |

The baseline produced 1.399988 strict-good requests/s. Of 5,775 total requests, 1,709 met both strict latency thresholds, and none failed.

## Method

The search followed a controlled hill-climbing process:

1. Freeze the model, revision, hardware, workload, SLOs, and benchmark semantics.
2. Form a falsifiable hypothesis for one independently testable configuration change.
3. Review the exact manifest diff before consuming GPU time.
4. Deploy the candidate and run model-list and chat-completion smoke checks.
5. Replace the complete DGD after smoke testing to restore cold worker KV caches.
6. Replay the unchanged request schedule without unrelated inference traffic.
7. Collect all request records and independently audit strict goodput.
8. Promote only an audited, zero-error improvement over the incumbent.

Each measured configuration is preserved as a direct DGD manifest under [`deploy/`](dynamo-agent-optimization-reproduction/deploy). The benchmark remained fixed in [`benchmark/perf.yaml`](dynamo-agent-optimization-reproduction/benchmark/perf.yaml).

## Iteration Record

| Configuration | Change from incumbent | Strict goodput | Strict-good requests | Errors | Result |
|---|---|---:|---:|---:|---|
| Baseline | Initial configuration | 1.399988 req/s | 1,709 | 0 | Reference |
| Winner 4096 | Batched tokens `8192 -> 4096` | **1.752324 req/s** | **2,131** | 0 | Promoted; +25.17% vs baseline |
| Router decay 1.0 | Decay `0 -> 1.0` | 1.545446 req/s | 1,888 | 0 | Rejected; −11.81% vs winner |
| GPU memory 0.95, run 1 | Memory utilization `0.90 -> 0.95` | 1.740795 req/s | 2,118 | 0 | Repeated |
| GPU memory 0.95, run 2 | Same candidate repeat | 1.756798 req/s | 2,134 | 0 | Rejected; two-run mean 1.748796 req/s |

The GPU-memory candidate's two-run mean was 0.20% below the incumbent. The extra KV-cache capacity therefore did not justify replacing the winner.

A further `max_num_batched_tokens=3072` candidate passed technical review but was not measured. It is recorded as an unmeasured next candidate, not as a result.

## Best Configuration

The best measured deployment is [`deploy/winner-4096.yaml`](dynamo-agent-optimization-reproduction/deploy/winner-4096.yaml). It retained the baseline topology, precision, router behavior, context limit, block size, and memory utilization. The only performance-setting change was:

```text
--max-num-batched-tokens 8192
                         ↓
--max-num-batched-tokens 4096
```

Measured outcome:

| Metric | Baseline | Winner | Change |
|---|---:|---:|---:|
| Strict goodput | 1.399988 req/s | 1.752324 req/s | +25.17% |
| Strict-good requests | 1,709 | 2,131 | +422 |
| Request errors | 0 | 0 | No change |
| Average TTFT | Reference | Lower | −27.50% |
| Average ITL | Reference | Lower | −43.17% |
| Average request latency | Reference | Lower | −23.68% |

The evidence supports the interpretation that the smaller scheduling budget improved latency-SLO attainment for this arrival pattern without sacrificing completion reliability.

## Reproducibility

The repository contains the reproducible, public-safe inputs required for a new within-cluster comparison:

| Artifact | Purpose |
|---|---|
| [`deploy/`](dynamo-agent-optimization-reproduction/deploy) | Exact DGD for each measured configuration |
| [`benchmark/perf.yaml`](dynamo-agent-optimization-reproduction/benchmark/perf.yaml) | Frozen in-cluster AIPerf workload |
| [`data/toolagent-shape-trace.jsonl.gz`](dynamo-agent-optimization-reproduction/data/toolagent-shape-trace.jsonl.gz) | Shape-only request trace |
| [`model-cache/`](dynamo-agent-optimization-reproduction/model-cache) | Model-cache PVC and pinned download Job |
| [`run.sh`](dynamo-agent-optimization-reproduction/run.sh) | Cache, deploy, smoke, cold-redeploy, run, and collect workflow |
| [`scripts/analyze-profile.py`](dynamo-agent-optimization-reproduction/scripts/analyze-profile.py) | Independent strict-goodput audit |
| [`results/reference-results.json`](dynamo-agent-optimization-reproduction/results/reference-results.json) | Sanitized machine-readable results |
| [`CHECKSUMS.sha256`](dynamo-agent-optimization-reproduction/CHECKSUMS.sha256) | Integrity hashes for fixed inputs and manifests |

After configuring the Kubernetes namespace, Secret, and storage class, reproduce the comparison with:

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

Absolute performance will vary with cluster implementation and background load. The reproducible claim is the controlled baseline-to-candidate comparison on the same target, not an expectation that every cluster will produce the same requests-per-second values.

## Limitations

- The measurements characterize one model, runtime build, eight-H100 topology, workload, and SLO definition.
- The trace preserves request shapes and prefix relationships but not prompt or response content. It is a serving-performance proxy, not a production-quality evaluation.
- Functional endpoint smoke tests and zero-error benchmark completion do not constitute a task-level output-quality study.
- The experiment did not establish that 4,096 is a global optimum. It is the best configuration among the measured candidates.
- The 3,072-token candidate, TP2 topology, FlashInfer attention, and native CPU KV offload remain unmeasured in this series.
- Provider-specific cluster identifiers and raw operational artifacts were intentionally excluded from the public repository.

## Conclusion

Reducing `max_num_batched_tokens` from 8,192 to 4,096 was the only tested change promoted over its incumbent. It raised strict goodput by 25.17%, increased the number of SLO-compliant requests by 422, and preserved zero request errors. Router-decay and additional GPU-memory headroom did not improve on that result and were rejected.

The recommended configuration for this measured workload is therefore [`deploy/winner-4096.yaml`](dynamo-agent-optimization-reproduction/deploy/winner-4096.yaml). It should be treated as the incumbent for future experiments, with new candidates evaluated one change at a time against the same frozen benchmark.
