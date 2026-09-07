#!/usr/bin/env python3
"""Summarize native vLLM metrics for the repeated three-run experiment.

Every value is computed as the post-run Prometheus snapshot minus the
post-warm snapshot, summed over the two vLLM workers. Classic histogram
quantiles use Prometheus-style linear interpolation within buckets.
"""

from __future__ import annotations

import csv
import json
import math
import re
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts" / "fresh-ordered-v1"
ARMS_CSV = ROOT / "protocol" / "fresh-ordered-v1-arms.csv"

SAMPLE_RE = re.compile(
    r'^(?P<metric>[^\s{]+)(?:\{(?P<labels>.*)\})?\s+'
    r'(?P<value>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?|[-+]?Inf|NaN)$'
)
LABEL_RE = re.compile(r'(\w+)="((?:\\.|[^"\\])*)"')

COUNTERS = (
    "vllm:request_success_total",
    "vllm:prompt_tokens_total",
    "vllm:prompt_tokens_cached_total",
    "vllm:generation_tokens_total",
    "vllm:prefix_cache_queries_total",
    "vllm:prefix_cache_hits_total",
    "vllm:num_preemptions_total",
    "dynamo_component_errors_total",
    "dynamo_component_cancellation_total",
    "dynamo_rejection_request_total",
    "dynamo_work_handler_enqueue_rejected_total",
)

HISTOGRAMS = (
    "vllm:request_prompt_tokens",
    "vllm:request_generation_tokens",
    "vllm:request_prefill_kv_computed_tokens",
    "vllm:time_to_first_token_seconds",
    "vllm:inter_token_latency_seconds",
    "vllm:request_time_per_output_token_seconds",
    "vllm:e2e_request_latency_seconds",
    "vllm:request_queue_time_seconds",
)


def parse_prom(path: Path) -> dict[str, list[tuple[dict[str, str], float]]]:
    samples: dict[str, list[tuple[dict[str, str], float]]] = defaultdict(list)
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        match = SAMPLE_RE.match(line)
        if not match:
            continue
        labels = {
            key: bytes(value, "utf-8").decode("unicode_escape")
            for key, value in LABEL_RE.findall(match.group("labels") or "")
        }
        samples[match.group("metric")].append((labels, float(match.group("value"))))
    return samples


def label_key(labels: dict[str, str]) -> tuple[tuple[str, str], ...]:
    return tuple(sorted(labels.items()))


def values_by_labels(
    samples: dict[str, list[tuple[dict[str, str], float]]], metric: str
) -> dict[tuple[tuple[str, str], ...], float]:
    return {label_key(labels): value for labels, value in samples.get(metric, [])}


def metric_delta(
    start: dict[str, list[tuple[dict[str, str], float]]],
    end: dict[str, list[tuple[dict[str, str], float]]],
    metric: str,
) -> list[tuple[dict[str, str], float]]:
    start_values = values_by_labels(start, metric)
    deltas: list[tuple[dict[str, str], float]] = []
    for labels, value in end.get(metric, []):
        key = label_key(labels)
        delta = value - start_values.get(key, 0.0)
        if delta < -1e-9:
            raise ValueError(f"counter decreased for {metric} in labels {labels}")
        deltas.append((labels, delta))
    return deltas


def histogram_quantile(buckets: dict[float, float], quantile: float) -> float:
    ordered = sorted(buckets.items())
    if not ordered or not math.isinf(ordered[-1][0]):
        return math.nan
    total = ordered[-1][1]
    if total <= 0:
        return math.nan
    rank = quantile * total
    previous_upper = 0.0
    previous_count = 0.0
    for index, (upper, cumulative) in enumerate(ordered):
        if cumulative < rank:
            if math.isfinite(upper):
                previous_upper = upper
            previous_count = cumulative
            continue
        if math.isinf(upper):
            return ordered[index - 1][0] if index else math.nan
        in_bucket = cumulative - previous_count
        if in_bucket <= 0:
            return upper
        return previous_upper + (upper - previous_upper) * (
            (rank - previous_count) / in_bucket
        )
    return math.nan


