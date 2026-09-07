# Three-run serving-metrics comparison

Status: complete. This is the primary ThunderAgent-versus-KV-router analysis
for the six arms across `run1`, `run2`, and `run3`. SWE-bench
resolved/unresolved outcomes are
not used to infer router performance or model quality.

## Method

- Source: native vLLM and Dynamo Prometheus snapshots from both workers in each
  arm.
- Measurement interval: `post-run - post-warm`, so the fixed eight-request
  warm-up is excluded.
- Aggregate counters are sums across the three repetitions and two workers.
- Aggregate latency distributions pool the native histogram deltas across all
  requests. Means are exact `sum / count`; p50/p95/p99 are classic Prometheus
  bucket estimates and therefore have bucket-resolution error.
- Native prefix-cache hit rate is
  `vllm:prefix_cache_hits_total / vllm:prefix_cache_queries_total`.
- Cached prompt fraction is
  `vllm:prompt_tokens_cached_total / vllm:prompt_tokens_total`.
- New KV tokens computed per request comes directly from
  `vllm:request_prefill_kv_computed_tokens`.
- Sampled KV occupancy and queue depth are taken only between each arm's driver
  start and finish. The table reports the median of the three run-level values.

The calculation is reproducible with
[`scripts/analyze_three_run_serving_metrics.py`](scripts/analyze_three_run_serving_metrics.py).

## Workload volume and shape

The task list and task order were identical, but the model-request traces were
not. Agent trajectories produced different numbers and shapes of requests:

| Metric | ThunderAgent | Baseline | TA vs baseline |
|---|---:|---:|---:|
| Completed model requests | 36,011 | 53,917 | -33.2% |
| Logical prompt tokens | 1.305B | 2.099B | -37.8% |
| Generated tokens | 6.004M | 7.251M | -17.2% |
| Mean prompt tokens/request | 36,239 | 38,934 | -6.9% |
| Mean generated tokens/request | 166.7 | 134.5 | +24.0% |

Consequently, the results below are strong descriptive evidence about the
workloads each arm actually produced, but they do not isolate the router as a
causal variable. A router-only claim requires replaying the same captured
request payloads, arrival times, and concurrency against both deployments.

## Latency

Lower is better. TPOT is vLLM's per-request time per output token; ITL is its
per-token inter-token latency distribution.

| Native vLLM metric | ThunderAgent | Baseline | TA vs baseline |
|---|---:|---:|---:|
| TTFT mean | 0.349 s | 0.941 s | -62.9% |
| TTFT p50 | 0.200 s | 0.235 s | -15.2% |
| TTFT p95 | 1.352 s | 4.985 s | -72.9% |
| TTFT p99 | 4.220 s | 7.391 s | -42.9% |
| TPOT mean | 27.59 ms | 42.90 ms | -35.7% |
| TPOT p50 | 22.60 ms | 34.28 ms | -34.1% |
| TPOT p95 | 60.28 ms | 123.82 ms | -51.3% |
| TPOT p99 | 117.49 ms | 187.85 ms | -37.5% |
| ITL mean | 27.13 ms | 46.16 ms | -41.2% |
| ITL p50 | 18.13 ms | 19.06 ms | -4.9% |
| ITL p95 | 118.84 ms | 246.33 ms | -51.8% |
| ITL p99 | 248.77 ms | 294.12 ms | -15.4% |
| End-to-end request latency mean | 4.845 s | 7.102 s | -31.8% |
| End-to-end request latency p50 | 1.863 s | 2.393 s | -22.2% |
| End-to-end request latency p95 | 19.909 s | 30.603 s | -34.9% |
| End-to-end request latency p99 | 42.942 s | 81.439 s | -47.3% |

The direction is consistent in every paired repetition: ThunderAgent had lower
mean TTFT, TPOT, ITL, and end-to-end request latency in 3/3 pairs.

## Queueing, KV reuse, and preemption

| Metric | ThunderAgent | Baseline | TA vs baseline |
|---|---:|---:|---:|
| Queue time mean | 45.51 ms | 350.39 ms | -87.0% |
| Queue time p50 | 154.52 ms | 173.74 ms | -11.1% |
| Queue time p95 | 0.294 s | 3.086 s | -90.5% |
| Queue time p99 | 1.631 s | 5.949 s | -72.6% |
| Native prefix-cache hit rate | 75.28% | 30.40% | +44.88 pp |
| Cached prompt-token fraction | 92.68% | 77.71% | +14.97 pp |
| New KV tokens computed/request | 2,651 | 8,677 | -69.4% |
| Raw vLLM preemptions | 217 | 1,342 | -83.8% |
| Preemptions/1,000 requests | 6.03 | 24.89 | -75.8% |
| Preemptions/million prompt tokens | 0.166 | 0.639 | -74.0% |
| Median run-level mean KV occupancy | 50.5% | 70.8% | -20.3 pp |
| Median run-level p95 KV occupancy | 85.9% | 96.2% | -10.3 pp |
| Median run-level maximum KV occupancy | 97.6% | 97.9% | approximately equal |
| Median run-level p95 waiting requests | 1.0 | 5.1 | -4.1 requests |
| Median run-level maximum waiting requests | 3 | 7 | -4 requests |

Both configurations reached roughly 98% KV occupancy, so the experiment did
create meaningful KV-cache pressure. ThunderAgent's advantage was lower
sustained occupancy, substantially more reuse, fewer newly computed KV tokens,
less queueing, and fewer preemptions. Prefix hit rate, cached prompt fraction,
new KV work per request, and normalized preemptions favored ThunderAgent in all
3/3 paired repetitions.

## Request throughput and failures

Standard throughput requires elapsed time. The only available denominator is
the end-to-end arm duration, which includes agent/tool/environment gaps and is
therefore not a router-isolating measurement:

| End-to-end observed rate | ThunderAgent | Baseline | TA vs baseline |
|---|---:|---:|---:|
| Completed model requests/s | 3.186 | 3.427 | -7.0% |
| Logical prompt tokens/s | 115.4K | 133.4K | -13.5% |
| Generated tokens/s | 531.2 | 460.8 | +15.3% |

Generated-token rate favored ThunderAgent in 3/3 pairs, while request rate was
mixed and favored ThunderAgent in only 1/3. These rates are recorded for
completeness, but should not be used as a clean serving-capacity comparison.

Native serving failure counters show:

- vLLM `finished_reason="abort"` and `finished_reason="error"`: zero in both
  arms.
- Dynamo capacity rejections and enqueue rejections: zero in both arms.
- ThunderAgent: zero backend cancellations and zero backend errors.
- Baseline: five cancellation counts and five `publish_response` error counts,
  all in `run1` and `run2`. The equal counts likely describe the same
  five cancelled response-publication incidents, so they must not be added and
  reported as ten independent failures.
- `finished_reason="length"` occurred for 100/36,011 ThunderAgent requests and
  115/53,917 baseline requests. Reaching the requested generation limit is not
  treated as an infrastructure failure.

Agent timeouts and SWE-bench verifier outcomes are outside this serving-failure
comparison.

## Conclusion

On the requests generated in this experiment, ThunderAgent was consistently
associated with better cache reuse and materially lower model-side work,
queueing, preemption, TTFT, TPOT/ITL, and request latency. That is the useful
result of this series.

It is not yet a clean estimate of the router-only effect because the six agent
runs did not emit identical request traces. The next benchmark needed for that
claim is deterministic trace replay against new ThunderAgent and baseline
deployments; SWE-bench task resolution need not be part of that analysis.
