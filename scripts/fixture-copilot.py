#!/usr/bin/env python3
"""Synthetic CLI fixture: no network, credentials, inference, or real user configuration."""
import json
import os
import sys
from pathlib import Path

home = Path(os.environ["COPILOT_HOME"])
for forbidden in ("GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN", "COPILOT_SDK_AUTH_TOKEN"):
    if forbidden in os.environ:
        sys.exit(91)
if "login" in sys.argv:
    if "--web-flow" not in sys.argv:
        sys.exit(92)
    (home / "fixture-signed-in").touch(mode=0o600)
    sys.exit(0)
if "--headless" not in sys.argv or "--stdio" not in sys.argv:
    sys.exit(93)

requests = []
while True:
    line = sys.stdin.buffer.readline()
    if not line:
        break
    if not line.lower().startswith(b"content-length:"):
        sys.exit(94)
    length = int(line.split(b":", 1)[1])
    if sys.stdin.buffer.readline() != b"\r\n":
        sys.exit(95)
    message = json.loads(sys.stdin.buffer.read(length))
    method = message["method"]
    requests.append(method)
    (home / "fixture-requests.json").write_text(json.dumps(requests))
    response = {"jsonrpc": "2.0", "id": message["id"]}
    mode_file = home / "fixture-mode"
    mode = mode_file.read_text() if mode_file.exists() else ""
    if method == "status.get":
        protocol = 99 if mode == "incompatible" else (3 if mode == "protocol-3" else 2)
        response["result"] = {"version": "synthetic-fixture", "protocolVersion": protocol}
    elif method == "auth.getStatus":
        authenticated = (home / "fixture-signed-in").exists() and "--no-auto-login" not in sys.argv
        response["result"] = {
            "isAuthenticated": authenticated,
            "login": ("changed" if mode == "changed-account" and requests.count(method) > 1 else "fixture-user") if authenticated else None,
            "host": "https://github.com",
            "authType": "user",
        }
    elif method == "account.getQuota":
        if mode == "rate-limit":
            response["error"] = {"code": -32603, "message": "429 rate limit: do not expose raw response"}
        else:
            response["result"] = {"quotaSnapshots": {"premium_interactions": {
                "isUnlimitedEntitlement": False,
                "entitlementRequests": 300,
                "usedRequests": 58.5,
                "remainingPercentage": 80.5,
                "overage": 0,
            }}}
    else:
        response["error"] = {"code": -32601, "message": "Unexpected method"}
    data = json.dumps(response).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    sys.stdout.buffer.flush()
