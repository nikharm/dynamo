#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a pinned SWE-bench Harbor dataset from an ID manifest."
    )
    parser.add_argument("--harbor-dir", type=Path, required=True)
    parser.add_argument("--ids", type=Path, required=True)
    parser.add_argument("--dataset-revision", required=True)
    parser.add_argument("--timeout-seconds", type=float, required=True)
    args = parser.parse_args()

    harbor_dir = args.harbor_dir.resolve()
    adapter_dir = harbor_dir / "adapters" / "swebench"
    output_dir = harbor_dir / "datasets" / "swebench"
    sys.path.insert(0, str(adapter_dir))

    import adapter as adapter_module  # noqa: PLC0415

    unpinned_load_dataset = adapter_module.load_dataset

    def load_pinned_dataset(path: str, *load_args: object, **load_kwargs: object):
        load_kwargs["revision"] = args.dataset_revision
        return unpinned_load_dataset(path, *load_args, **load_kwargs)

    adapter_module.load_dataset = load_pinned_dataset
    converter_class = adapter_module.SWEBenchToHarbor

    instance_ids = [
        line.strip()
        for line in args.ids.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not instance_ids:
        raise SystemExit("Task ID manifest is empty")
    if len(set(instance_ids)) != len(instance_ids):
        raise SystemExit("Task ID manifest contains duplicates")

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    converter = converter_class(
        harbor_tasks_root=output_dir,
        max_timeout_sec=args.timeout_seconds,
    )
    generated, failures = converter.generate_many(instance_ids, overwrite=True)
    if failures:
        for instance_id, reason in failures:
            print(f"FAILED {instance_id}: {reason}", file=sys.stderr)
        raise SystemExit(f"Failed to generate {len(failures)} task(s)")
    if len(generated) != len(instance_ids):
        raise SystemExit(
            f"Expected {len(instance_ids)} generated tasks, found {len(generated)}"
        )
    print(f"Generated {len(generated)} tasks in {output_dir}")


if __name__ == "__main__":
    main()
