# ThunderAgent Program-Aware Scheduling Evaluation — SWE-bench Throughput Study

## 1. Goal

Evaluate whether ThunderAgent's program-aware pause/resume scheduling improves the performance of a realistic coding-agent workload under KV-cache pressure.

The comparison uses the same model, tasks, task order, serving capacity, and client concurrency for both approaches:

- **Dynamo KV-aware routing:** the baseline, using Dynamo's KV-aware router.
- **ThunderAgent:** the same KV-aware routing base with program-aware pause/resume scheduling enabled.

The primary metrics are workload throughput and goodput. Request-level latency, cache utilization, preemptions, and task outcomes are used to explain the observed workload-level result.

## 3. Setup

### 3.1 Workload

| Item | Configuration |
|---|---|
| Benchmark | SWE-bench Verified |
| Agent harness | Pi through Harbor |
| Tasks | 90 unique tasks |
| Sampling | Deterministic, repository-proportional sample preserving the repository mix of SWE-bench Verified |
| Task order | Identical for both approaches |
| Client concurrency | 32 |
| Per-task client resources | 2 vCPUs and 8 GiB memory |
| Task timeout | 3,000 seconds |

The 90 tasks were selected without repetition. Repository-proportional sampling was used so that increasing the sample size did not disproportionately favor repositories with only a small number of tasks in the full benchmark.

### 3.2 Model and serving topology

| Item | Configuration |
|---|---|
| Model | Qwen/Qwen3-Coder-Next |
| Precision | BF16 |
| Maximum model context | 65,536 tokens |
| GPU memory utilization limit | 90% |
| Replicas per approach | 2 |
| Tensor parallelism per replica | 2 |
| GPUs per approach | 4 H100 NVL GPUs |
| Total GPUs | 8 H100 NVL GPUs |
| Execution | Both approaches ran simultaneously on separate GPU and client resources |

Each approach used two independent model replicas, with every replica tensor-parallel across two GPUs. This preserved equal serving capacity while allowing KV-cache pressure to develop naturally at 90% GPU memory utilization.

### 3.3 Metrics

- **Throughput** = reported tasks / elapsed wall-clock hours.
- **Goodput** = successfully completed tasks / elapsed wall-clock hours.
- **Successful task** = the agent run completed without an infrastructure or agent timeout. A successful task can still produce an incorrect patch.
- **Error** = the task did not complete normally, such as an agent timeout. Benchmark correctness is reported separately.

## 4. Results

### 4.1 Workload throughput and goodput

| Metric | Dynamo KV-aware routing | ThunderAgent | Difference |
|---|---:|---:|---:|
| Total tasks reported | 89 | 89 | — |
| Successful tasks | 79 | 88 | +9 |
| Errors | 10 | 1 | -9 |
| Error rate | 11.24% | 1.12% | -10.12 percentage points |
| Total wall-clock time | 107.51 min | 56.00 min | -47.91% |
| Throughput | 49.67 tasks/hour | 95.35 tasks/hour | **+91.98%** |
| Goodput | 44.09 successful tasks/hour | 94.28 successful tasks/hour | **+113.85%** |

*Both approaches executed the same 90 tasks. `scikit-learn__scikit-learn-14710` encountered a Harbor verifier timeout in both runs and is excluded from the comparative results above. The ten baseline errors and one ThunderAgent error were agent timeouts exceeding 3,000 seconds; they remain included in the 89-task comparison. Elapsed time begins when the last excluded task terminal finished, so the table measures the same 89-task cohort in both approaches.*

### 4.2 Request-level serving performance

| Metric | Dynamo KV-aware routing | ThunderAgent | Difference |
|---|---:|---:|---:|
| Mean time to first token | 0.982 s | 0.367 s | **-62.66%** |
| Mean queue time | 0.431 s | 0.062 s | **-85.55%** |
| Mean request latency | 6.668 s | 4.680 s | **-29.81%** |
| Mean inter-token latency | 44.14 ms | 28.59 ms | **-35.21%** |
| Prefix-cache hit rate | 29.15% | 66.68% | **+37.53 percentage points** |
| Worker preemptions | 433 | 95 | **-78.06%** |

*Request-level metrics are aggregate serving telemetry from the full 90-task execution. They cannot be cleanly separated for the single verifier-excluded task and therefore support mechanism analysis rather than the adjusted 89-task throughput calculation.*

### 4.3 Task duration and benchmark outcomes

| Metric | Dynamo KV-aware routing | ThunderAgent | Difference |
|---|---:|---:|---:|
| Median completed-task duration | 58.19 min | 34.08 min | -41.43% |
| P95 completed-task duration | 88.38 min | 50.15 min | -43.25% |
| SWE-bench tasks passed | 52 | 54 | +2 |

The pass counts measure patch correctness, while goodput measures reliable task completion. ThunderAgent's principal benefit in this experiment is higher serving efficiency and fewer timeouts, not a demonstrated improvement in model reasoning quality.

### 4.4 ThunderAgent scheduler activity

| Signal | Observed value |
|---|---:|
| Scheduler pressure threshold | 15 |
| Immediate pause actions | 35 |
| Requests marked for pause | 111 |
| Resume cycles | 91 |
| Resume actions | 186 |

Pause and resume activity occurred throughout the run. Both serving paths reached high KV-cache utilization, but there were no worker restarts, client-host swap events, or infrastructure-capacity guard failures.

## 5. Analysis

### 5.1 The workload created real KV-cache pressure

This experiment allowed the serving engine to use up to 90% of GPU memory and created pressure through concurrent, long-running coding-agent sessions rather than through an artificially small KV-cache allocation. The observed pause/resume actions confirm that ThunderAgent's scheduling mechanism was exercised under the workload.

### 5.2 ThunderAgent materially increased workload throughput

ThunderAgent completed the comparable 89-task cohort in 56.00 minutes, versus 107.51 minutes for KV-aware routing. This corresponds to a 91.98% throughput improvement.

The request-level measurements are consistent with that workload result: ThunderAgent reduced mean queue time by 85.55%, time to first token by 62.66%, and request latency by 29.81%.

### 5.3 The larger improvement was in useful completed work

The baseline encountered ten agent timeouts, while ThunderAgent encountered one. Because timed-out tasks consumed serving time without completing normally, goodput improved by 113.85%, more than the raw throughput improvement.

This is not an artifact of comparing different task counts. Both rates use the same 89 reported tasks; successful-task count affects only goodput.

### 5.4 Cache reuse and lower preemption pressure explain the direction of the result

ThunderAgent increased the prefix-cache hit rate from 29.15% to 66.68% and reduced worker preemptions from 433 to 95. Together with the recorded pause/resume activity, these measurements indicate that program-aware scheduling preserved useful agent state and avoided a substantial amount of recomputation under pressure.

### 5.5 Scope and limitations

- This is one simultaneous comparison using one model, one 90-task sample, and one concurrency level.
- The shared Harbor verifier timeout is excluded symmetrically because it does not measure either serving approach.
- The experiment demonstrates a large performance and reliability improvement for this workload, but repeated trials are needed to quantify run-to-run variance.
- The two-task difference in SWE-bench pass count is too small to support a claim that scheduling changed model quality.
