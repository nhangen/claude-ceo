import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

SPEC = importlib.util.spec_from_file_location("fleet_discord", Path(__file__).with_name("ceo-fleet-readiness-discord.py"))


class DeliveryTests(unittest.TestCase):
    def test_supported_reason_explains_warning_and_deduplicates_repeat(self):
        state = {"active_failures": [], "unknown": ["ml2:ml2:reachability"], "finding_details": {"ml2:ml2:reachability": {"code": "probe-timeout"}}}
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()) as post:
            self.assertTrue(self.module.deliver(state, "test", self.ack, self.pending, self.webhook))
            payload = json.loads(post.call_args.args[0].data)
            self.assertIn("time budget", payload["embeds"][0]["description"])
            self.assertFalse(self.module.deliver(state, "test", self.ack, self.pending, self.webhook))
        self.assertEqual(post.call_count, 1)

    def test_informational_gap_stays_in_state_without_initial_discord_warning(self):
        state = {"active_failures": [], "unknown": ["gpu:trust-state"], "finding_details": {"gpu:trust-state": {"code": "collector-unsupported"}}}
        with patch.object(self.module, "urlopen") as post:
            self.assertFalse(self.module.deliver(state, "test", self.ack, self.pending, self.webhook))
        post.assert_not_called()
        state["active_failures"] = ["gpu:trust-state"]
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()) as post:
            self.assertTrue(self.module.deliver(state, "test", self.ack, self.pending, self.webhook))
        self.assertEqual(post.call_count, 1)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(self.module)
        self.ack = self.root / "ack.json"
        self.pending = self.root / "pending.json"
        self.webhook = "https://discord.com/api/webhooks/123/secret-test-value"

    def tearDown(self):
        self.directory.cleanup()

    def response(self):
        result = io.BytesIO(b'{"id":"1234","channel_id":"5678"}')
        result.status = 200
        return result

    def deliver(self, failures=None, warnings=None):
        return self.module.deliver({"active_failures": failures or [], "unknown": warnings or []}, "test", self.ack, self.pending, self.webhook)

    def test_initial_warning_is_sent_unchanged_is_quiet_recovery_is_sent(self):
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()) as post:
            self.assertTrue(self.deliver(warnings=["gpu:trust-state"]))
            self.assertFalse(self.deliver(warnings=["gpu:trust-state"]))
            self.assertTrue(self.deliver())
        self.assertEqual(post.call_count, 2)
        self.assertEqual(json.loads(self.ack.read_text())["discord_message_id"], "1234")
        self.assertNotIn("secret-test-value", self.ack.read_text())
        self.assertNotIn("secret-test-value", self.pending.read_text())

    def test_failed_delivery_retains_ack_and_retries_same_transition(self):
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()):
            self.deliver(warnings=["gpu:trust-state"])
        previous = self.ack.read_text()
        with patch.object(self.module, "urlopen", side_effect=OSError("secret-test-value")) as post, patch.object(self.module.time, "sleep") as sleep:
            with self.assertRaises(self.module.DeliveryError):
                self.deliver(failures=["gpu:api"])
        self.assertEqual(post.call_count, 3)
        self.assertEqual(sleep.call_args_list, [call(1), call(2)])
        self.assertEqual(self.ack.read_text(), previous)
        self.assertNotIn("secret-test-value", self.pending.read_text())
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()):
            self.assertTrue(self.deliver(failures=["gpu:api"]))

    def test_transient_failure_retries_and_acknowledges_valid_receipt(self):
        with patch.object(self.module, "urlopen", side_effect=[OSError("temporary"), self.response()]) as post, patch.object(self.module.time, "sleep") as sleep:
            self.assertTrue(self.deliver(failures=["gpu:api"]))
        self.assertEqual(post.call_count, 2)
        self.assertEqual(sleep.call_args_list, [call(1)])
        acknowledgment = json.loads(self.ack.read_text())
        self.assertEqual(acknowledgment["failures"], ["gpu:api"])
        self.assertEqual(acknowledgment["discord_message_id"], "1234")
        self.assertEqual(acknowledgment["discord_channel_id"], "5678")
        with patch.object(self.module, "urlopen") as post:
            self.assertFalse(self.deliver(failures=["gpu:api"]))
        post.assert_not_called()

    def test_http_error_or_missing_receipt_cannot_acknowledge(self):
        for status, body in ((500, b'{}'), (200, b'{}'), (204, b''), (200, b'[]'), (200, b'null'), (200, b'{"id":123,"channel_id":"5678"}')):
            with self.subTest(status=status, body=body):
                def response(*args, **kwargs):
                    value = io.BytesIO(body)
                    value.status = status
                    return value
                with patch.object(self.module, "urlopen", side_effect=response), patch.object(self.module.time, "sleep"):
                    with self.assertRaises(self.module.DeliveryError):
                        self.deliver(warnings=["gpu:trust-state"])
                self.assertFalse(self.ack.exists())

    def test_invalid_persisted_ack_cannot_suppress_delivery(self):
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()):
            self.deliver(warnings=["gpu:trust-state"])
        original = json.loads(self.ack.read_text())
        for key, value in (("schema_version", 2), ("discord_message_id", None), ("delivered_at", "invalid")):
            self.ack.write_text(json.dumps({**original, key: value}))
            with self.assertRaises((ValueError, TypeError)):
                self.deliver(warnings=["gpu:trust-state"])

    def test_post_receipt_write_failure_leaves_transition_unacknowledged(self):
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()), patch.object(self.module, "atomic_write", side_effect=[None, OSError("disk")]):
            with self.assertRaises(OSError):
                self.deliver(failures=["gpu:api"])
        self.assertFalse(self.ack.exists())

    def test_empty_initial_state_is_quiet_and_mentions_are_disabled(self):
        with patch.object(self.module, "urlopen") as post:
            self.assertFalse(self.deliver())
        post.assert_not_called()
        with patch.object(self.module, "urlopen", side_effect=lambda *a, **k: self.response()) as post:
            self.deliver(failures=["gpu:api"])
        request = post.call_args.args[0]
        self.assertEqual(json.loads(request.data)["allowed_mentions"], {"parse": []})
        self.assertEqual(post.call_args.kwargs["timeout"], 10)


if __name__ == "__main__":
    unittest.main()