def percentile(values: list[float], q: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def load_arm_windows() -> dict[tuple[str, str], tuple[datetime, datetime, float]]:
    windows = {}
    with ARMS_CSV.open(newline="") as handle:
        for row in csv.DictReader(handle):
            start = datetime.fromisoformat(row["started_at_utc"].replace("Z", "+00:00"))
            end = datetime.fromisoformat(row["finished_at_utc"].replace("Z", "+00:00"))
            windows[(row["run_id"], row["arm"])] = (start, end, (end - start).total_seconds())
    return windows


def telemetry_summary(path: Path, start: datetime, end: datetime) -> dict[str, float]:
    by_timestamp: dict[datetime, list[dict[str, str]]] = defaultdict(list)
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            timestamp = datetime.fromisoformat(row["timestamp_utc"].replace("Z", "+00:00"))
            if start <= timestamp <= end:
                by_timestamp[timestamp].append(row)

    mean_kv: list[float] = []
    running: list[float] = []
    waiting: list[float] = []
    for rows in by_timestamp.values():
        mean_kv.append(statistics.fmean(float(row["kv_cache_usage"]) for row in rows))
        running.append(sum(float(row["requests_running"]) for row in rows))
        waiting.append(sum(float(row["requests_waiting"]) for row in rows))
    return {
        "telemetry_samples": len(by_timestamp),
        "kv_usage_mean": statistics.fmean(mean_kv) if mean_kv else math.nan,
        "kv_usage_p95": percentile(mean_kv, 0.95),
        "kv_usage_max": max(mean_kv, default=math.nan),
        "running_p95": percentile(running, 0.95),
        "running_max": max(running, default=math.nan),
        "waiting_p95": percentile(waiting, 0.95),
        "waiting_max": max(waiting, default=math.nan),
    }


def scheduler_summary(arm_root: Path) -> dict[str, int]:
    paths = list((arm_root / "post-run").rglob("*thunderagentrouter*.log"))
    if len(paths) != 1:
        raise ValueError(f"expected one ThunderAgent router log under {arm_root}")
    pause_ticks = 0
    immediate_pauses = 0
    marked_for_pause = 0
    resume_cycles = 0
    resume_actions = 0
    for line in paths[0].read_text(errors="replace").splitlines():
        if "router._pause_until_safe" in line:
            match = re.search(r"paused=(\d+) marked=(\d+)", line)
            if match:
                pause_ticks += 1
                immediate_pauses += int(match.group(1))
                marked_for_pause += int(match.group(2))
        if "router._greedy_resume" in line:
            match = re.search(r"resumed=(\d+)", line)
            if match:
                resume_cycles += 1
                resume_actions += int(match.group(1))
    return {
        "pressure_trigger_ticks": pause_ticks,
        "immediate_pause_actions": immediate_pauses,
        "requests_marked_for_pause": marked_for_pause,
        "resume_cycles": resume_cycles,
        "resume_actions": resume_actions,
    }


def arm_summary(run_id: str, arm: str, duration: float, start: datetime, end: datetime) -> dict:
    arm_root = ARTIFACTS / run_id / arm
    post_warm_paths = sorted((arm_root / "post-warm").glob("*vllmdecodeworker*.prom"))
    post_run_paths = sorted((arm_root / "post-run").glob("*vllmdecodeworker*.prom"))
    if len(post_warm_paths) != 2 or len(post_run_paths) != 2:
        raise ValueError(f"expected two worker snapshots for {run_id}/{arm}")

    starts = {path.name: parse_prom(path) for path in post_warm_paths}
    ends = {path.name: parse_prom(path) for path in post_run_paths}
    if starts.keys() != ends.keys():
        raise ValueError(f"worker snapshot names differ for {run_id}/{arm}")

    summary: dict[str, object] = {
        "run_id": run_id,
        "arm": arm,
        "duration_seconds": duration,
    }

    grouped_counter_deltas: dict[str, dict[str, float]] = {}
    for metric in COUNTERS:
        grouped: dict[str, float] = defaultdict(float)
        for name in starts:
            for labels, delta in metric_delta(starts[name], ends[name], metric):
                group = labels.get("finished_reason", "total")
                grouped[group] += delta
        grouped_counter_deltas[metric] = dict(grouped)

    completed_by_reason = grouped_counter_deltas["vllm:request_success_total"]
    requests = sum(completed_by_reason.values())
    prompt_tokens = grouped_counter_deltas["vllm:prompt_tokens_total"].get("total", 0.0)
    cached_tokens = grouped_counter_deltas["vllm:prompt_tokens_cached_total"].get("total", 0.0)
    generation_tokens = grouped_counter_deltas["vllm:generation_tokens_total"].get("total", 0.0)
    prefix_queries = grouped_counter_deltas["vllm:prefix_cache_queries_total"].get("total", 0.0)
    prefix_hits = grouped_counter_deltas["vllm:prefix_cache_hits_total"].get("total", 0.0)
    preemptions = grouped_counter_deltas["vllm:num_preemptions_total"].get("total", 0.0)

    summary.update(
        {
            "requests": requests,
            "completed_by_reason": completed_by_reason,
            "prompt_tokens": prompt_tokens,
            "cached_prompt_tokens": cached_tokens,
            "generation_tokens": generation_tokens,
            "prefix_queries": prefix_queries,
            "prefix_hits": prefix_hits,
            "prefix_hit_rate": prefix_hits / prefix_queries if prefix_queries else math.nan,
            "cached_prompt_fraction": cached_tokens / prompt_tokens if prompt_tokens else math.nan,
            "preemptions": preemptions,
            "preemptions_per_1k_requests": 1000.0 * preemptions / requests if requests else math.nan,
            "preemptions_per_m_prompt_tokens": 1e6 * preemptions / prompt_tokens if prompt_tokens else math.nan,
            "requests_per_second_e2e": requests / duration,
            "prompt_tokens_per_second_e2e": prompt_tokens / duration,
            "generation_tokens_per_second_e2e": generation_tokens / duration,
        }
    )

    summary["serving_failures"] = {
        metric: grouped_counter_deltas[metric].get("total", 0.0)
        for metric in (
            "dynamo_component_errors_total",
            "dynamo_component_cancellation_total",
            "dynamo_rejection_request_total",
            "dynamo_work_handler_enqueue_rejected_total",
        )
    }

    histograms: dict[str, dict[str, float]] = {}
    for base in HISTOGRAMS:
        aggregate_buckets: dict[float, float] = defaultdict(float)
        total_sum = 0.0
        total_count = 0.0
        for name in starts:
            for labels, delta in metric_delta(starts[name], ends[name], f"{base}_bucket"):
                upper = float(labels["le"])
                aggregate_buckets[upper] += delta
            total_sum += sum(delta for _, delta in metric_delta(starts[name], ends[name], f"{base}_sum"))
            total_count += sum(delta for _, delta in metric_delta(starts[name], ends[name], f"{base}_count"))
        histograms[base] = {
            "count": total_count,
            "mean": total_sum / total_count if total_count else math.nan,
            "p50": histogram_quantile(aggregate_buckets, 0.50),
            "p95": histogram_quantile(aggregate_buckets, 0.95),
            "p99": histogram_quantile(aggregate_buckets, 0.99),
        }
    summary["histograms"] = histograms

    telemetry_paths = list(arm_root.glob("cluster*/serving-telemetry.csv"))
    if len(telemetry_paths) != 1:
        raise ValueError(f"expected one serving telemetry file for {run_id}/{arm}")
    summary["telemetry"] = telemetry_summary(telemetry_paths[0], start, end)
    if arm == "thunderagent":
        summary["scheduler"] = scheduler_summary(arm_root)
    return summary


def aggregate_arm(run_summaries: list[dict], arm: str) -> dict:
    runs = [item for item in run_summaries if item["arm"] == arm]
    result: dict[str, object] = {"arm": arm, "run_count": len(runs)}
    for field in (
        "duration_seconds",
        "requests",
        "prompt_tokens",
        "cached_prompt_tokens",
        "generation_tokens",
        "prefix_queries",
        "prefix_hits",
        "preemptions",
    ):
        result[field] = sum(float(run[field]) for run in runs)

    result["prefix_hit_rate"] = result["prefix_hits"] / result["prefix_queries"]
    result["cached_prompt_fraction"] = result["cached_prompt_tokens"] / result["prompt_tokens"]
    result["preemptions_per_1k_requests"] = 1000.0 * result["preemptions"] / result["requests"]
    result["preemptions_per_m_prompt_tokens"] = 1e6 * result["preemptions"] / result["prompt_tokens"]
    result["requests_per_second_e2e"] = result["requests"] / result["duration_seconds"]
    result["prompt_tokens_per_second_e2e"] = result["prompt_tokens"] / result["duration_seconds"]
    result["generation_tokens_per_second_e2e"] = result["generation_tokens"] / result["duration_seconds"]

    completed_by_reason: dict[str, float] = defaultdict(float)
    serving_failures: dict[str, float] = defaultdict(float)
    for run in runs:
        for key, value in run["completed_by_reason"].items():
            completed_by_reason[key] += value
        for key, value in run["serving_failures"].items():
            serving_failures[key] += value
    result["completed_by_reason"] = dict(completed_by_reason)
    result["serving_failures"] = dict(serving_failures)

    if arm == "thunderagent":
        scheduler: dict[str, int] = defaultdict(int)
        for run in runs:
            for key, value in run["scheduler"].items():
                scheduler[key] += value
        result["scheduler"] = dict(scheduler)

    # Aggregate classic histogram deltas again by weighting exact means by count.
    # Quantiles cannot be combined from already-computed quantiles, so recompute
    # directly from all six worker snapshot pairs for this arm.
    aggregate_histograms: dict[str, dict[str, float]] = {}
    for base in HISTOGRAMS:
        buckets: dict[float, float] = defaultdict(float)
        total_sum = 0.0
        total_count = 0.0
        for run in runs:
            arm_root = ARTIFACTS / run["run_id"] / arm
            start_paths = {p.name: parse_prom(p) for p in (arm_root / "post-warm").glob("*vllmdecodeworker*.prom")}
            end_paths = {p.name: parse_prom(p) for p in (arm_root / "post-run").glob("*vllmdecodeworker*.prom")}
            for name in start_paths:
                for labels, delta in metric_delta(start_paths[name], end_paths[name], f"{base}_bucket"):
                    buckets[float(labels["le"])] += delta
                total_sum += sum(delta for _, delta in metric_delta(start_paths[name], end_paths[name], f"{base}_sum"))
                total_count += sum(delta for _, delta in metric_delta(start_paths[name], end_paths[name], f"{base}_count"))
        aggregate_histograms[base] = {
            "count": total_count,
            "mean": total_sum / total_count if total_count else math.nan,
            "p50": histogram_quantile(buckets, 0.50),
            "p95": histogram_quantile(buckets, 0.95),
            "p99": histogram_quantile(buckets, 0.99),
        }
    result["histograms"] = aggregate_histograms

    for field in (
        "kv_usage_mean",
        "kv_usage_p95",
        "kv_usage_max",
        "running_p95",
        "running_max",
        "waiting_p95",
        "waiting_max",
    ):
        values = [float(run["telemetry"][field]) for run in runs]
        result[f"run_{field}_median"] = statistics.median(values)
        result[f"run_{field}_range"] = [min(values), max(values)]
    return result


def main() -> None:
    windows = load_arm_windows()
    run_summaries = []
    for run_id in ("fresh-001", "fresh-002", "fresh-003"):
        for arm in ("thunderagent", "baseline"):
            start, end, duration = windows[(run_id, arm)]
            run_summaries.append(arm_summary(run_id, arm, duration, start, end))

    aggregates = {
        arm: aggregate_arm(run_summaries, arm)
        for arm in ("thunderagent", "baseline")
    }
    print(json.dumps({"runs": run_summaries, "aggregate": aggregates}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
