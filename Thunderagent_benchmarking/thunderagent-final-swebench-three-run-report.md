# ThunderAgent Program-Aware Scheduling Evaluation — Repeated SWE-bench Serving Study

Study: three repeated paired runs

Execution date: September 2–3, 2026 UTC

Status: complete

## 1. Goal

Evaluate whether ThunderAgent's program-aware pause/resume scheduling improves
model-serving efficiency for a realistic, prefix-heavy coding-agent workload
under KV-cache pressure, compared with Dynamo's KV-aware router.

To remain consistent with the original experiment, the primary comparison uses
the same six request-level serving metrics:

- mean time to first token;
- mean queue time;
- mean model-request latency;
- mean inter-token latency;
- prefix-cache hit rate;
- worker preemptions.

SWE-bench patch correctness is not used to establish the scheduling result.
ThunderAgent is not expected to change the model's reasoning quality.

## 2. Experimental design

### 2.1 Repeated paired execution

| Pair | First arm | Second arm | Purpose |
|---|---|---|---|
| `run1` | ThunderAgent | Dynamo KV-aware baseline | TA-first pair |
| `run2` | Dynamo KV-aware baseline | ThunderAgent | Baseline-first pair |
| `run3` | ThunderAgent | Dynamo KV-aware baseline | TA-first pair |

Only four H100s were available, so the arms ran sequentially rather than
simultaneously. Every arm used a new serving deployment and new worker
processes. Between arms, the deployment was removed, GPU consumers were
verified absent, and the driver was verified to have zero benchmark containers
and processes. Node-local model weights and the identical Harbor image cache
were retained consistently.

### 2.2 Workload

| Item | Configuration |
|---|---|
| Benchmark | SWE-bench Verified through Harbor/Pi |
| Tasks | 90 unique tasks |
| Task order | Frozen and identical in all six arms |
| Task-list SHA-256 | `397a87f516967776db4fe382c1abf78266c145316eedb0a8373a361868e6b2b7` |
| Attempts and retries | One attempt; no retry |
| Client concurrency | 32 |
| Per-task resources | 2 vCPUs; 8 GiB memory |
| Agent timeout | 3,000 seconds |

### 2.3 Model and serving topology

| Item | Configuration |
|---|---|
| Model | `Qwen/Qwen3-Coder-Next` |
| Model revision | `a7fbcb5c0e12d62a448eaa0e260346bf5dcc0feb` |
| Precision / KV precision | BF16 / BF16 |
| Maximum model context | 65,536 tokens |
| GPU memory utilization limit | 90% |
| vLLM replicas | 2 |
| Tensor parallelism per replica | 2 |
| GPUs per arm | 4 H100 NVL GPUs |
| Maximum sequences per worker | 32 |
| Maximum batched tokens | 8,192 |
| Dynamo runtime | 1.4.1 |
| Baseline | Dynamo frontend with KV routing |
| ThunderAgent | Dynamo routing plus program-aware pause/resume scheduling |

## 3. Results

Negative differences indicate lower latency or fewer preemptions. Cache hit-rate
differences are shown in percentage points (`pp`).

### 3.1 Aggregate result across all three runs

The aggregate pools the native vLLM histogram sums and counts for latency,
pools prefix-cache hit/query counters, and sums worker preemptions across the
three repetitions.

| Metric | Dynamo KV-aware baseline | ThunderAgent | Difference |
|---|---:|---:|---:|
| Mean time to first token | 0.941 s | 0.349 s | **-62.93%** |
| Mean queue time | 0.350 s | 0.046 s | **-87.01%** |
| Mean model-request latency | 7.102 s | 4.845 s | **-31.77%** |
| Mean inter-token latency | 46.16 ms | 27.13 ms | **-41.22%** |
| Prefix-cache hit rate | 30.40% | 75.28% | **+44.88 pp** |
| Worker preemptions | 1,342 | 217 | **-83.83%** |

### 3.2 Equal-weight paired-run aggregate

This second view gives each run equal weight instead of allowing runs with more
model requests to dominate the result.

| Metric | Mean paired ThunderAgent improvement | Range across runs | ThunderAgent favored |
|---|---:|---:|---:|
| Mean time to first token | 62.2% lower | 55.9–73.8% lower | 3/3 |
| Mean queue time | 85.9% lower | 80.9–93.3% lower | 3/3 |
| Mean model-request latency | 31.6% lower | 25.7–42.2% lower | 3/3 |
| Mean inter-token latency | 41.0% lower | 35.1–47.4% lower | 3/3 |
| Prefix-cache hit rate | +44.5 pp | +37.3 to +58.9 pp | 3/3 |
| Worker preemptions | 80.9% fewer | 68.9–91.7% fewer | 3/3 |

With three deployment pairs, the range and directional count are more useful
than a narrow confidence interval. Requests within a deployment are correlated
and should not be treated as independent experimental repetitions.

