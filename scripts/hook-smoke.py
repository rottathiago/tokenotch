"""Exercise the native helper without reading or writing the user's integration."""

import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def main():
    helper = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="tokenotch-hook-", dir="/tmp") as temporary:
        home = Path(temporary).resolve()
        env = {**os.environ, "HOME": str(home), "CFFIXED_USER_HOME": str(home)}
        probe = subprocess.run(
            ["xcrun", "swift", "-e",
             "import Foundation; print(FileManager.default.homeDirectoryForCurrentUser.path)"],
            env=env, capture_output=True, text=True, check=True, timeout=60,
        )
        assert Path(probe.stdout.strip()).resolve() == home, "Refusing to run without an isolated Foundation home"
        root = home / ".tokenotch"
        marker = root / "bridge-failure"
        now = int(time.time() * 1000)
        base = {"sessionId": "private-session", "eventId": "private-call", "timestamp": now}
        usage = {
            **base, "usageContract": 1, "inputTokens": 100, "outputTokens": 10,
            "cacheReadTokens": 40, "cacheWriteTokens": 20,
            "cacheReadTokensReported": True, "cacheWriteTokensReported": True,
            "model": "fixture-model", "prompt": "private-content", "cwd": "/private-path",
        }

        def invoke(source, hook, payload, status):
            result = subprocess.run(
                [str(helper), source, hook], input=json.dumps(payload).encode(),
                env=env, capture_output=True, timeout=3,
            )
            assert result.returncode == status, (source, hook, result.returncode, status)
            assert result.stdout == b"", "Hooks must never emit an approval decision"
            assert b"private-" not in result.stderr, "Failure diagnostics must not expose payload content"

        metrics = {
            "usage": usage,
            "context": {**base, "currentTokens": 80, "tokenLimit": 100},
            "contextInvalidated": base,
            "compaction": {**base, "phase": "start"},
            "activity": {**base, "active": True},
        }
        for hook, payload in metrics.items():
            invoke("cli", hook, payload, 1)
            assert marker.read_text() == "Hook delivery unavailable"
            marker.unlink()

        for hook, fields in [
            ("sessionStart", {}), ("userPromptSubmitted", {}),
            ("agentStop", {"stopReason": "end_turn"}), ("sessionEnd", {"reason": "complete"}),
            ("notification", {"hook_event_name": "Notification", "notification_type": "permission_prompt"}),
            ("errorOccurred", {"recoverable": False}),
        ]:
            invoke("cli", hook, {**base, **fields}, 0)
            assert marker.read_text() == "Hook delivery unavailable", "Lifecycle delivery must remain fail-open"
            marker.unlink()
        for hook in ["SessionStart", "UserPromptSubmit", "Stop"]:
            payload = {
                "session_id": "private-session", "hook_event_name": hook,
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now / 1000)),
            }
            invoke("vscode", hook, payload, 0)
            assert marker.read_text() == "Hook delivery unavailable"
            marker.unlink()
        invoke("cli", "notification", {
            **base, "hook_event_name": "Notification", "notification_type": "ignored",
        }, 0)
        assert not marker.exists(), "Intentionally filtered hooks must not become failures"

        invoke("cli", "usage", {**usage, "usageContract": 0}, 1)
        assert marker.read_text() == "metric-upgrade"
        marker.unlink()
        invoke("cli", "usage", {**usage, "inputTokens": -1}, 1)
        assert marker.read_text() == "Hook delivery unavailable"
        marker.unlink()
        marker.mkdir()
        invoke("cli", "usage", usage, 1)
        marker.rmdir()

        registration = root / "cli.registration"
        registration.write_text("fixture-registration")
        registration.chmod(0o600)
        invoke("cli", "usage", usage, 1)
        assert marker.read_text() == "Hook delivery unavailable"
        marker.unlink()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as receiver:
            path = root / "events.sock"
            receiver.bind(str(path))
            path.chmod(0o600)
            receiver.listen(8)
            receiver.settimeout(3)
            events = []
            for hook, payload in [("usage", usage), ("usage", usage), *metrics.items()]:
                invoke("cli", hook, payload, 0)
                connection, _ = receiver.accept()
                with connection:
                    connection.settimeout(3)
                    wire = b""
                    while not wire.endswith(b"\n"):
                        part = connection.recv(4096)
                        assert part, "Helper closed without delivering a complete envelope"
                        wire += part
                        assert len(wire) <= 4096, "Helper exceeded the bridge envelope limit"
                assert b"private-" not in wire, "Raw identity or content reached the bridge"
                envelope = json.loads(wire)
                assert envelope["registration"] == "fixture-registration"
                events.append(envelope["event"])
            assert events[0] == events[1] == events[2], "Retries must preserve normalized call identity"
            tokens = events[0]["tokens"]
            assert tokens["model"] == "fixture-model"
            assert (tokens["input"], tokens["output"], tokens["cacheInput"], tokens["cacheWrite"]) == (40, 10, 40, 20)
            assert tokens["callID"] == hashlib.sha256(b"private-session:private-call").hexdigest()
            assert not marker.exists(), "Successful forwarding must not report a delivery failure"
    print("PASS: native telemetry failures return nonzero, retries preserve usage, and lifecycle hooks remain fail-open.")


if __name__ == "__main__":
    main()
