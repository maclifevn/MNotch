"""Exercise the actual shipped Perl helpers against an isolated localhost peer."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
RELAY = ROOT / "Vendor/agent-relay/mnotch-relay.pl"
NOTIFY = ROOT / "Vendor/agent-relay/mnotch-notify.pl"


class RelayTests(unittest.TestCase):
    def exchange(self, payload, args=None, reply=None, script=RELAY):
        received, failures = [], []
        with tempfile.TemporaryDirectory(prefix="mnotch-relay-tests-") as support:
            with socket.socket() as peer:
                peer.bind(("127.0.0.1", 0))
                peer.listen(1)
                peer.settimeout(3)
                Path(support, "agent-port").write_text(str(peer.getsockname()[1]))
                Path(support, "agent-token").write_text("isolated-test-token")

                def receive():
                    try:
                        with peer.accept()[0] as connection:
                            connection.settimeout(3)
                            data = b""
                            while not data.endswith(b"\n"):
                                data += connection.recv(65536)
                            received.append(json.loads(data))
                            if reply is not None:
                                connection.sendall(reply)
                    except Exception as error:
                        failures.append(error)

                worker = threading.Thread(target=receive)
                worker.start()
                environment = dict(os.environ, MNOTCH_SUPPORT_DIRECTORY=support)
                result = subprocess.run(["/usr/bin/perl", str(script)] + (args or []),
                                        input=json.dumps(payload).encode(), capture_output=True,
                                        env=environment, timeout=5)
                worker.join(4)
                self.assertFalse(worker.is_alive())
                self.assertEqual(failures, [])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(received[0]["token"], "isolated-test-token")
                return received[0]["event"], result.stdout

    def test_nested_event_cannot_change_top_level_routing(self):
        payload = {"hook_event_name": "Stop", "session_id": "quotes\"\nline",
                   "tool_input": {"hook_event_name": "PermissionRequest"},
                   "cwd": "/tmp/apostrophe' and newline\n"}
        event, output = self.exchange(payload, args=["codex"])
        self.assertEqual(event["event"], "Stop")
        self.assertEqual(event["cwd"], payload["cwd"])
        self.assertEqual(event["session_id"], payload["session_id"])
        self.assertEqual(event["agent_kind"], "codex")
        self.assertEqual(output, b"")

    def test_permission_response_keeps_native_schema(self):
        reply = {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                      "decision": {"behavior": "allow"}}}
        _, output = self.exchange({"hook_event_name": "PermissionRequest"},
                                  reply=json.dumps(reply).encode() + b"\n")
        self.assertEqual(json.loads(output), reply)

    def test_closed_peer_preserves_native_permission_prompt(self):
        _, output = self.exchange({"hook_event_name": "PermissionRequest"})
        self.assertEqual(output, b"")
        _, output = self.exchange({"hook_event_name": "PreToolUse"})
        self.assertEqual(json.loads(output)["hookSpecificOutput"]["permissionDecision"], "ask")

    def test_oversized_reply_is_rejected(self):
        _, output = self.exchange({"hook_event_name": "PermissionRequest"}, reply=b"x" * 70000)
        self.assertEqual(output, b"")

    def test_notifier_escapes_control_characters(self):
        payload = {"session_id": "tab\tnewline\nquotes\"", "cwd": "/tmp/\n\t"}
        event, output = self.exchange(payload, args=["idle", "control\nchars\t\""], script=NOTIFY)
        self.assertEqual(event["session_id"], payload["session_id"])
        self.assertEqual(event["cwd"], payload["cwd"])
        self.assertEqual(event["title"], "control\nchars\t\"")
        self.assertEqual(output, b"")

    def test_malformed_or_oversized_input_has_no_output(self):
        with tempfile.TemporaryDirectory() as support:
            environment = dict(os.environ, MNOTCH_SUPPORT_DIRECTORY=support)
            for script in (RELAY, NOTIFY):
                for data in (b"invalid", b"[]", b"x" * 900001):
                    result = subprocess.run(["/usr/bin/perl", str(script)], input=data,
                                            capture_output=True, env=environment, timeout=4)
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, b"")

    def test_open_stdin_has_bounded_deadline(self):
        process = subprocess.Popen(["/usr/bin/perl", str(RELAY)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.wait(timeout=4), 0)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()


if __name__ == "__main__":
    unittest.main()
