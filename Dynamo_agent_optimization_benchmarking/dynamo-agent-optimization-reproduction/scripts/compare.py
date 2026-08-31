#!/usr/bin/env python3
"""Compare strict-goodput summaries without changing experiment evidence."""

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()

    baseline = json.loads(args.baseline.read_text())["metrics"]
    candidate = json.loads(args.candidate.read_text())["metrics"]
    prior = baseline["strict_goodput_rps"]
    current = candidate["strict_goodput_rps"]
    delta_pct = (current - prior) / prior * 100
    fraction_pp = (
        candidate["strict_good_request_fraction"]
        - baseline["strict_good_request_fraction"]
    ) * 100

    result = {
        "baseline_strict_goodput_rps": prior,
        "candidate_strict_goodput_rps": current,
        "strict_goodput_delta_percent": delta_pct,
        "strict_good_fraction_delta_percentage_points": fraction_pp,
        "baseline_errors": baseline["error_count"],
        "candidate_errors": candidate["error_count"],
        "candidate_is_zero_error_improvement": (
            candidate["error_count"] == 0 and current > prior
        ),
    }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
