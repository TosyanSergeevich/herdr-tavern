"""Чистые алгоритмы статистики и проверки сопоставимости (stdlib)."""
import math
import statistics

SCENARIOS = ("idle", "animations", "output", "tabs", "interaction", "panels", "resize", "sustained")
SCHEMA = 1


def quantile(values, fraction):
    """Линейная интерполяция ранга (N-1)*p; пустая выборка — null."""
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * fraction
    lo, hi = math.floor(rank), math.ceil(rank)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (rank - lo)


def stats(values):
    if any(not isinstance(x, (int, float)) or isinstance(x, bool) or not math.isfinite(x) for x in values):
        raise ValueError("non_finite_sample")
    return {"n": len(values), "p50": quantile(values, .5), "p95": quantile(values, .95),
            "p99": quantile(values, .99), "min": min(values) if values else None,
            "max": max(values) if values else None,
            "mean": statistics.fmean(values) if values else None,
            "stdev": statistics.stdev(values) if len(values) > 1 else None}


def action_latency_stats(events):
    return stats([event["input_to_draw_ns"] for event in events
                  if event.get("input_to_draw_ns") is not None and event.get("no_change") is not True])


def flatten(value, prefix=""):
    out = {}
    for key, item in value.items():
        name = f"{prefix}.{key}" if prefix else key
        if isinstance(item, dict):
            out.update(flatten(item, name))
        elif isinstance(item, (int, float)) and not isinstance(item, bool):
            if not math.isfinite(item):
                raise ValueError("non_finite_metric")
            out[name] = item
    return out


def metric_delta(before, after):
    """Only cumulative counts/totals/resources admit subtraction; quantiles do not."""
    first, last = flatten(before), flatten(after)
    result = {}
    for key, value in last.items():
        if after.get("enabled") is False and key.startswith(("stages.", "counters.", "gauges.")):
            continue
        cumulative = (key.startswith("counters.") or key.endswith((".count", ".total_ns"))
                      or key in ("resources.cpu_seconds", "resources.disk_write_bytes", "resources.sample_count"))
        if cumulative:
            if key not in first or value < first[key]:
                raise ValueError(f"counter_discontinuity:{key}")
            result[key] = value - first[key]
    return result


def summarize(runs):
    result = {}
    for run in runs:
        for key, value in run.get("measurement", {}).items():
            result.setdefault(key, []).append(value)
    return {key: stats(values) for key, values in sorted(result.items())}


def validate_artifact(report):
    artifact = report.get("artifact")
    if not isinstance(artifact, dict):
        raise ValueError("missing_artifact")
    suite = artifact.get("suite_sha256")
    if not isinstance(suite, str) or len(suite) != 64 or any(char not in "0123456789abcdef" for char in suite):
        raise ValueError("invalid_suite_sha256")
    if "current_toolchain" not in artifact:
        raise ValueError("missing_current_toolchain")
    toolchain = artifact["current_toolchain"]
    if toolchain is not None and (not isinstance(toolchain, str) or not toolchain.strip()):
        raise ValueError("invalid_current_toolchain")
    return artifact


def validate_baseline_artifacts(current, baseline):
    now, old = validate_artifact(current), validate_artifact(baseline)
    if now["suite_sha256"] != old["suite_sha256"]:
        raise ValueError("baseline_suite_mismatch")
    if now["current_toolchain"] != old["current_toolchain"]:
        raise ValueError("baseline_current_toolchain_mismatch")


def validate_report(report):
    if report.get("schema") != SCHEMA or report.get("valid") is not True:
        raise ValueError("invalid_report")
    validate_artifact(report)
    if not isinstance(report.get("environment"), dict) or not report["environment"]:
        raise ValueError("missing_environment")
    workload = report.get("workload", {})
    if workload.get("profile") not in ("normal", "loaded") or not workload.get("scenarios"):
        raise ValueError("invalid_workload")
    runs = report.get("runs", [])
    expected = {(scene, rep) for scene in workload["scenarios"] for rep in range(workload["repetitions"])}
    actual = {(run.get("scenario"), run.get("repetition")) for run in runs}
    if actual != expected or len(runs) != len(expected):
        raise ValueError("incomplete_runs")
    for run in runs:
        if run.get("valid") is not True or run.get("correctness") is not True:
            raise ValueError("invalid_run")
        if run.get("environment") != report["environment"]:
            raise ValueError("environment_drift")
        if not run.get("measurement"):
            raise ValueError("missing_measurement")
        stats(list(run["measurement"].values()))
    return report


def compare(current, baseline):
    validate_report(current)
    validate_report(baseline)
    validate_baseline_artifacts(current, baseline)
    if current["environment"] != baseline["environment"]:
        raise ValueError("baseline_environment_mismatch")
    if current["workload"] != baseline["workload"]:
        raise ValueError("baseline_workload_mismatch")
    result = {}
    for scene in current["workload"]["scenarios"]:
        now = summarize([r for r in current["runs"] if r["scenario"] == scene])
        old = summarize([r for r in baseline["runs"] if r["scenario"] == scene])
        if now.keys() != old.keys():
            raise ValueError("baseline_metric_set_mismatch")
        result[scene] = {}
        for key, value in now.items():
            previous = old[key]
            delta = value["p50"] - previous["p50"]
            result[scene][key] = {"current": value, "baseline": previous, "p50_delta": delta,
                                  "p50_delta_percent": delta / previous["p50"] * 100 if previous["p50"] else None}
    return result


def schedule(scenario, duration, tabs):
    """Deterministic offsets; readiness delays never trigger catch-up event storms."""
    if scenario not in SCENARIOS or not math.isfinite(duration) or duration <= 0 or tabs < 1:
        raise ValueError("invalid_schedule")
    interval = {"idle": 1, "animations": 1, "output": 1, "tabs": .4,
                "interaction": .5, "panels": .6, "resize": .8, "sustained": .5}[scenario]
    count = max(1, math.ceil(duration / interval))
    return [(index * interval, index) for index in range(count) if index * interval < duration]
