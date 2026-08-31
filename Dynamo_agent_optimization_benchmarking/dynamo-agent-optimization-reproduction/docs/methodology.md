# Methodology

## Question

At the fixed ToolAgent arrival schedule, which Dynamo/vLLM configuration maximizes requests per second that simultaneously meet TTFT `< 5,000 ms` and ITL `< 100 ms`, with zero request errors?

## Frozen Conditions

- Model: `Qwen/Qwen3-32B`
- Revision: `9216db5781bf21249d130ec9da846c4624c16137`
- Runtime: Dynamo vLLM 1.4.1 / vLLM 0.26.0
- Hardware: eight H100 GPUs; eight TP1 workers
- Precision: FP8 weights and FP8 KV cache
- Context: 131,072 tokens with retained YaRN scaling
- Workload: 5,775 requests at original timestamps over 1,196.248 seconds
- Endpoint: streaming chat completions
- AIPerf: 0.10.0, seed 42, `ignore_eos=true`, no warmup requests

Only the declared candidate lever changed at each comparison point. The direct manifests in [`deploy/`](../deploy) make those diffs inspectable without rendering.

## Optimization Loop

The exercise followed the [Dynamo Agent Optimization Skills](https://docs.dynamo.nvidia.com/dynamo/dev/digest/agent-optimization-skills):

1. Form one falsifiable hypothesis from the incumbent's evidence.
2. Review its exact semantic and resource diff before GPU spend.
3. Deploy and smoke-test the approved DGD.
4. Replace the DGD after smoke to start with fresh worker caches.
5. Replay the immutable trace without other inference traffic.
6. Collect and audit all 5,775 request records.
7. Promote only a zero-error improvement in client-visible strict goodput.

AIPerf 0.10.0 uses inclusive `<=` goodput thresholds, while this experiment's contract uses strict `<`. [`analyze-profile.py`](../scripts/analyze-profile.py) therefore audits timing, status, cancellation, uniqueness, and metric values before independently recalculating the objective.

Direct comparisons are valid only within the same cluster and benchmark series. Small deltas require repeat or noise evidence; telemetry may explain a result but cannot override the client objective.
