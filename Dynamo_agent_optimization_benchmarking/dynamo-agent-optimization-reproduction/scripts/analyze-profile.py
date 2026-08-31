#!/usr/bin/env python3
"""Audit an AIPerf profile export and compute strict goodput."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from typing import Any


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * pct / 100.0
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] * (high - position) + ordered[high] * (position - low)


def stats(values: list[float]) -> dict[str, float | int | None]:
    return {
        "count": len(values),
        "average": statistics.fmean(values) if values else None,
        "minimum": min(values) if values else None,
        "p50": percentile(values, 50),
        "p90": percentile(values, 90),
        "p95": percentile(values, 95),
        "p99": percentile(values, 99),
        "maximum": max(values) if values else None,
        "standard_deviation": statistics.pstdev(values) if values else None,
    }


def metric(record: dict[str, Any], name: str) -> float | None:
    item = record.get("metrics", {}).get(name)
    if not isinstance(item, dict):
        return None
    value = item.get("value")
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    return None


def metric_values(records: list[dict[str, Any]], name: str) -> list[float]:
    values = [metric(record, name) for record in records]
    return [value for value in values if value is not None]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def analyze(
    profile: Path,
    expected_requests: int,
    ttft_ms: float,
    itl_ms: float,
    gpu_count: int,
) -> dict[str, Any]:
    records = [json.loads(line) for line in profile.read_text().splitlines() if line.strip()]
    if not records:
        raise ValueError("profile contains no records")
    if expected_requests and len(records) != expected_requests:
        raise ValueError(f"expected {expected_requests} records, found {len(records)}")

    sessions = [record.get("metadata", {}).get("session_num") for record in records]
    request_ids = [record.get("metadata", {}).get("x_request_id") for record in records]
    if None in sessions or len(set(sessions)) != len(records):
        raise ValueError("session numbers are missing or duplicated")
    if None in request_ids or len(set(request_ids)) != len(records):
        raise ValueError("request IDs are missing or duplicated")

    starts: list[int] = []
    ends: list[int] = []
    error_count = 0
    strict_good = 0
    ttft_pass = 0
    itl_pass = 0
    threshold_equalities = 0

    for record in records:
        metadata = record.get("metadata", {})
        trace_data = record.get("trace_data", {})
        start = metadata.get("request_start_ns")
        end = metadata.get("request_end_ns")
        if not isinstance(start, int) or not isinstance(end, int) or end < start:
            raise ValueError("invalid request timing")
        starts.append(start)
        ends.append(end)

        status = trace_data.get("response_status_code")
        cancelled = bool(metadata.get("was_cancelled"))
        successful = status == 200 and not cancelled
        if not successful:
            error_count += 1

        ttft = metric(record, "time_to_first_token")
        itl = metric(record, "inter_token_latency")
        if ttft == ttft_ms or itl == itl_ms:
            threshold_equalities += 1
        if successful and ttft is not None and ttft < ttft_ms:
            ttft_pass += 1
        if successful and itl is not None and itl < itl_ms:
            itl_pass += 1
        if (
            successful
            and ttft is not None
            and ttft < ttft_ms
            and itl is not None
            and itl < itl_ms
        ):
            strict_good += 1

    duration_seconds = (max(ends) - min(starts)) / 1e9
    if duration_seconds <= 0:
        raise ValueError("benchmark duration must be positive")

    output_tokens = sum(metric_values(records, "output_sequence_length"))
    strict_goodput = strict_good / duration_seconds
    request_throughput = len(records) / duration_seconds
    output_throughput = output_tokens / duration_seconds

    return {
        "schema_version": 1,
        "source": {
            "profile": profile.name,
            "sha256": sha256(profile),
        },
        "integrity": {
            "record_count": len(records),
            "unique_sessions": len(set(sessions)),
            "unique_request_ids": len(set(request_ids)),
            "terminal_newline": profile.read_bytes().endswith(b"\n"),
        },
        "thresholds": {
            "time_to_first_token_ms": {"operator": "<", "value": ttft_ms},
            "inter_token_latency_ms": {"operator": "<", "value": itl_ms},
        },
        "metrics": {
            "benchmark_duration_seconds": duration_seconds,
            "request_count": len(records),
            "error_count": error_count,
            "strict_good_request_count": strict_good,
            "strict_good_request_fraction": strict_good / len(records),
            "strict_goodput_rps": strict_goodput,
            "request_throughput_rps": request_throughput,
            "output_token_count": int(output_tokens),
            "output_token_throughput_tokens_per_second": output_throughput,
            "output_token_throughput_per_gpu": output_throughput / gpu_count,
            "ttft_strict_pass_count": ttft_pass,
            "itl_strict_pass_count": itl_pass,
            "threshold_equality_count": threshold_equalities,
            "time_to_first_token_ms": stats(metric_values(records, "time_to_first_token")),
            "inter_token_latency_ms": stats(metric_values(records, "inter_token_latency")),
            "request_latency_ms": stats(metric_values(records, "request_latency")),
            "input_sequence_length_tokens": stats(metric_values(records, "input_sequence_length")),
            "output_sequence_length_tokens": stats(metric_values(records, "output_sequence_length")),
        },
    }


def write_markdown(result: dict[str, Any], path: Path) -> None:
    metrics = result["metrics"]
    thresholds = result["thresholds"]
    text = f"""# Strict Goodput Audit

- Records: {metrics['request_count']}
- Errors: {metrics['error_count']}
- Duration: {metrics['benchmark_duration_seconds']:.3f} seconds
- Strict-good requests: {metrics['strict_good_request_count']}
- Strict-good fraction: {metrics['strict_good_request_fraction']:.6f}
- Strict goodput: **{metrics['strict_goodput_rps']:.6f} requests/s**
- Request throughput: {metrics['request_throughput_rps']:.6f} requests/s
- Output throughput: {metrics['output_token_throughput_tokens_per_second']:.3f} tokens/s
- Thresholds: TTFT {thresholds['time_to_first_token_ms']['operator']} {thresholds['time_to_first_token_ms']['value']} ms and ITL {thresholds['inter_token_latency_ms']['operator']} {thresholds['inter_token_latency_ms']['value']} ms
"""
    path.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", type=Path)
    parser.add_argument("--output", type=Path, default=Path("strict-summary.json"))
    parser.add_argument("--expected-requests", type=int, default=5775)
    parser.add_argument("--ttft-ms", type=float, default=5000)
    parser.add_argument("--itl-ms", type=float, default=100)
    parser.add_argument("--gpu-count", type=int, default=8)
    args = parser.parse_args()

    result = analyze(
        args.profile,
        expected_requests=args.expected_requests,
        ttft_ms=args.ttft_ms,
        itl_ms=args.itl_ms,
        gpu_count=args.gpu_count,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    write_markdown(result, args.output.with_suffix(".md"))
    print(json.dumps(result["metrics"], indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
