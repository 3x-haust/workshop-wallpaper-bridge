#!/usr/bin/env python3
"""Account-free subprocess contract checks against the published self-contained helper."""
import json
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import uuid

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="wwb-helper-ipc-") as scratch:
    process = subprocess.Popen([str(binary), "--data-directory", str(Path(scratch).resolve() / "auth")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    count = 0
    try:
        def exchange(command, expected, **fields):
            global count
            identifier = str(uuid.uuid4())
            process.stdin.write(json.dumps(dict(id=identifier, command=command, **fields)) + "\n")
            process.stdin.flush()
            assert selector.select(timeout=10), "Helper did not respond within deadline"
            line = process.stdout.readline()
            event = json.loads(line)
            assert event == dict(id=identifier, type="error", code=expected[0], message=expected[1]), event
            assert "fixture-secret" not in line
            count += 1

        for _ in range(20):
            exchange("resume", ("credentialsUnavailable", "Saved Steam sign-in is unavailable. Please sign in again."))
            exchange("search", ("authenticationRequired", "Sign in to Steam to continue."), query="fixture-secret", page=1)
        exchange("details", ("authenticationRequired", "Sign in to Steam to continue."), itemID="123")
        exchange("download", ("authenticationRequired", "Sign in to Steam to continue."), itemID="123", directory="fixture-secret")
        exchange("fixture-secret", ("invalidRequest", "The helper request is invalid."), password="fixture-secret")
        exchange("guard", ("invalidRequest", "The helper request is invalid."), code="fixture-secret")
        exchange("loginPassword", ("invalidRequest", "The helper request is invalid."), username="", password="fixture-secret")
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        assert process.stderr.read() == "", "Diagnostics were not suppressed"
        assert process.stdout.read() == "", "Unexpected terminal output"
        print(f"PASS {count} subprocess IPC requests; no account/network or diagnostic leakage")
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
