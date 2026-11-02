"""Запуск после интеграции: python3 -m unittest discover -s tools/performance -p 'test_*.py'."""
import copy
import math
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from comparison import action_latency_stats, compare, metric_delta, quantile, schedule, stats, validate_report
from fixture import burst, marker
from run import BenchmarkError, Bridge, clean_environment, cpu_time, numeric_diagnostic


def report():
    environment = {"os": "test", "scale": 2, "thermal_state": "nominal"}
    return {"schema": 1, "valid": True, "environment": environment,
            "artifact": {"suite_sha256": "a" * 64, "current_toolchain": "Swift test toolchain"},
            "workload": {"profile": "normal", "scenarios": ["idle"], "repetitions": 2},
            "runs": [{"scenario": "idle", "repetition": index, "valid": True,
                      "correctness": True, "environment": environment.copy(),
                      "measurement": {"stage.ns": 10 + index}} for index in range(2)]}


class StatisticsTests(unittest.TestCase):
    def test_quantiles_interpolate_rank(self):
        self.assertEqual(quantile([30, 0, 20, 10], .5), 15)
        self.assertAlmostEqual(quantile([30, 0, 20, 10], .95), 28.5)
        self.assertAlmostEqual(quantile([30, 0, 20, 10], .99), 29.7)

    def test_empty_is_not_zero(self):
        self.assertIsNone(stats([])["p50"])
        self.assertEqual(stats([])["n"], 0)

    def test_one_sample_has_no_variance_estimate(self):
        self.assertEqual(stats([7])["p99"], 7)
        self.assertIsNone(stats([7])["stdev"])

    def test_nonfinite_is_rejected(self):
        for value in (math.inf, math.nan, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                stats([value])

    def test_only_cumulative_metrics_are_subtracted(self):
        before = {"stages": {"draw": {"count": 1, "total_ns": 20, "p95_ns": 20}}, "gauges": {"queue": 4}}
        after = {"stages": {"draw": {"count": 3, "total_ns": 55, "p95_ns": 30}}, "gauges": {"queue": 1}}
        self.assertEqual(metric_delta(before, after), {"stages.draw.count": 2, "stages.draw.total_ns": 35})

    def test_counter_reset_invalidates_delta(self):
        with self.assertRaises(ValueError):
            metric_delta({"counters": {"events": 5}}, {"counters": {"events": 1}})

    def test_disabled_recorder_does_not_report_fake_zero_stages(self):
        before = {"enabled": False, "stages": {"draw": {"count": 0}}, "resources": {"cpu_seconds": 1}}
        after = {"enabled": False, "stages": {"draw": {"count": 0}}, "resources": {"cpu_seconds": 2}}
        self.assertEqual(metric_delta(before, after), {"resources.cpu_seconds": 1})

    def test_action_quantiles_exclude_noops_and_retain_real_draws(self):
        events = [{"input_to_draw_ns": 0, "no_change": True},
                  {"input_to_draw_ns": 100, "no_change": False},
                  {"input_to_draw_ns": None}, {"input_to_draw_ns": 300}]
        result = action_latency_stats(events)
        self.assertEqual(result["n"], 2)
        self.assertEqual(result["p50"], 200)
        self.assertEqual(len(events), 4)

    def test_all_noops_have_no_latency_percentile(self):
        result = action_latency_stats([{"input_to_draw_ns": 0, "no_change": True}])
        self.assertEqual(result["n"], 0)
        self.assertIsNone(result["p50"])


class ScheduleTests(unittest.TestCase):
    def test_all_eight_scenes_are_deterministic_and_bounded(self):
        scenes = ("idle", "animations", "output", "tabs", "interaction", "panels", "resize", "sustained")
        for scene in scenes:
            with self.subTest(scene=scene):
                first = schedule(scene, 2.1, 5)
                self.assertEqual(first, schedule(scene, 2.1, 5))
                self.assertEqual(first[0], (0, 0))
                self.assertTrue(all(0 <= offset < 2.1 for offset, _ in first))
                self.assertEqual([index for _, index in first], list(range(len(first))))

    def test_smoke_still_has_one_action(self):
        self.assertEqual(schedule("tabs", .001, 5), [(0, 0)])

    def test_invalid_duration_and_scene_rejected(self):
        for scene, duration in (("tabs", 0), ("idle", math.inf), ("unknown", 2)):
            with self.subTest(scene=scene, duration=duration), self.assertRaises(ValueError):
                schedule(scene, duration, 5)


class BaselineTests(unittest.TestCase):
    def test_valid_comparison_retains_variance_and_no_score(self):
        current, baseline = report(), report()
        current["runs"][0]["measurement"]["stage.ns"] = 12
        result = compare(current, baseline)
        self.assertEqual(result["idle"]["stage.ns"]["p50_delta"], 1)
        self.assertEqual(result["idle"]["stage.ns"]["current"]["n"], 2)
        self.assertNotIn("score", result)

    def test_invalid_baseline_has_no_deltas(self):
        baseline = report()
        baseline["valid"] = False
        with self.assertRaisesRegex(ValueError, "invalid_report"):
            compare(report(), baseline)

    def test_different_suite_hash_rejects_comparison(self):
        baseline = report()
        baseline["artifact"]["suite_sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "baseline_suite_mismatch"):
            compare(report(), baseline)

    def test_missing_suite_hash_rejects_report(self):
        baseline = report()
        del baseline["artifact"]["suite_sha256"]
        with self.assertRaisesRegex(ValueError, "invalid_suite_sha256"):
            validate_report(baseline)

    def test_different_current_toolchain_rejects_comparison(self):
        baseline = report()
        baseline["artifact"]["current_toolchain"] = "Other Swift toolchain"
        with self.assertRaisesRegex(ValueError, "baseline_current_toolchain_mismatch"):
            compare(report(), baseline)

    def test_toolchain_availability_mismatch_is_not_silently_ignored(self):
        baseline = report()
        baseline["artifact"]["current_toolchain"] = None
        with self.assertRaisesRegex(ValueError, "baseline_current_toolchain_mismatch"):
            compare(report(), baseline)

    def test_different_app_binary_can_compare_with_same_suite_and_toolchain(self):
        current, baseline = report(), report()
        current["artifact"]["app_binary_sha256"] = "c" * 64
        baseline["artifact"]["app_binary_sha256"] = "d" * 64
        self.assertIn("idle", compare(current, baseline))

    def test_environment_mismatch_has_no_deltas(self):
        baseline = report()
        baseline["environment"]["scale"] = 1
        for run in baseline["runs"]:
            run["environment"]["scale"] = 1
        with self.assertRaisesRegex(ValueError, "environment_mismatch"):
            compare(report(), baseline)

    def test_workload_mismatch_has_no_deltas(self):
        baseline = report()
        baseline["workload"]["duration_override"] = 1
        with self.assertRaisesRegex(ValueError, "workload_mismatch"):
            compare(report(), baseline)

    def test_missing_repetition_rejected(self):
        baseline = report()
        baseline["runs"].pop()
        with self.assertRaisesRegex(ValueError, "incomplete_runs"):
            validate_report(baseline)

    def test_recorder_mode_mismatch_is_not_an_environment_bypass(self):
        current, baseline = report(), report()
        current["workload"]["recorder"] = "minimal"
        baseline["workload"]["recorder"] = "off"
        with self.assertRaisesRegex(ValueError, "workload_mismatch"):
            compare(current, baseline)

    def test_duplicate_repetition_rejected(self):
        baseline = report()
        baseline["runs"][1] = copy.deepcopy(baseline["runs"][0])
        with self.assertRaisesRegex(ValueError, "incomplete_runs"):
            validate_report(baseline)

    def test_content_failure_rejected(self):
        baseline = report()
        baseline["runs"][0]["correctness"] = False
        with self.assertRaisesRegex(ValueError, "invalid_run"):
            validate_report(baseline)

    def test_environment_drift_rejected(self):
        baseline = report()
        baseline["runs"][1]["environment"]["scale"] = 1
        with self.assertRaisesRegex(ValueError, "environment_drift"):
            validate_report(baseline)

    def test_metric_set_mismatch_rejected(self):
        baseline = report()
        for run in baseline["runs"]:
            run["measurement"]["extra"] = 1
        with self.assertRaisesRegex(ValueError, "metric_set_mismatch"):
            compare(report(), baseline)

    def test_zero_baseline_percent_is_unknown_not_infinity(self):
        baseline = report()
        for run in baseline["runs"]:
            run["measurement"]["stage.ns"] = 0
        self.assertIsNone(compare(report(), baseline)["idle"]["stage.ns"]["p50_delta_percent"])


class FixtureAndIsolationTests(unittest.TestCase):
    def test_measured_inactive_guard_retains_only_window_flags(self):
        bridge = Bridge(None, None)
        state = {"ready": True, "visible": True, "active": False, "screen_locked": False,
                 "terminal_text": "private", "focused_tab": "private-id"}
        with patch.object(bridge, "request", return_value=state), self.assertRaises(BenchmarkError) as caught:
            bridge.inspect()
        self.assertEqual(str(caught.exception), "window_not_active")
        self.assertEqual(caught.exception.metadata, {"window_state": {
            "ready": True, "visible": True, "active": False, "screen_locked": False}})

    def test_measured_invisible_guard_is_distinct_from_inactive(self):
        bridge = Bridge(None, None)
        state = {"ready": True, "visible": False, "active": False, "screen_locked": False}
        with patch.object(bridge, "request", return_value=state), self.assertRaisesRegex(BenchmarkError, "window_not_visible"):
            bridge.inspect()

    def test_setup_inactive_policy_restores_strict_measured_guard(self):
        bridge = Bridge(None, None)
        state = {"ready": True, "visible": True, "active": False, "screen_locked": False,
                 "width": 1200, "height": 800, "scale": 2, "refresh_hz": 60}
        self.assertTrue(bridge.require_active)
        with patch.object(bridge, "request", return_value=state):
            bridge.require_active = False
            self.assertEqual(bridge.inspect(), state)
            bridge.require_active = True
            with self.assertRaisesRegex(BenchmarkError, "window_not_active"):
                bridge.inspect()

    def test_setup_inactive_policy_keeps_lock_guard(self):
        bridge = Bridge(None, None)
        bridge.require_active = False
        state = {"ready": True, "visible": True, "active": False, "screen_locked": True}
        with patch.object(bridge, "request", return_value=state), self.assertRaisesRegex(BenchmarkError, "screen_locked_or_unknown"):
            bridge.inspect()

    def test_measured_context_drift_rejects_each_frozen_field(self):
        context = {"display_id": 1, "scale": 2, "refresh_hz": 60, "refresh_kind": "nominal_maximum",
                   "animations_enabled": True, "sound_enabled": False}
        replacements = {"display_id": 2, "scale": 1, "refresh_hz": 120, "refresh_kind": "different",
                        "animations_enabled": False, "sound_enabled": True}
        for key, changed in replacements.items():
            with self.subTest(field=key):
                bridge = Bridge(None, None)
                bridge.expected_context = context.copy()
                state = {**context, key: changed, "ready": True, "visible": True, "active": True,
                         "screen_locked": False, "width": 1200, "height": 800}
                with patch.object(bridge, "request", return_value=state), self.assertRaises(BenchmarkError) as caught:
                    bridge.inspect()
                self.assertEqual(str(caught.exception), "environment_context_drift")
                self.assertEqual(caught.exception.metadata["context_fields"], [key])

    def test_measured_resize_does_not_change_frozen_context(self):
        bridge = Bridge(None, None)
        bridge.expected_context = {"scale": 2, "refresh_hz": 60}
        state = {"scale": 2, "refresh_hz": 60, "width": 1400, "height": 900,
                 "ready": True, "visible": True, "active": True, "screen_locked": False}
        with patch.object(bridge, "request", return_value=state):
            self.assertEqual(bridge.inspect(), state)

    def test_diagnostics_exclude_paths_text_and_unknown_schema_fields(self):
        source = {"schema_version": 1, "terminal_text": "secret", "app": {"path": "/user/app"},
                  "resources": {"cpu_seconds": 3, "thermal_state": "nominal", "path": "/user/file"},
                  "stages": {"surfaceDraw": {"count": 2, "total_ns": 100}}}
        value = numeric_diagnostic(source)
        self.assertEqual(value, {"schema_version": 1, "resources": {"cpu_seconds": 3},
                                 "stages": {"surfaceDraw": {"count": 2, "total_ns": 100}}})

    def test_diagnostics_unknown_schema_rejected(self):
        with self.assertRaises(ValueError):
            numeric_diagnostic({"schema_version": 2, "resources": {}})

    def test_fixture_deterministic_unicode_ansi_and_unique_panes(self):
        value = burst(3, 7)
        self.assertEqual(value, burst(3, 7))
        self.assertIn(marker(3), value)
        self.assertNotIn(marker(2), value)
        for token in ("\x1b[", "сборка", "模型", "e\u0301", "progress"):
            self.assertIn(token, value)

    def test_environment_drops_secrets_herdr_and_shell_startup(self):
        with patch.dict(os.environ, {"HOME": "/own", "PATH": "/bin", "HERDR_SESSION": "user", "API_KEY": "secret", "ENV": "/user/startup"}, clear=True):
            result = clean_environment(Path("/isolated"))
        self.assertNotIn("HERDR_SESSION", result)
        self.assertNotIn("API_KEY", result)
        self.assertNotIn("ENV", result)
        self.assertEqual(result["HOME"], "/own")
        self.assertEqual(result["SHELL"], "/bin/sh")
        self.assertEqual(result["XDG_CONFIG_HOME"], "/isolated")

    def test_ps_cpu_time_supports_days_hours_and_fraction(self):
        self.assertEqual(cpu_time("02:03.25"), 123.25)
        self.assertEqual(cpu_time("1-02:03:04"), 93784)


if __name__ == "__main__":
    unittest.main()
