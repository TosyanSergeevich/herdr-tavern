#!/bin/sh
# Modified for Tavern: isolated herdr-tavern runtime namespace.
# managed by herdr-tavern; reinstalling the integration replaces this file.
# HERDR_TAVERN_INTEGRATION_ID=qodercli
# HERDR_TAVERN_INTEGRATION_VERSION=4

[ "${1:-}" = "session" ] || exit 0
[ "${HERDR_TAVERN_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_TAVERN_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_TAVERN_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 -c '
import json
import os
import subprocess
import sys
import time

try:
    payload = json.load(sys.stdin)
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        raise ValueError
    subprocess.run(
        [
            os.environ.get("HERDR_TAVERN_BIN_PATH") or "herdr-tavern",
            "pane", "report-agent-session", os.environ["HERDR_TAVERN_PANE_ID"],
            "--source", "herdr-tavern:qodercli", "--agent", "qodercli",
            "--agent-session-id", session_id, "--seq", str(time.time_ns()),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=1,
        check=False,
    )
except Exception:
    pass
' 2>/dev/null || true
