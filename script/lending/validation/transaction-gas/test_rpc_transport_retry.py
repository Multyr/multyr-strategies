"""Control-plane fault regressions; not part of financial no-mock acceptance."""
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("gas_runner", pathlib.Path(__file__).with_name("runner.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RpcTransportRetryTest(unittest.TestCase):
    def failure(self, **changes):
        result = {"status": "FAIL", "errorType": "RuntimeError", "operations": [{"receipt": {"status": 1}}],
                  "error": "RPC error eth_estimateGas: failed to get account: error sending request for url (https://eth.drpc.org/); connection reset"}
        result.update(changes)
        return result

    def test_ci_reset_restarts_case_and_preserves_partial_receipts(self):
        failed = self.failure()
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runner, "run_case", side_effect=[failed, {"status": "PASS"}]) as run, \
                patch.object(runner.time, "sleep"):
            path = pathlib.Path(directory)
            result = runner.run_case_with_transport_retry({"id": "euler-arb-usdc"}, "public", path)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(json.loads((path / "transport-attempt-1.json").read_text()), failed)
            self.assertEqual(len(result["infrastructureAttempts"]), 1)

    def test_assertions_reverts_and_unclassified_errors_are_never_retried(self):
        failures = [self.failure(errorType="AssertionError"),
                    self.failure(error="RPC error eth_call: execution reverted: error sending request for url connection reset"),
                    self.failure(error="RPC error eth_call: execution reverted"),
                    self.failure(error="connection reset")]
        for failed in failures:
            with self.subTest(error=failed), tempfile.TemporaryDirectory() as directory, \
                    patch.object(runner, "run_case", return_value=failed) as run, \
                    patch.object(runner.time, "sleep") as sleep:
                result = runner.run_case_with_transport_retry({}, "public", pathlib.Path(directory))
                self.assertEqual(result["status"], "FAIL")
                self.assertEqual(run.call_count, 1)
                sleep.assert_not_called()

    def test_three_transport_failures_remain_failed(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runner, "run_case", side_effect=[self.failure() for _ in range(3)]) as run, \
                patch.object(runner.time, "sleep"):
            result = runner.run_case_with_transport_retry({}, "public", pathlib.Path(directory))
            self.assertEqual(run.call_count, 3)
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(len(result["infrastructureAttempts"]), 2)


if __name__ == "__main__":
    unittest.main()
