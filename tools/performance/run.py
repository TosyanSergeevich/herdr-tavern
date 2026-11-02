#!/usr/bin/env python3
"""Восемь изолированных сценариев Tavern; Python stdlib, macOS, без сети."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from comparison import SCENARIOS, SCHEMA, action_latency_stats, compare, flatten, metric_delta, schedule, summarize
from comparison import validate_baseline_artifacts
from fixture import FIXTURE_VERSION, marker

ROOT = Path(__file__).resolve().parent
ACTION_TIMEOUT = 12.0


class BenchmarkError(RuntimeError):
    def __init__(self, code, metadata=None):
        super().__init__(code)
        self.metadata = metadata or {}


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False))
    temporary.replace(path)


def command(args, env=None, timeout=20):
    result = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        # No terminal content, inherited environment, or arbitrary subprocess errors in reports.
        raise BenchmarkError(f"command_failed:{Path(str(args[0])).name}:{result.returncode}")
    return result.stdout.strip()


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def tree_digest(root):
    hasher = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            hasher.update(str(path.relative_to(root)).encode())
            hasher.update(bytes.fromhex(digest(path)))
    return hasher.hexdigest()


def clean_environment(config):
    # Allow-list: excludes HERDR_*, credentials, shell startup overrides and all model integrations.
    result = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "PATH", "TMPDIR") if key in os.environ}
    result.update({"XDG_CONFIG_HOME": str(config), "SHELL": "/bin/sh", "LANG": "en_US.UTF-8",
                   "LC_ALL": "en_US.UTF-8", "TERM": "xterm-256color"})
    return result


def wait_for(predicate, timeout=ACTION_TIMEOUT, code="readiness_timeout"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.04)
    raise BenchmarkError(code)


class Bridge:
    def __init__(self, directory, process):
        self.directory, self.process = directory, process
        self.require_active = True
        self.expected_context = None

    def request(self, op, **fields):
        request_id = uuid.uuid4().hex
        atomic_json(self.directory / "command.json", {"id": request_id, "op": op, **fields})
        deadline = time.monotonic() + ACTION_TIMEOUT
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise BenchmarkError("app_exited")
            try:
                response = json.loads((self.directory / "response.json").read_text())
            except (OSError, ValueError):
                time.sleep(.02)
                continue
            if response.get("id") != request_id:
                time.sleep(.02)
                continue
            if response.get("ok") is not True:
                code = response.get("error", "bridge_error")
                if not isinstance(code, str) or not code.replace("_", "").isalnum():
                    code = "bridge_error"
                raise BenchmarkError(f"{op}:{code}")
            result = response.get("result")
            if not isinstance(result, dict):
                raise BenchmarkError("invalid_bridge_result")
            return result
        # A mutation may have happened: never retry this command.
        raise BenchmarkError(f"{op}:bridge_timeout")

    def inspect(self):
        state = self.request("inspect")
        metadata = {"window_state": {key: state.get(key) if isinstance(state.get(key), bool) else None
                                     for key in ("ready", "visible", "active", "screen_locked")}}
        if state.get("screen_locked") is not False:
            raise BenchmarkError("screen_locked_or_unknown", metadata)
        if not state.get("visible"):
            raise BenchmarkError("window_not_visible", metadata)
        if self.require_active and not state.get("active"):
            raise BenchmarkError("window_not_active", metadata)
        if not state.get("ready"):
            raise BenchmarkError("app_not_ready", metadata)
        for key in ("width", "height", "scale", "refresh_hz"):
            value = state.get(key)
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise BenchmarkError(f"invalid_geometry:{key}", metadata)
        if self.expected_context is not None:
            changed = [key for key, expected in self.expected_context.items() if state.get(key) != expected]
            if changed:
                raise BenchmarkError("environment_context_drift", {**metadata, "context_fields": changed})
        return state

    def content(self, pane_index, tab=None, pane=None, token=None):
        def ready():
            state = self.inspect()
            if tab is not None and state.get("focused_tab") != tab:
                return False
            if pane is not None and state.get("focused_pane") != pane:
                return False
            text = state.get("terminal_text", "")
            wanted = token or marker(pane_index)
            return state if wanted in text else False
        return wait_for(ready, code="content_or_focus_timeout")


def rows(response, name):
    value = response.get(name)
    if not isinstance(value, list):
        raise BenchmarkError(f"cli_schema:{name}")
    return value


def identifier(value, kind):
    result = value.get(f"{kind}_id", value.get("id")) if isinstance(value, dict) else None
    if not isinstance(result, str) or not result:
        raise BenchmarkError(f"cli_schema:{kind}_id")
    return result


def cpu_time(text):
    text = text.strip()
    days, clock = text.split("-", 1) if "-" in text else ("0", text)
    parts = [float(part) for part in clock.split(":")]
    seconds = sum(part * 60 ** index for index, part in enumerate(reversed(parts)))
    return int(days) * 86400 + seconds


def process_sample(pid):
    # CPU time is cumulative process CPU, RSS is KiB from macOS ps, not physical footprint.
    result = command(["/bin/ps", "-p", str(pid), "-o", "time=", "-o", "rss="])
    parts = result.split()
    if len(parts) != 2:
        raise BenchmarkError("herdr_resource_sample_unavailable")
    return {"cpu_seconds": cpu_time(parts[0]), "rss_bytes": int(parts[1]) * 1024}


def optional_command(args):
    try:
        return command(args)
    except (OSError, subprocess.SubprocessError, BenchmarkError):
        return None


def power_source():
    result = optional_command(["/usr/bin/pmset", "-g", "batt"])
    if result and "AC Power" in result:
        return "AC"
    if result and "Battery Power" in result:
        return "battery"
    return None


def numeric_diagnostic(snapshot):
    """Explicit recorder schema only; no string values, arbitrary paths or terminal payload."""
    if not isinstance(snapshot, dict) or snapshot.get("schema_version") != 1:
        raise ValueError("diagnostic_schema")

    def scrub(value):
        if value is None or isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            if not math.isfinite(value):
                raise ValueError("diagnostic_nonfinite")
            return value
        if isinstance(value, dict):
            return {key: scrub(item) for key, item in value.items()
                    if isinstance(key, str) and key.isidentifier() and not isinstance(item, str)}
        if isinstance(value, list):
            return [scrub(item) for item in value if not isinstance(item, str)]
        raise ValueError("diagnostic_value")

    allowed = {"schema_version", "enabled", "detailed", "recorded_at_unix_seconds", "epoch", "elapsed_ns",
               "histogram_relative_precision", "stages", "counters", "gauges", "gauge_maxima",
               "slow_samples", "resources", "main_busy_current_ns", "storage_failures", "machine"}
    return scrub({key: value for key, value in snapshot.items() if key in allowed})


def preserve_diagnostics(box):
    relative = f"diagnostics/{box.scenario}-{box.repetition}"
    status = {"scenario": box.scenario, "repetition": box.repetition, "directory": relative,
              "files": [], "rejected_files": 0, "status": "unavailable"}
    destination = box.args.output / relative
    try:
        destination.mkdir(mode=0o700, parents=True, exist_ok=False)
        sources = [(box.bridge_dir / "metrics" / f"summary-{index}.jsonl", True) for index in range(4)]
        sources += [(box.bridge_dir / "metrics" / f"incident-{index}.json", False) for index in range(3)]
        sources.append((box.bridge_dir / "snapshot.json", False))
        for source, is_lines in sources:
            if not source.is_file() or source.is_symlink():
                continue
            if source.stat().st_size > 256 * 1024:
                status["rejected_files"] += 1
                continue
            samples = []
            try:
                payloads = source.read_text().splitlines() if is_lines else [source.read_text()]
                for payload in payloads:
                    if payload.strip():
                        try:
                            samples.append(numeric_diagnostic(json.loads(payload)))
                        except (ValueError, TypeError):
                            status["rejected_files"] += 1
                if samples:
                    name = source.stem + ".json" if is_lines else source.name
                    atomic_json(destination / name, {"schema_version": 1, "samples": samples})
                    status["files"].append(name)
            except (OSError, UnicodeError):
                status["rejected_files"] += 1
        status["status"] = "saved" if status["files"] else "unavailable"
        atomic_json(destination / "manifest.json", status)
    except (OSError, ValueError, AttributeError):
        # Diagnostics must not replace the benchmark's original failure.
        status["status"] = "preservation_failed"
    box.args.diagnostics.append(status)


class Sandbox:
    def __init__(self, args, scenario, repetition):
        self.args, self.scenario, self.repetition = args, scenario, repetition
        self.temp = None
        self.app_process = self.server_process = None
        self.log = None
        self.session = "tp_" + uuid.uuid4().hex[:16]
        self.bundle_id = "local.herdr.tavern.performance." + uuid.uuid4().hex
        self.tabs, self.panes, self.controls = [], [], []
        self.epoch = 0

    def cli(self, *args):
        result = command([self.args.herdr, "--session", self.session, *args], env=self.env)
        ack_only = {("pane", "run"), ("pane", "report-agent"), ("pane", "wait-output"), ("tab", "rename")}
        if not result and tuple(args[:2]) in ack_only:
            return {}
        try:
            value = json.loads(result)
        except ValueError:
            raise BenchmarkError("cli_invalid_json") from None
        if value.get("ok") is False or value.get("error"):
            raise BenchmarkError("cli_request_rejected")
        result = value.get("result", value)
        if not isinstance(result, dict):
            raise BenchmarkError("cli_invalid_result")
        return result

    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tavern-perf-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.env = clean_environment(self.root / "config")
        self.bridge_dir = self.root / "bridge"
        self.bridge_dir.mkdir(mode=0o700)
        config = self.root / "config" / "herdr"
        config.mkdir(parents=True, mode=0o700)
        (config / "config.toml").write_text('onboarding = false\n[terminal]\ndefault_shell = "/bin/sh"\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n[ui]\ncopy_on_select = false\n[ui.sound]\nenabled = false\n[ui.toast]\ndelivery = "off"\n[session]\nresume_agents_on_restore = false\n[experimental]\npane_history = false\n')
        try:
            self.start()
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def start(self):
        # A distinct bundle identity keeps all UserDefaults and app instances isolated.
        qa_app = self.root / "Tavern Performance.app"
        shutil.copytree(self.args.app, qa_app, symlinks=True)
        info_path = qa_app / "Contents" / "Info.plist"
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        info["CFBundleIdentifier"] = self.bundle_id
        with info_path.open("wb") as stream:
            plistlib.dump(info, stream)
        command(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", qa_app], env=self.env)
        self.log = (self.root / "process.log").open("wb")
        self.server_process = subprocess.Popen([self.args.herdr, "--session", self.session, "server"],
                                               env=self.env, stdout=self.log, stderr=self.log, start_new_session=True)
        socket_path = self.root / "config" / "herdr" / "sessions" / self.session / "herdr-client.sock"
        def socket_ready():
            if self.server_process.poll() is not None:
                raise BenchmarkError("server_exited")
            return socket_path.exists()
        wait_for(socket_ready, timeout=20, code="server_socket_timeout")
        # Use the initial topology, never leave an unmeasured default workspace/tab behind.
        workspaces = rows(self.cli("workspace", "list"), "workspaces")
        if not workspaces:
            created = self.cli("workspace", "create", "--cwd", self.root, "--label", "Tavern Performance", "--focus")
            workspace = identifier(created.get("workspace"), "workspace")
            initial_id = identifier(created.get("tab"), "tab")
            initial_pane = identifier(created.get("root_pane"), "pane")
        elif len(workspaces) == 1:
            workspace = identifier(workspaces[0], "workspace")
            initial_tabs = rows(self.cli("tab", "list", "--workspace", workspace), "tabs")
            if len(initial_tabs) != 1:
                raise BenchmarkError("unexpected_initial_tab_count")
            initial_id = identifier(initial_tabs[0], "tab")
            initial_panes = rows(self.cli("pane", "list", "--workspace", workspace), "panes")
            if len(initial_panes) != 1:
                raise BenchmarkError("unexpected_initial_pane_count")
            initial_pane = identifier(initial_panes[0], "pane")
        else:
            raise BenchmarkError("unexpected_initial_workspace_count")
        self.tabs.append(initial_id)
        self.panes.append(initial_pane)
        self.cli("tab", "rename", initial_id, marker(0))
        for index in range(1, self.args.tab_count):
            created = self.cli("tab", "create", "--workspace", workspace, "--cwd", self.root,
                               "--label", marker(index), "--no-focus")
            self.tabs.append(identifier(created.get("tab"), "tab"))
            self.panes.append(identifier(created.get("root_pane"), "pane"))
        if self.scenario == "panels":
            for direction in ("right", "down", "down"):
                created = self.cli("pane", "split", "--pane", initial_pane, "--direction", direction,
                                   "--cwd", self.root, "--no-focus")
                self.panes.append(identifier(created.get("pane"), "pane"))
        for index, pane in enumerate(self.panes):
            control = self.root / f"producer-{index}.json"
            atomic_json(control, {"epoch": 0, "rate": 0})
            self.controls.append(control)
            invocation = shlex.join([sys.executable, str(ROOT / "fixture.py"), "--index", str(index), "--control", str(control)])
            self.cli("pane", "run", pane, "exec " + invocation)
            self.cli("pane", "wait-output", pane, "--match", marker(index), "--timeout", "10000")
            if self.scenario in ("animations", "panels", "sustained"):
                self.cli("pane", "report-agent", pane, "--source", "tavern-performance", "--agent", "codex",
                         "--state", "working", "--seq", "1")
        launch_env = {**self.env, "TAVERN_BENCHMARK_DIRECTORY": str(self.bridge_dir),
                      "TAVERN_PERFORMANCE_DIRECTORY": str(self.bridge_dir / "metrics"),
                      "TAVERN_PERFORMANCE": "off" if self.args.recorder == "off" else "on",
                      "TAVERN_PERFORMANCE_DETAIL": "1" if self.args.recorder == "detailed" else "0"}
        executable = qa_app / "Contents" / "MacOS" / info["CFBundleExecutable"]
        self.app_process = subprocess.Popen([str(executable), "--socket", str(socket_path)], env=launch_env,
                                            stdout=self.log, stderr=self.log, start_new_session=True)
        self.bridge = Bridge(self.bridge_dir, self.app_process)
        self.bridge.require_active = False
        # Activate this child at most once during setup, never during measurement.
        readiness_flags = {}
        activation_attempted = False

        def app_ready(require_active=False):
            nonlocal activation_attempted
            state = self.bridge.request("inspect")
            readiness_flags.update({key: state.get(key) if isinstance(state.get(key), bool) else None
                                    for key in ("ready", "visible", "active", "screen_locked")})
            if state.get("screen_locked") is not False:
                raise BenchmarkError("screen_locked_or_unknown")
            if not state.get("ready"):
                return False
            if require_active and (not state.get("visible") or not state.get("active")):
                if not activation_attempted:
                    activation_attempted = True
                    script = ('tell application "System Events" to set frontmost of '
                              f'(first application process whose unix id is {self.app_process.pid}) to true')
                    try:
                        command(["/usr/bin/osascript", "-e", script], env=self.env, timeout=8)
                    except (BenchmarkError, OSError, subprocess.SubprocessError):
                        raise BenchmarkError("own_window_activation_failed") from None
                return False
            return bool(state.get("visible") and (not require_active or state.get("active")))

        try:
            wait_for(lambda: app_ready(True), timeout=20, code="window_readiness_timeout")
            self.bridge.request("resize", width=1200, height=800)
            motion_enabled = self.scenario in ("animations", "panels", "sustained")
            motion = self.bridge.request("motion", enabled=motion_enabled)
            if motion.get("enabled") != motion_enabled:
                raise BenchmarkError("motion_unavailable_check_system_reduce_motion")
            for index in range(len(self.tabs)):
                self.focus(index)
            self.focus(0)
            wait_for(lambda: app_ready(True), timeout=20, code="window_activation_readiness_timeout")
            self.bridge.require_active = True
            self.initial_state = self.bridge.inspect()
            self.bridge.expected_context = {
                key: self.initial_state.get(key) for key in
                ("display_id", "scale", "refresh_hz", "refresh_kind", "animations_enabled", "sound_enabled")}
        except BenchmarkError as error:
            error.metadata.setdefault("window_state", readiness_flags)
            error.metadata["activation_attempted"] = activation_attempted
            raise

    def focus(self, index):
        result = self.bridge.request("focus", tab=self.tabs[index])
        self.bridge.content(index, tab=self.tabs[index])
        return result

    def output(self, enabled):
        self.epoch += 1
        for index, path in enumerate(self.controls):
            active = enabled and (index == 0 or self.args.profile == "loaded" or self.scenario == "panels")
            atomic_json(path, {"epoch": self.epoch, "rate": 10 if active else 0})

    def __exit__(self, *_):
        errors = []
        # Stop owned client first, then the named server. Never target a default/user session.
        for process in (self.app_process,):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        if self.server_process:
            if self.server_process.poll() is None:
                try:
                    command([self.args.herdr, "--session", self.session, "server", "stop"], env=self.env, timeout=8)
                except (BenchmarkError, OSError, subprocess.SubprocessError):
                    errors.append("session_stop_failed")
                try:
                    self.server_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    # Only this runner's process group, never a discovered user PID.
                    os.killpg(self.server_process.pid, signal.SIGTERM)
                    try:
                        self.server_process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(self.server_process.pid, signal.SIGKILL)
                        self.server_process.wait(timeout=3)
        # This exact random domain belongs solely to this temporary signed bundle.
        optional_command(["/usr/bin/defaults", "delete", self.bundle_id])
        if self.log:
            self.log.close()
        preserve_diagnostics(self)
        if self.temp:
            self.temp.cleanup()
        if errors and sys.exc_info()[0] is None:
            raise BenchmarkError("cleanup:" + ",".join(errors))


def environment(state, snapshot, args):
    resources = snapshot.get("resources", {})
    machine = snapshot.get("machine", {})
    thermal = resources.get("thermal_state")
    if thermal is None:
        raise BenchmarkError("thermal_state_unavailable")
    if state.get("sound_enabled") is not False:
        raise BenchmarkError("benchmark_sound_not_disabled")
    return {"os": platform.mac_ver()[0], "architecture": platform.machine(),
            "hardware_model": machine.get("hardware_model") or command(["/usr/sbin/sysctl", "-n", "hw.model"]),
            "logical_cpu_count": os.cpu_count(),
            "physical_memory_bytes": machine.get("physical_memory_bytes") or int(command(["/usr/sbin/sysctl", "-n", "hw.memsize"])),
            "herdr_version": args.herdr_version, "herdr_sha256": args.herdr_sha,
            "width": state["width"], "height": state["height"], "scale": state["scale"],
            "refresh_hz": state["refresh_hz"], "display_id": state.get("display_id"),
            "refresh_kind": state.get("refresh_kind"), "low_power_mode": machine.get("low_power_mode"),
            "sound_enabled": state["sound_enabled"],
            "thermal_state": thermal, "power_source": power_source(),
            "histogram_relative_precision": snapshot.get("histogram_relative_precision")}


def validate_metrics(snapshot):
    flat = flatten(snapshot)
    for key, value in flat.items():
        if (key.startswith("gauges.") or "queue" in key.lower()) and value < 0:
            raise BenchmarkError("invalid_queue_metric")
    if not isinstance(snapshot.get("stages"), dict) or not isinstance(snapshot.get("resources"), dict):
        raise BenchmarkError("invalid_metrics_schema")


def action(box, scene, index):
    bridge = box.bridge
    state = bridge.inspect()
    result = None
    if scene == "animations":
        status = ("working", "blocked", "idle")[index % 3]
        box.cli("pane", "report-agent", box.panes[0], "--source", "tavern-performance",
                "--agent", "codex", "--state", status, "--seq", str(index + 2))
        result = box.focus((index + 1) % len(box.tabs))
    elif scene == "tabs" or (scene == "sustained" and index % 4 == 0):
        result = box.focus((index + 1) % len(box.tabs))
    elif scene == "panels":
        pane_index = [0, *range(box.args.tab_count, len(box.panes))][index % 4]
        result = bridge.request("focus_pane", pane=box.panes[pane_index])
        bridge.content(pane_index, tab=box.tabs[0], pane=box.panes[pane_index])
        bridge.request("scroll", lines=3 if index % 2 else -3)
    elif scene == "interaction" or (scene == "sustained" and index % 4 in (1, 2)):
        if index % 3 == 0:
            token = f"input-{index:06d}-Привет"
            bridge.request("scroll", lines=-65535)
            bridge.request("type", text=token + "\n")
            pane_index = box.panes.index(state["focused_pane"])
            bridge.content(pane_index, token="ECHO:" + token)
        elif index % 3 == 1:
            result = bridge.request("scroll", lines=8 if index % 2 else -8)
            if not all(isinstance(result.get(k), (int, float)) and math.isfinite(result[k]) for k in ("offset", "maximum")):
                raise BenchmarkError("invalid_scroll_geometry")
            if not 0 <= result["offset"] <= result["maximum"]:
                raise BenchmarkError("invalid_scroll_offset")
        else:
            columns, rows_count = state.get("columns", 0), state.get("rows", 0)
            if columns < 4 or rows_count < 3:
                raise BenchmarkError("selection_grid_too_small")
            row = rows_count // 2
            result = bridge.request("select", from_x=1, from_y=row,
                                    to_x=min(25, columns - 2), to_y=row)
            if result.get("selected") is not True:
                raise BenchmarkError("selection_not_created")
    elif scene == "resize" or (scene == "sustained" and index % 4 == 3):
        width, height = ((1100, 720), (1400, 900), (1200, 800))[index % 3]
        result = bridge.request("resize", width=width, height=height)
        actual = bridge.inspect()
        if abs(actual["width"] - width) > 1 or abs(actual["height"] - height) > 1:
            raise BenchmarkError("resize_geometry_mismatch")
    if result is not None and "latency_ns" in result:
        latency = result["latency_ns"]
        if not isinstance(latency, (int, float)) or not math.isfinite(latency) or latency < 0:
            raise BenchmarkError("invalid_action_latency")
    return result


def visual_pass(box, output, scene, repetition):
    # Called only after final measured snapshot/export. No captures in timed intervals.
    box.output(False)
    box.epoch += 1
    for control in box.controls:
        atomic_json(control, {"epoch": box.epoch, "rate": 0, "control_frame": True})
    captures = []
    for index in sorted({0, len(box.tabs) - 1}):
        box.focus(index)
        box.bridge.request("scroll", lines=-65535)
        box.bridge.content(index, tab=box.tabs[index], token=marker(index) + " CONTROL-FRAME")
        state = box.bridge.content(index, tab=box.tabs[index])
        window = state.get("window_id")
        if not isinstance(window, int) or window <= 0:
            raise BenchmarkError("own_window_id_unavailable")
        path = output / f"{scene}-{repetition}-tab-{index}.png"
        command(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window), path])
        if not path.is_file() or path.stat().st_size == 0:
            raise BenchmarkError("capture_missing")
        captures.append({"file": path.name, "tab_index": index, "marker_valid": True,
                         "width": state["width"], "height": state["height"], "scale": state["scale"]})
    return {"separate_unmeasured_pass": True, "frames": captures,
            "limitation": "Только контрольные кадры; они не измеряют физическую задержку input→screen и не доказывают отсутствие tearing."}


def run_once(args, scene, repetition):
    duration = args.duration if args.duration is not None else (300.0 if scene == "sustained" else 20.0)
    with Sandbox(args, scene, repetition) as box:
        output_enabled = scene in ("output", "tabs", "interaction", "panels", "resize", "sustained")
        box.output(output_enabled)
        if output_enabled:
            # Ensure actual post-setup producer output arrived before resetting metrics.
            box.cli("pane", "wait-output", box.panes[0], "--match", "000001:", "--timeout", "10000")
            box.bridge.content(0)
        box.bridge.request("reset_metrics")
        before = box.bridge.request("metrics")
        validate_metrics(before)
        if before.get("enabled") != (args.recorder != "off"):
            raise BenchmarkError("recorder_mode_not_applied")
        if args.recorder == "detailed" and before.get("detailed") is not True:
            raise BenchmarkError("recorder_detail_not_applied")
        identity = environment(box.initial_state, before, args)
        herdr_before = process_sample(box.server_process.pid)
        phases, events = [], []
        start = time.monotonic()
        for offset, index in schedule(scene, duration, args.tab_count):
            target = start + offset
            delay = target - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            if time.monotonic() >= start + duration:
                raise BenchmarkError("action_schedule_overrun", {
                    "scenario": scene, "scheduled_seconds": offset,
                    "elapsed_seconds": time.monotonic() - start, "completed_actions": len(events),
                    "last_actions": events[-16:],
                    "last_snapshot": numeric_diagnostic(phases[-1]["snapshot"] if phases else before)})
            event_start = time.monotonic_ns()
            result = action(box, scene, index)
            events.append({"index": index, "scheduled_seconds": offset,
                           "dispatch_seconds": (event_start / 1e9) - start,
                           "runner_round_trip_ns": time.monotonic_ns() - event_start,
                           "input_to_draw_ns": result.get("latency_ns") if result else None,
                           "boundary": result.get("boundary") if result else None,
                           "no_change": result.get("no_change") if result else None})
            snap = box.bridge.request("metrics")
            validate_metrics(snap)
            phases.append({"offset_seconds": time.monotonic() - start, "snapshot": snap,
                           "delta": metric_delta(before if not phases else phases[-1]["snapshot"], snap)})
        remaining = start + duration - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        box.bridge.inspect()
        after = box.bridge.request("metrics")
        elapsed = time.monotonic() - start
        herdr_after = process_sample(box.server_process.pid)
        validate_metrics(after)
        end_identity = environment(box.initial_state, after, args)
        if identity != end_identity:
            raise BenchmarkError("environment_drift")
        # Geometry can vary inside resize/sustained, but return to the fixed control geometry afterward.
        measurement = metric_delta(before, after)
        measurement["elapsed_seconds"] = elapsed
        measurement["herdr.cpu_seconds"] = herdr_after["cpu_seconds"] - herdr_before["cpu_seconds"]
        measurement["herdr.rss_bytes_end"] = herdr_after["rss_bytes"]
        action_statistics = action_latency_stats(events)
        measurement["actions.no_change_count"] = sum(event.get("no_change") is True for event in events)
        for key in ("p50", "p95", "p99"):
            if action_statistics[key] is not None:
                measurement[f"actions.input_to_draw_{key}_ns"] = action_statistics[key]
        for key, value in flatten(after).items():
            if key.startswith("resources.") or (args.recorder != "off" and key.startswith("stages.")):
                if key not in measurement:
                    measurement[key] = value
        # Never derive/average pooled percentiles. Stage histogram percentiles above describe this repetition.
        box.output(False)
        recovery = None
        if scene == "sustained":
            recovery_duration = min(duration, 2.0) if args.duration is not None else 5.0
            recovery_before = box.bridge.request("metrics")
            recovery_herdr_before = process_sample(box.server_process.pid)
            recovery_samples = []
            recovery_start = time.monotonic()
            while time.monotonic() - recovery_start < recovery_duration:
                time.sleep(min(.5, max(0, recovery_duration - (time.monotonic() - recovery_start))))
                box.bridge.inspect()
                snapshot = box.bridge.request("metrics")
                validate_metrics(snapshot)
                previous = recovery_samples[-1]["snapshot"] if recovery_samples else recovery_before
                recovery_samples.append({"offset_seconds": time.monotonic() - recovery_start,
                                         "snapshot": snapshot, "delta": metric_delta(previous, snapshot),
                                         "herdr": process_sample(box.server_process.pid)})
            recovery_after = recovery_samples[-1]["snapshot"]
            recovery_herdr_after = recovery_samples[-1]["herdr"]
            if environment(box.initial_state, recovery_after, args) != identity:
                raise BenchmarkError("environment_drift_during_recovery")
            recovery = {"duration_seconds": recovery_duration, "elapsed_seconds": time.monotonic() - recovery_start,
                        "snapshot_before": recovery_before, "snapshot_after": recovery_after,
                        "samples": recovery_samples, "delta": metric_delta(recovery_before, recovery_after),
                        "herdr_cpu_seconds": recovery_herdr_after["cpu_seconds"] - recovery_herdr_before["cpu_seconds"],
                        "herdr_rss_bytes_end": recovery_herdr_after["rss_bytes"]}
            measurement["recovery.elapsed_seconds"] = recovery["elapsed_seconds"]
            measurement["recovery.herdr_cpu_seconds"] = recovery["herdr_cpu_seconds"]
            measurement["recovery.herdr_rss_bytes_end"] = recovery["herdr_rss_bytes_end"]
            for key, value in recovery["delta"].items():
                measurement[f"recovery.{key}"] = value
        box.bridge.request("resize", width=1200, height=800)
        box.focus(0)
        final = box.bridge.content(0, tab=box.tabs[0])
        if len(final.get("tabs", [])) != args.tab_count:
            raise BenchmarkError("final_tab_count_mismatch")
        reset_scroll = box.bridge.request("scroll", lines=-65535)
        if reset_scroll.get("offset") != 0:
            raise BenchmarkError("final_scroll_not_at_bottom")
        exported = None
        if args.recorder != "off":
            export = box.bridge_dir / "snapshot.json"
            box.bridge.request("export", path=str(export))
            wait_for(lambda: export.is_file(), code="export_timeout")
            exported = json.loads(export.read_text())
            validate_metrics(exported)
        result = {"scenario": scene, "repetition": repetition, "valid": True, "correctness": True,
                  "environment": identity, "duration_seconds": duration, "snapshot_before": before,
                  "snapshot_after": after, "phase_samples": phases, "events": events,
                  "herdr_before": herdr_before, "herdr_after": herdr_after, "measurement": measurement,
                  "action_statistics_ns": action_statistics,
                  "recovery": recovery,
                  "export_snapshot": exported}
        if args.visual:
            result["visual"] = visual_pass(box, args.output, scene, repetition)
        return result


def markdown(report):
    lines = ["# Производительность Tavern", "", f"Данные валидны: **{report['valid']}**", "",
             "Синтетическая задержка input→draw, не физическая input→screen. GPU и энергопотребление не выводятся из CPU.",
             "herdr RSS — резидентная память по ps, не physical footprint. Статистика N повторений; без общей оценки и порогов.", ""]
    if report.get("error"):
        lines += [f"Ошибка: `{report['error']}`", ""]
    for scene, metrics in report.get("summary", {}).items():
        lines += [f"## Сценарий `{scene}`", "", "| Метрика | N | p50 | p95 | p99 | Стандартное отклонение |", "|---|---:|---:|---:|---:|---:|"]
        for name, value in metrics.items():
            def fmt(x):
                return "н/д" if x is None else f"{x:.6g}"
            lines.append(f"| {name} | {value['n']} | {fmt(value['p50'])} | {fmt(value['p95'])} | {fmt(value['p99'])} | {fmt(value['stdev'])} |")
        lines.append("")
    if "comparison" in report:
        lines += ["## Изменения относительно baseline", "", "| Сценарий / метрика | Разница p50 | Разница, % |", "|---|---:|---:|"]
        for scene, metrics in report["comparison"].items():
            for name, value in metrics.items():
                percent = value["p50_delta_percent"]
                lines.append(f"| {scene} / {name} | {value['p50_delta']:.6g} | {'н/д' if percent is None else format(percent, '.4g')} |")
    return "\n".join(lines) + "\n"


def parser():
    result = argparse.ArgumentParser(description="Изолированные performance-сцены Tavern (macOS, Python stdlib). Нужен видимый unlocked экран; никаких моделей/сети.")
    result.add_argument("--app", type=Path, required=True, help="Путь к собранной .app; оригинал не изменяется")
    result.add_argument("--herdr", default=shutil.which("herdr"), help="Установленный herdr; не скачивается")
    result.add_argument("--profile", choices=("normal", "loaded"), default="normal", help="normal: 5 tabs/1 output; loaded: 20 tabs/multiple output")
    result.add_argument("--output", type=Path, required=True, help="Новый каталог отчёта JSON/Markdown; существующий не перезаписывается")
    result.add_argument("--scenario", choices=SCENARIOS, action="append", help="Повторяемый выбор сцен; по умолчанию все восемь")
    result.add_argument("--duration", type=float, help="Секунды каждой measured фазы (smoke-вариация; обычно 20, sustained 300)")
    result.add_argument("--repetitions", type=int, default=3, help="Независимые clean-session повторения, по умолчанию 3")
    result.add_argument("--recorder", choices=("off", "minimal", "detailed"), default="minimal",
                        help="Режим instrumentation; off исключает stage/counter показатели, detailed включает signposts. Baseline требует тот же режим.")
    result.add_argument("--baseline", type=Path, help="JSON прежнего отчёта; строгая проверка env/workload до дельт, mismatch = error")
    result.add_argument("--visual", action="store_true", help="После measured pass снять control frames только собственного окна")
    return result


def main():
    cli_parser = parser()
    args = cli_parser.parse_args()
    if args.repetitions < 1 or (args.duration is not None and (not math.isfinite(args.duration) or args.duration <= 0)):
        cli_parser.error("repetitions >= 1, duration > 0 и finite")
    if sys.platform != "darwin":
        cli_parser.error("Требуется macOS")
    if not args.herdr or not Path(args.herdr).is_file():
        cli_parser.error("herdr не найден; установка/скачивание не выполняется")
    args.herdr = str(Path(args.herdr).resolve())
    args.app = args.app.resolve()
    if not (args.app / "Contents" / "Info.plist").is_file():
        cli_parser.error("app не является собранным bundle")
    args.output = args.output.resolve()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    args.tab_count = 5 if args.profile == "normal" else 20
    args.diagnostics = []
    scenes = list(dict.fromkeys(args.scenario or SCENARIOS))
    args.herdr_version = command([args.herdr, "--version"])
    args.herdr_sha = digest(Path(args.herdr))
    info = plistlib.loads((args.app / "Contents" / "Info.plist").read_bytes())
    binary = args.app / "Contents" / "MacOS" / info["CFBundleExecutable"]
    report = {"schema": SCHEMA, "valid": False, "runs": [], "environment": {},
              "diagnostics": args.diagnostics,
              "artifact": {"app_binary_sha256": digest(binary), "app_bundle_sha256": tree_digest(args.app),
                           "suite_sha256": tree_digest(ROOT), "current_toolchain": optional_command(["/usr/bin/xcrun", "swiftc", "--version"])},
              "workload": {"profile": args.profile, "scenarios": scenes, "repetitions": args.repetitions,
                           "duration_override_seconds": args.duration, "duration_variation": "smoke" if args.duration is not None else "standard",
                           "standard_seconds": 20, "sustained_seconds": 300, "tabs": args.tab_count,
                           "fixture_version": FIXTURE_VERSION, "burst_rate_hz": 10,
                           "recorder": args.recorder,
                           "fixture_sha256": digest(ROOT / "fixture.py"), "schedule_revision": 3,
                           "quiet": True, "animation_states": ["working", "blocked", "idle"],
                           "animation_state_interval_seconds": 1,
                           "recovery_standard_seconds": 5, "recovery_smoke_cap_seconds": 2,
                           "visual": args.visual, "width": 1200, "height": 800},
              "unavailable_metrics": ["energy", "physical_input_to_screen", "tearing"]
                                     + (["stages", "counters", "gauges"] if args.recorder == "off" else []),
              "notes": ["SHA приложения сохранён в artifact, но намеренно исключён из идентичности среды: разные сборки можно сравнивать.",
                        "PTY-последовательность детерминирована индексом панели и tick; RNG и seed не используются.",
                        "IDs сессии и панелей создаются заново для изоляции; зависящее от них seed-derived оформление карточек между запусками не обязано быть пиксельно идентичным.",
                        "Визуальный проход — контрольный, а не pixel-baseline; production-путь оформления и его seed не переопределяются.",
                        "Квантили стадий взяты из гистограмм recorder отдельно для каждого повторения; они не вычитаются и не объединяются.",
                        "null в power_source или current_toolchain означает недоступные сведения, а не вычисленное предположение.",
                        "current_toolchain описывает установленный сейчас Swift toolchain, а не подтверждённое происхождение сборки.",
                        "refresh_hz — номинальная максимальная частота дисплея, не измеренная частота presentation; refresh_kind указывает источник.",
                        "null в low_power_mode или refresh_kind означает недоступные сведения, а не вычисленное предположение.",
                        "Во всех режимах recorder используется одинаковое расписание опросов bridge и снимков метрик фаз."]}
    exit_code = 0
    try:
        def interrupt(*_):
            raise KeyboardInterrupt()
        signal.signal(signal.SIGTERM, interrupt)
        baseline = None
        if args.baseline:
            baseline = json.loads(args.baseline.read_text())
            from comparison import validate_report
            validate_report(baseline)
            try:
                validate_baseline_artifacts(report, baseline)
            except ValueError as error:
                raise BenchmarkError(str(error)) from None
            if baseline["workload"] != report["workload"]:
                raise BenchmarkError("baseline_workload_mismatch")
        for scene in scenes:
            for repetition in range(args.repetitions):
                run = run_once(args, scene, repetition)
                if report["environment"] and report["environment"] != run["environment"]:
                    raise BenchmarkError("environment_drift_between_runs")
                report["environment"] = run["environment"]
                if baseline and baseline["environment"] != run["environment"]:
                    raise BenchmarkError("baseline_environment_mismatch")
                report["runs"].append(run)
                atomic_json(args.output / "report.json", report)
        report["valid"] = True
        report["summary"] = {scene: summarize([r for r in report["runs"] if r["scenario"] == scene]) for scene in scenes}
        if baseline:
            report["comparison"] = compare(report, baseline)
    except KeyboardInterrupt:
        report["error"], exit_code = "interrupted", 130
    except (BenchmarkError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        report["error"] = str(error) if isinstance(error, BenchmarkError) else type(error).__name__
        if isinstance(error, BenchmarkError) and error.metadata:
            report["error_metadata"] = error.metadata
        exit_code = 1
    finally:
        if exit_code:
            report["valid"] = False
        atomic_json(args.output / "report.json", report)
        (args.output / "report.md").write_text(markdown(report))
    print(f"{'VALID' if report['valid'] else 'INVALID'}: {args.output / 'report.json'}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
