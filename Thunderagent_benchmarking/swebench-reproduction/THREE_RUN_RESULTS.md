# Three-run repeated-study results

Status: complete. All six arms ran on 2026-09-02--03 UTC and passed their
90-task admission-order, post-run driver-clean, artifact-hash, and teardown
gates.

## Frozen design

- Three paired runs per arm in the fixed order `TA, baseline, baseline, TA, TA,
  baseline`.
- Ninety tasks per arm in an identical first-attempt order; one attempt and no
  retry; concurrency 32; 3,000-second agent timeout.
- The same pinned model revision and four H100s for every arm.
- A new deployment and new serving pods for every arm, with zero pre-warm vLLM
  counters and zero pod restarts at launch.
- The same excluded warm-up for every arm: 8/8 successful requests, split 4/4,
  176 prompt tokens, followed by quiescence before measurement.
- Full serving teardown and driver-clean checks between arms. Node-local model
  and Harbor Docker caches were retained consistently; no model cache was
  deleted.

The frozen task-list SHA-256 is
`397a87f516967776db4fe382c1abf78266c145316eedb0a8373a361868e6b2b7`.
The complete arm order and artifact roots are in the
[arm ledger](protocol/fresh-ordered-v1-arms.csv).

## Run-level outcomes

| Run | Arm | Resolved | Unresolved | Errors | Duration (s) | Final vLLM preemptions |
|---|---|---:|---:|---|---:|---:|
| `run1` | ThunderAgent | 55 | 31 | 4 agent timeouts | 4,634 | 55 |
| `run1` | baseline | 58 | 29 | 3 agent timeouts | 5,405 | 660 |
| `run2` | baseline | 50 | 34 | 6 agent timeouts | 5,075 | 299 |
| `run2` | ThunderAgent | 60 | 28 | 1 agent timeout; 1 reward-file error | 3,382 | 93 |
| `run3` | ThunderAgent | 56 | 31 | 3 agent timeouts | 3,274 | 69 |
| `run3` | baseline | 51 | 36 | 3 agent timeouts | 5,241 | 383 |

Resolved, unresolved, and errors sum to 90 for every arm. Durations are
recorded for audit but are secondary because they include agent, local setup,
verification, and orchestration time in addition to model serving.

`Final vLLM preemptions` is the sum of the two workers' native
`vllm:num_preemptions_total` counters in the terminal snapshot. Each deployment
started with new workers and zero pre-warm preemptions; the fixed warm-up did
not produce a preemption in any arm.

## Primary comparison

The primary ThunderAgent-versus-baseline result is the complete repeated-study
report in
[`../thunderagent-final-swebench-three-run-report.md`](../thunderagent-final-swebench-three-run-report.md),
with calculation details in
[`THREE_RUN_SERVING_METRICS.md`](THREE_RUN_SERVING_METRICS.md).
It compares native vLLM TTFT, TPOT/ITL, request and queue latency, KV/prefix
reuse, new KV work, preemptions, throughput, and serving failures, with the
fixed warm-up excluded.

The serving metrics descriptively favor ThunderAgent in all three pairs, but
the model-request traces differed between arms despite the fixed task order.
The document therefore does not claim a causal router-only effect; that
requires deterministic replay of identical request traces.

## Secondary task-outcome audit

SWE-bench resolution is retained only as an experiment and artifact audit. It
is not evidence that a router changed model quality and is not part of the
primary ThunderAgent-versus-KV-router comparison.

| Outcome | ThunderAgent | Baseline |
|---|---:|---:|
| Resolved | 171/270 (63.33%) | 159/270 (58.89%) |
| `AgentTimeoutError` | 8 | 12 |

## Error audit

- ThunderAgent `run2` had one `RewardFileNotFoundError` on
  `scikit-learn__scikit-learn-25747`. The task transcript records the agent
  executing `mv /testbed /testbed_src`; the verifier then could not enter its
  fixed `/testbed/` working directory and produced no reward file. The result
  was retained without retry or workload change.
- All other errors in this series were `AgentTimeoutError`; no verifier timeout
  was recorded.
- The replacement task `django__django-13089` completed normally in every arm.
  Its rewards by arm order were ThunderAgent `0`, baseline `1`, baseline `1`,
  ThunderAgent `1`, ThunderAgent `1`, baseline `0`.

This is a separate experiment because the removed task was selected using
outcomes from the prior series. These results must not be pooled with the
earlier series as if all runs shared one frozen design.
