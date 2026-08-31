# Results

## Winner

The best configuration retained eight TP1 workers, FP8 weights and KV cache, 131,072-token context, block size 64, GPU memory utilization 0.90, async scheduling, and KV-aware routing. Its sole change from baseline was:

```text
max_num_batched_tokens: 8192 -> 4096
```

It produced 1.7523235 strict-good requests/s (2,131 of 5,775), a 25.17% improvement over baseline, with zero errors. Average TTFT fell 27.50%, average ITL 43.17%, and average request latency 23.68%.

## Search Record

| Candidate | Outcome | Interpretation |
|---|---|---|
| Batched tokens `8192 -> 4096` | +25.17%; promoted | The lower scheduling budget materially improved latency-SLO attainment. |
| Router decay `0 -> 1.0` | −11.81%; rejected | Better worker balance did not compensate for lost useful locality. |
| GPU memory `0.90 -> 0.95` | two-run mean −0.20%; rejected | More KV blocks did not improve the primary objective. |
| Batched tokens `4096 -> 3072` | reviewed, unmeasured | A valid next scheduler candidate, not a result. |

Machine-readable aggregate evidence is in [`reference-results.json`](../results/reference-results.json). Absolute performance is environment-dependent; reproduce the within-cluster comparison.

The 4,096-token winner is conclusive for the measured series. TP2 topology, FlashInfer attention, native CPU KV offload, and the 3,072-token candidate remain open families.
