import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "scripts/analyze-profile.py"


def record(session: int, ttft: float, itl: float, start: int, end: int) -> dict:
    return {
        "metadata": {
            "session_num": session,
            "x_request_id": f"request-{session}",
            "request_start_ns": start,
            "request_end_ns": end,
            "was_cancelled": False,
            "benchmark_phase": "profiling",
        },
        "trace_data": {"response_status_code": 200},
        "metrics": {
            "time_to_first_token": {"value": ttft, "unit": "ms"},
            "inter_token_latency": {"value": itl, "unit": "ms"},
            "request_latency": {"value": (end - start) / 1e6, "unit": "ms"},
            "input_sequence_length": {"value": 1000 + session, "unit": "tokens"},
            "output_sequence_length": {"value": 10, "unit": "tokens"},
        },
    }


class AnalyzerTest(unittest.TestCase):
    def test_strict_thresholds_exclude_equalities(self) -> None:
        records = [
            record(0, 100, 10, 0, 1_000_000_000),
            record(1, 5000, 10, 1_000_000_000, 2_000_000_000),
            record(2, 100, 100, 2_000_000_000, 4_000_000_000),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / "profile.jsonl"
            output = root / "summary.json"
            profile.write_text("".join(json.dumps(item) + "\n" for item in records))
            subprocess.run(
                [
                    "python3",
                    str(ANALYZER),
                    str(profile),
                    "--output",
                    str(output),
                    "--expected-requests",
                    "3",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            metrics = json.loads(output.read_text())["metrics"]
            self.assertEqual(metrics["strict_good_request_count"], 1)
            self.assertEqual(metrics["threshold_equality_count"], 2)
            self.assertAlmostEqual(metrics["strict_goodput_rps"], 0.25)
            self.assertEqual(metrics["error_count"], 0)


if __name__ == "__main__":
    unittest.main()
