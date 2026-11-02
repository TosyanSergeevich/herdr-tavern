#!/usr/bin/env python3
"""Локальный PTY producer: никаких моделей, сети или пользовательских файлов."""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import sys
import termios
import time
import tty

MARKER_PREFIX = "TAVERN-PERF-PANE-"
FIXTURE_VERSION = 2


def marker(index):
    return f"{MARKER_PREFIX}{index:03d}"


def burst(index, tick, count=12):
    """ANSI + Cyrillic + wide + combining; одинаковые байты для одного tick."""
    lines = [f"\x1b[3{(tick + row) % 7 + 1}m{marker(index)} "
             f"{tick:06d}:{row:02d} сборка 模型 e\u0301 "
             f"{'█' * ((tick + row) % 17)}\x1b[0m\r\n" for row in range(count)]
    lines.append(f"\r\x1b[2K{marker(index)} progress {tick % 101:3d}%\r\n")
    return f"\x1b]0;{marker(index)} tick={tick:06d}\x07" + "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=int, required=True)
    parser.add_argument("--control", type=Path, required=True)
    args = parser.parse_args()
    old = termios.tcgetattr(sys.stdin.fileno())
    alive = True

    def stop(*_):
        nonlocal alive
        alive = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    tick, pending, epoch, emitted = 0, b"", None, 0
    try:
        tty.setcbreak(sys.stdin.fileno())
        # Enough history for actual scroll movement, including static scenes.
        sys.stdout.write("\x1b[2J\x1b[H" + burst(args.index, 0, 160))
        sys.stdout.flush()
        while alive:
            try:
                control = json.loads(args.control.read_text())
            except (OSError, ValueError):
                control = {"epoch": 0, "rate": 0}
            if control.get("epoch") != epoch:
                epoch, tick, emitted = control.get("epoch"), 0, 0
                origin = time.monotonic()
                if control.get("control_frame"):
                    sys.stdout.write("\x1b[2J\x1b[H" + burst(args.index, 0, 12)
                                     + f"\r\n{marker(args.index)} CONTROL-FRAME\r\n")
                    sys.stdout.flush()
            rate = control.get("rate", 0)
            due = int((time.monotonic() - origin) * rate)
            if rate and emitted < due:
                # Bounded burst, never an unbounded catch-up loop.
                sys.stdout.write(burst(args.index, tick))
                sys.stdout.flush()
                tick += 1
                emitted += 1
            readable, _, _ = select.select([sys.stdin], [], [], .05 if rate else .25)
            if readable:
                chunk = os.read(sys.stdin.fileno(), 4096)
                if not chunk:
                    break
                pending += chunk
                while b"\n" in pending or b"\r" in pending:
                    split = min(p for p in (pending.find(b"\n"), pending.find(b"\r")) if p >= 0)
                    line, pending = pending[:split], pending[split + 1:]
                    sys.stdout.write(f"\r\n{marker(args.index)} ECHO:{line.decode('utf-8', 'replace')}\r\n")
                    sys.stdout.flush()
    finally:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, old)


if __name__ == "__main__":
    main()
