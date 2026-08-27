#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import math
from collections import Counter, defaultdict

from datasets import load_dataset


def stable_rank(seed: str, purpose: str, value: str) -> bytes:
    return hashlib.sha256(f"{seed}\0{purpose}\0{value}".encode()).digest()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print a deterministic repository-proportional SWE-bench sample."
    )
    parser.add_argument("--dataset-revision", required=True)
    parser.add_argument("--tasks", type=int, required=True)
    parser.add_argument("--seed", required=True)
    args = parser.parse_args()

    dataset = load_dataset(
        "princeton-nlp/SWE-bench_Verified",
        split="test",
        revision=args.dataset_revision,
    )
    by_repo: dict[str, list[str]] = defaultdict(list)
    for row in dataset:
        by_repo[row["repo"]].append(row["instance_id"])

    if not 0 < args.tasks <= len(dataset):
        raise SystemExit(f"--tasks must be between 1 and {len(dataset)}")

    counts = Counter({repo: len(ids) for repo, ids in by_repo.items()})
    quotas = {repo: args.tasks * count / len(dataset) for repo, count in counts.items()}
    allocation = {repo: math.floor(quota) for repo, quota in quotas.items()}
    remaining = args.tasks - sum(allocation.values())
    remainder_order = sorted(
        counts,
        key=lambda repo: (-(quotas[repo] - allocation[repo]), repo),
    )
    for repo in remainder_order[:remaining]:
        allocation[repo] += 1

    selected: list[str] = []
    for repo in sorted(by_repo):
        ranked = sorted(
            by_repo[repo],
            key=lambda instance_id: stable_rank(args.seed, "select", instance_id),
        )
        selected.extend(ranked[: allocation[repo]])

    selected.sort(key=lambda instance_id: stable_rank(args.seed, "order", instance_id))
    if len(selected) != args.tasks or len(set(selected)) != args.tasks:
        raise SystemExit("Selection did not produce the requested number of unique tasks")

    print("# Deterministic repository-proportional sample from SWE-bench Verified.")
    print(f"# revision={args.dataset_revision} tasks={args.tasks} seed={args.seed}")
    for instance_id in selected:
        print(instance_id)


if __name__ == "__main__":
    main()
