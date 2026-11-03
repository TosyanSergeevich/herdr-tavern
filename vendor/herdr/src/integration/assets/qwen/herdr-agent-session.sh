#!/bin/sh
# Modified for Tavern: isolated herdr-tavern runtime namespace.
# managed by herdr-tavern; reinstalling the integration replaces this file.
# HERDR_TAVERN_INTEGRATION_ID=qwen
# HERDR_TAVERN_INTEGRATION_VERSION=2

[ "${1:-}" = "session" ] || exit 0
[ "${HERDR_TAVERN_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_TAVERN_PANE_ID:-}" ] || exit 0
[ -n "${HERDR_TAVERN_SOCKET_PATH:-}" ] || exit 0
if [ -n "${HERDR_TAVERN_BIN_PATH:-}" ]; then
    [ -x "$HERDR_TAVERN_BIN_PATH" ] || exit 0
else
    command -v herdr-tavern >/dev/null 2>&1 || exit 0
fi
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
    source = payload.get("source")
    if not isinstance(session_id, str) or not session_id:
        raise ValueError
    command = os.environ.get("HERDR_TAVERN_BIN_PATH") or "herdr-tavern"
    args = [
        command, "pane", "report-agent-session", os.environ["HERDR_TAVERN_PANE_ID"],
        "--source", "herdr-tavern:qwen", "--agent", "qwen",
        "--agent-session-id", session_id, "--seq", str(time.time_ns()),
    ]
    if source in ("startup", "resume", "clear", "compact", "branch"):
        args.extend(["--session-start-source", source])
    subprocess.run(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=1,
        check=False,
    )
except Exception:
    pass
' 2>/dev/null || true
