#!/bin/sh
# Modified for Tavern: isolated herdr-tavern runtime namespace.
# managed by herdr-tavern; reinstalling the integration replaces this file.
# HERDR_TAVERN_INTEGRATION_ID=kimi
# HERDR_TAVERN_INTEGRATION_VERSION=8

action="${1:-}"
case "$action" in
  session|working|blocked|idle) ;;
  *) exit 0 ;;
esac

[ "${HERDR_TAVERN_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_TAVERN_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_TAVERN_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 -c '
import json
import os
import socket
import sys
import time

action = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}

session_id = payload.get("session_id")
if not isinstance(session_id, str) or not session_id:
    session_id = None

seq = time.time_ns()
params = {
    "pane_id": os.environ["HERDR_TAVERN_PANE_ID"],
    "source": "herdr-tavern:kimi",
    "agent": "kimi",
    "seq": seq,
}
if action == "session":
    if session_id is None:
        raise SystemExit(0)
    method = "pane.report_agent_session"
    params["session_start_source"] = "startup"
else:
    method = "pane.report_agent"
    params["state"] = action
if session_id is not None:
    params["agent_session_id"] = session_id

request = json.dumps({"id": f"herdr-tavern:kimi:{seq}", "method": method, "params": params})
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(0.5)
        client.connect(os.environ["HERDR_TAVERN_SOCKET_PATH"])
        client.sendall((request + "\n").encode())
        client.recv(4096)
except Exception:
    pass
' "$action" 2>/dev/null || true