### 3.3 `run1` — ThunderAgent first

| Metric | Dynamo KV-aware baseline | ThunderAgent | Difference |
|---|---:|---:|---:|
| Mean time to first token | 1.197 s | 0.313 s | **-73.81%** |
| Mean queue time | 0.507 s | 0.034 s | **-93.28%** |
| Mean model-request latency | 8.417 s | 4.864 s | **-42.21%** |
| Mean inter-token latency | 49.34 ms | 25.96 ms | **-47.39%** |
| Prefix-cache hit rate | 21.91% | 80.77% | **+58.86 pp** |
| Worker preemptions | 660 | 55 | **-91.67%** |

### 3.4 `run2` — baseline first

| Metric | Dynamo KV-aware baseline | ThunderAgent | Difference |
|---|---:|---:|---:|
| Mean time to first token | 0.866 s | 0.374 s | **-56.77%** |
| Mean queue time | 0.317 s | 0.053 s | **-83.44%** |
| Mean model-request latency | 6.600 s | 4.833 s | **-26.78%** |
| Mean inter-token latency | 43.66 ms | 28.32 ms | **-35.15%** |
| Prefix-cache hit rate | 33.23% | 70.57% | **+37.34 pp** |
| Worker preemptions | 299 | 93 | **-68.90%** |

### 3.5 `run3` — ThunderAgent first

| Metric | Dynamo KV-aware baseline | ThunderAgent | Difference |
|---|---:|---:|---:|
| Mean time to first token | 0.806 s | 0.355 s | **-55.94%** |
| Mean queue time | 0.256 s | 0.049 s | **-80.87%** |
| Mean model-request latency | 6.518 s | 4.841 s | **-25.74%** |
| Mean inter-token latency | 45.64 ms | 27.13 ms | **-40.56%** |
| Prefix-cache hit rate | 38.47% | 75.87% | **+37.40 pp** |
| Worker preemptions | 383 | 69 | **-81.98%** |

### 3.6 ThunderAgent scheduler activity

| Signal | `run1` | `run2` | `run3` | Total |
|---|---:|---:|---:|---:|
| Pressure-trigger ticks | 8 | 9 | 11 | 28 |
| Immediate pause actions | 18 | 10 | 27 | 55 |
| Requests marked for pause | 76 | 105 | 79 | 260 |
| Resume cycles | 41 | 60 | 46 | 147 |
| Resume actions | 109 | 131 | 124 | 364 |

Scheduling activity occurred in every ThunderAgent repetition. Both serving
paths also reached high KV-cache occupancy, confirming that the scheduling
mechanism was exercised under cache pressure.

## 4. Analysis

### 4.1 The serving result repeated across all three runs

ThunderAgent improved all six primary serving metrics in `run1`, `run2`, and
`run3`. The result also held when the execution order was reversed in `run2`,
where the baseline ran first.

The largest repeated change was queue time, which was 80.9–93.3% lower. Mean
time to first token was 55.9–73.8% lower, mean model-request latency was
25.7–42.2% lower, and mean inter-token latency was 35.1–47.4% lower.

Cache behavior moved in the same direction. Prefix-cache hit rate increased by
37.3–58.9 percentage points, while worker preemptions fell by 68.9–91.7%.

### 4.2 Consistency with the original experiment

| Primary metric | Original experiment | Three-run pooled result |
|---|---:|---:|
| Mean TTFT reduction | 62.66% | 62.93% |
| Mean queue-time reduction | 85.55% | 87.01% |
| Mean request-latency reduction | 29.81% | 31.77% |
| Mean ITL reduction | 35.21% | 41.22% |
| Prefix-cache hit-rate increase | +37.53 pp | +44.88 pp |
| Worker-preemption reduction | 78.06% | 83.83% |

The three-run series reproduces the original experiment's direction and
broadly its magnitude. The repeated result is therefore not dependent on one
favorable run.

### 4.3 Scope and limitations

- The arms ran sequentially on the same four H100s rather than simultaneously.
- The task list and task order were fixed, but coding-agent execution did not
  emit identical request traces between arms.
- The pooled result describes the requests observed in these runs; the
  equal-weight paired result describes repeatability across deployments.
- Three pairs establish directional repeatability but are not enough for a
  precise population-effect estimate.
- A router-only effect size requires deterministic replay of the same request
  payloads, arrival schedule, and concurrency against both deployments.

### 4.4 Bottom line

Across three paired repetitions, ThunderAgent consistently improved the same
request-level serving metrics reported in the original experiment. The pooled
result shows 62.93% lower mean TTFT, 87.01% lower mean queue time, 31.77% lower
mean request latency, 41.22% lower mean ITL, a 44.88-point higher prefix-cache
hit rate, and 83.83% fewer worker preemptions.
