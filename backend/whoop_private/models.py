"""Tolerant decoding helpers for important private-API reads.

Unknown or missing fields become None / empty defaults. Bad types never raise
AttributeError; callers get clear WhoopDecodeError only when the top-level
payload is not a JSON object at all.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from typing import Any, Iterable

from .errors import WhoopDecodeError

_NUM_RE = re.compile(r"[-+]?\d[\d,]*(?:\.\d+)?")


def as_object(value: Any, *, label: str = "payload") -> dict[str, Any]:
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    raise WhoopDecodeError(f"Expected JSON object for {label}, got {type(value).__name__}")


def as_str(value: Any) -> str | None:
    return value if isinstance(value, str) and value != "" else None


def as_bool(value: Any) -> bool | None:
    return value if isinstance(value, bool) else None


def as_number(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        return parse_number(value)
    return None


def parse_number(text: str | None) -> float | None:
    if not text:
        return None
    match = _NUM_RE.search(text.replace(",", ""))
    if not match:
        return None
    try:
        return float(match.group(0))
    except ValueError:
        return None


def label_to_number(text: str | None) -> float | None:
    return parse_number(text)


def time_to_ms(text: str | None) -> int | None:
    if not text:
        return None
    parts = text.strip().split(":")
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return None
    if len(nums) == 2:
        return ((nums[0] * 60) + nums[1]) * 60 * 1000
    if len(nums) == 3:
        return ((nums[0] * 3600) + (nums[1] * 60) + nums[2]) * 1000
    return None


def ms_to_min(ms: float | None) -> int | None:
    if ms is None:
        return None
    return int(round(ms / 60_000))


def walk_items(node: Any) -> Iterable[dict[str, Any]]:
    """Yield objects that look like BFF items: {type, content}."""
    if isinstance(node, list):
        for child in node:
            yield from walk_items(child)
        return
    if not isinstance(node, dict):
        return
    if isinstance(node.get("type"), str) and isinstance(node.get("content"), dict):
        yield {"type": node["type"], "content": node["content"], "raw": node}
    for value in node.values():
        yield from walk_items(value)


def find_by_type(node: Any, type_name: str) -> dict[str, Any] | None:
    for item in walk_items(node):
        if item["type"] == type_name:
            content = item["content"]
            # Merge common scalar fields from the item itself.
            merged = dict(content)
            raw = item.get("raw") or {}
            for key in ("value", "bpm", "zone", "updated_at", "timestamp", "score", "title"):
                if key in raw and key not in merged:
                    merged[key] = raw[key]
            return merged
    # Also search for a dict that literally has matching type even without content.
    def search(obj: Any) -> dict[str, Any] | None:
        if isinstance(obj, list):
            for child in obj:
                found = search(child)
                if found:
                    return found
            return None
        if not isinstance(obj, dict):
            return None
        if obj.get("type") == type_name:
            return obj
        for value in obj.values():
            found = search(value)
            if found:
                return found
        return None

    return search(node)


def to_dict(model: Any) -> dict[str, Any]:
    if hasattr(model, "__dataclass_fields__"):
        return asdict(model)
    if isinstance(model, dict):
        return model
    raise TypeError(f"Cannot convert {type(model)!r} to dict")


@dataclass
class StressTimelinePoint:
    started_at: str | None = None
    ended_at: str | None = None
    level: float | None = None


@dataclass
class StressReading:
    date: str
    current_level: float | None = None
    peak_level: float | None = None
    min_level: float | None = None
    stress_state: str | None = None
    calibration_state: str | None = None
    timeline: list[StressTimelinePoint] = field(default_factory=list)
    raw_keys: list[str] = field(default_factory=list)


@dataclass
class LiveStressReading:
    current_level: float | None = None
    calibration_state: str | None = None
    stress_state: str | None = None
    last_updated_at: str | None = None


@dataclass
class StrainTarget:
    value: float | None = None
    optimal_lower: float | None = None
    optimal_upper: float | None = None


@dataclass
class StrainReading:
    date: str
    score: float | None = None
    target: StrainTarget = field(default_factory=StrainTarget)
    steps: float | None = None
    strength_activity_time_ms: int | None = None
    zone_1_3_ms: int | None = None
    zone_4_5_ms: int | None = None
    workouts_count: int = 0
    raw_keys: list[str] = field(default_factory=list)


@dataclass
class RecoveryReading:
    date: str
    score: float | None = None
    hrv: float | None = None
    resting_hr: float | None = None
    respiratory_rate: float | None = None
    sleep_performance: float | None = None
    spo2: float | None = None
    skin_temp: float | None = None
    raw_keys: list[str] = field(default_factory=list)


@dataclass
class SleepStageTotals:
    awake_ms: int | None = None
    light_ms: int | None = None
    slow_wave_ms: int | None = None
    rem_ms: int | None = None
    no_data_ms: int | None = None
    in_bed_ms: int | None = None


@dataclass
class SleepHypnogramPoint:
    clock_label: str | None = None
    stage: str | None = None
    value: float | None = None


@dataclass
class SleepDeepDive:
    date: str
    performance: float | None = None
    efficiency: float | None = None
    consistency: float | None = None
    stages: SleepStageTotals = field(default_factory=SleepStageTotals)
    hypnogram: list[SleepHypnogramPoint] = field(default_factory=list)
    raw_keys: list[str] = field(default_factory=list)


@dataclass
class SleepNeedReading:
    recommended_time_in_bed: str | None = None
    recommended_time_in_bed_minutes: int | None = None
    baseline_minutes: int | None = None
    debt_minutes: int | None = None
    strain_minutes: int | None = None
    nap_credit_minutes: int | None = None
    schedule_state: str | None = None
    smart_alarm_eligible: bool | None = None
    next_schedule_day: str | None = None
    raw_keys: list[str] = field(default_factory=list)


@dataclass
class LiveHrReading:
    current_bpm: int | None = None
    hr_zone: int | None = None
    is_recording: bool = False
    show_live_hr: bool | None = None
    last_updated_at: str | None = None


@dataclass
class LiveUserState:
    state: str | None = None
    start_at: str | None = None
    source: str | None = None
    tracked_sleep: bool | None = None
    activity: dict[str, Any] = field(default_factory=dict)
    latest_metrics_processed: Any = None
    raw_keys: list[str] = field(default_factory=list)


@dataclass
class WorkoutDetail:
    activity_id: str
    title: str | None = None
    strain: float | None = None
    average_hr: float | None = None
    max_hr: float | None = None
    calories: float | None = None
    zone_durations: dict[str, Any] = field(default_factory=dict)
    hr_curve_point_count: int = 0
    msk: dict[str, Any] = field(default_factory=dict)
    raw_keys: list[str] = field(default_factory=list)


@dataclass
class TrendReading:
    metric: str
    end_date: str
    header: str | None = None
    raw_keys: list[str] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict, repr=False)


def _clock_label_to_minutes(label: str | None) -> int | None:
    if not label:
        return None
    match = re.match(
        r"^\s*(\d{1,2}):(\d{2})\s*(AM|PM)?\s*$",
        label,
        flags=re.IGNORECASE,
    )
    if not match:
        return None
    hour = int(match.group(1))
    minute = int(match.group(2))
    ampm = (match.group(3) or "").upper()
    if ampm == "PM" and hour != 12:
        hour += 12
    if ampm == "AM" and hour == 12:
        hour = 0
    return hour * 60 + minute


def _wall_clock_iso(date: str, minutes: int) -> str:
    hour, minute = divmod(max(0, minutes) % (24 * 60), 60)
    return f"{date}T{hour:02d}:{minute:02d}:00"


def _downsample(items: list[Any], max_points: int) -> list[Any]:
    if len(items) <= max_points:
        return items
    step = len(items) / max_points
    out = [items[int(i * step)] for i in range(max_points)]
    if out[-1] is not items[-1]:
        out.append(items[-1])
    return out


def decode_stress(raw: Any, date: str, *, max_timeline: int = 48) -> StressReading:
    root = as_object(raw, label="stress")
    gauge = root.get("gauge") if isinstance(root.get("gauge"), dict) else {}
    stress_graph = root.get("stress_graph") if isinstance(root.get("stress_graph"), dict) else {}
    graph = stress_graph.get("graph") if isinstance(stress_graph.get("graph"), dict) else {}

    points: list[tuple[int, float | None]] = []
    plots = graph.get("plots") if isinstance(graph.get("plots"), list) else []
    for plot_wrap in plots:
        if not isinstance(plot_wrap, dict):
            continue
        plot = plot_wrap.get("plot") if isinstance(plot_wrap.get("plot"), dict) else {}
        for seg in plot.get("segments") if isinstance(plot.get("segments"), list) else []:
            if not isinstance(seg, dict):
                continue
            for pt in seg.get("points") if isinstance(seg.get("points"), list) else []:
                if not isinstance(pt, dict):
                    continue
                dsd = pt.get("data_scrubber_details")
                if not isinstance(dsd, dict):
                    continue
                clock = _clock_label_to_minutes(as_str(dsd.get("primary_contextual_display")))
                if clock is None:
                    continue
                points.append((clock, label_to_number(as_str(dsd.get("value_display")))))

    levels = [level for _, level in points if level is not None]
    current = label_to_number(as_str(gauge.get("gauge_score_display")))
    if current is None and levels:
        current = levels[-1]
    calibrating = as_str(root.get("calibration_text_display")) is not None or as_str(
        root.get("stress_state")
    ) == "CALIBRATING"
    sampled = _downsample(points, max_timeline)
    timeline: list[StressTimelinePoint] = []
    for index, (clock, level) in enumerate(sampled):
        next_clock = sampled[index + 1][0] if index + 1 < len(sampled) else clock
        timeline.append(
            StressTimelinePoint(
                started_at=_wall_clock_iso(date, clock),
                ended_at=_wall_clock_iso(date, next_clock),
                level=level,
            )
        )
    return StressReading(
        date=date,
        current_level=current,
        peak_level=max(levels) if levels else None,
        min_level=min(levels) if levels else None,
        stress_state=as_str(root.get("stress_state")),
        calibration_state="CALIBRATING" if calibrating else "CALIBRATED",
        timeline=timeline,
        raw_keys=sorted(root.keys()),
    )


def decode_live_stress(raw: Any, date: str) -> LiveStressReading:
    full = decode_stress(raw, date)
    last = full.timeline[-1].ended_at if full.timeline else None
    return LiveStressReading(
        current_level=full.current_level,
        calibration_state=full.calibration_state,
        stress_state=full.stress_state,
        last_updated_at=last,
    )


def _contributor_status(metrics: list[Any], suffix: str) -> str | None:
    for metric in metrics:
        if not isinstance(metric, dict):
            continue
        ident = as_str(metric.get("id")) or ""
        if ident.upper().endswith(suffix.upper()):
            return as_str(metric.get("status"))
    return None


def decode_strain(raw: Any, date: str) -> StrainReading:
    root = as_object(raw, label="strain")
    items = list(walk_items(root))
    gauge = next(
        (
            item["content"]
            for item in items
            if item["type"] == "SCORE_GAUGE" and as_str(item["content"].get("id")) == "STRAIN_SCORE_GAUGE"
        ),
        {},
    )
    contributors = next(
        (
            item["content"]
            for item in items
            if item["type"] == "CONTRIBUTORS_TILE"
            and as_str(item["content"].get("id")) == "STRAIN_CONTRIBUTORS_TILE"
        ),
        {},
    )
    metrics = contributors.get("metrics") if isinstance(contributors.get("metrics"), list) else []
    score = parse_number(as_str(gauge.get("score_display")))
    target_frac = as_number(gauge.get("score_target"))
    lower = as_number(gauge.get("lower_optimal_percentage"))
    upper = as_number(gauge.get("higher_optimal_percentage"))
    max_strain = 21.0
    return StrainReading(
        date=date,
        score=score,
        target=StrainTarget(
            value=None if target_frac is None else target_frac * max_strain,
            optimal_lower=None if lower is None else lower * max_strain,
            optimal_upper=None if upper is None else upper * max_strain,
        ),
        steps=parse_number(_contributor_status(metrics, "STEPS")),
        strength_activity_time_ms=time_to_ms(_contributor_status(metrics, "STRENGTH_TRAINING_TIME")),
        zone_1_3_ms=time_to_ms(_contributor_status(metrics, "HR_ZONES_1_3")),
        zone_4_5_ms=time_to_ms(_contributor_status(metrics, "HR_ZONES_4_5")),
        workouts_count=sum(1 for item in items if item["type"] == "ACTIVITY"),
        raw_keys=sorted(root.keys()),
    )


def decode_recovery(raw: Any, date: str) -> RecoveryReading:
    root = as_object(raw, label="recovery")
    items = list(walk_items(root))
    gauge = next(
        (
            item["content"]
            for item in items
            if item["type"] == "SCORE_GAUGE"
            and (as_str(item["content"].get("id")) or "").endswith("RECOVERY_SCORE_GAUGE")
        ),
        {},
    )
    contributors = next(
        (
            item["content"]
            for item in items
            if item["type"] == "CONTRIBUTORS_TILE"
            and "RECOVERY_CONTRIBUTORS" in (as_str(item["content"].get("id")) or "")
        ),
        {},
    )
    metrics = contributors.get("metrics") if isinstance(contributors.get("metrics"), list) else []

    def metric_value(suffix: str) -> float | None:
        status = _contributor_status(metrics, suffix)
        return parse_number(status)

    return RecoveryReading(
        date=date,
        score=parse_number(as_str(gauge.get("score_display"))),
        hrv=metric_value("HRV"),
        resting_hr=metric_value("RHR"),
        respiratory_rate=metric_value("RESPIRATORY_RATE"),
        sleep_performance=metric_value("SLEEP_PERFORMANCE"),
        spo2=metric_value("SPO2"),
        skin_temp=metric_value("SKIN_TEMPERATURE"),
        raw_keys=sorted(root.keys()),
    )


def decode_sleep_deep_dive(raw: Any, date: str) -> SleepDeepDive:
    root = as_object(raw, label="sleep")
    stages = SleepStageTotals()
    hypnogram: list[SleepHypnogramPoint] = []
    performance = efficiency = consistency = None

    # Prefer explicit totals when present; otherwise scrape display strings.
    for item in walk_items(root):
        content = item["content"]
        title = (as_str(content.get("title")) or as_str(content.get("name_display")) or "").upper()
        if "SLEEP PERFORMANCE" in title:
            performance = performance or parse_number(
                as_str(content.get("score_display")) or as_str(content.get("value_display"))
            )
        if "EFFICIENCY" in title:
            efficiency = efficiency or parse_number(
                as_str(content.get("score_display")) or as_str(content.get("value_display"))
            )
        if "CONSISTENCY" in title:
            consistency = consistency or parse_number(
                as_str(content.get("score_display")) or as_str(content.get("value_display"))
            )
        # Hypnogram-ish points
        for pt in content.get("points") if isinstance(content.get("points"), list) else []:
            if not isinstance(pt, dict):
                continue
            hypnogram.append(
                SleepHypnogramPoint(
                    clock_label=as_str(pt.get("primary_contextual_display") or pt.get("x_display")),
                    stage=as_str(pt.get("stage") or pt.get("secondary_contextual_display")),
                    value=as_number(pt.get("value")) or parse_number(as_str(pt.get("value_display"))),
                )
            )

    # Stage totals sometimes live under stage_summary-like keys.
    def dig_ms(*keys: str) -> int | None:
        node: Any = root
        for key in keys:
            if not isinstance(node, dict):
                return None
            node = node.get(key)
        num = as_number(node)
        return int(num) if num is not None else None

    stages.awake_ms = dig_ms("stage_summary", "total_awake_time_milli")
    stages.light_ms = dig_ms("stage_summary", "total_light_sleep_time_milli")
    stages.slow_wave_ms = dig_ms("stage_summary", "total_slow_wave_sleep_time_milli")
    stages.rem_ms = dig_ms("stage_summary", "total_rem_sleep_time_milli")
    stages.no_data_ms = dig_ms("stage_summary", "total_no_data_time_milli")
    stages.in_bed_ms = dig_ms("stage_summary", "total_in_bed_time_milli")

    return SleepDeepDive(
        date=date,
        performance=performance,
        efficiency=efficiency,
        consistency=consistency,
        stages=stages,
        hypnogram=hypnogram[:500],
        raw_keys=sorted(root.keys()),
    )


def decode_sleep_need(raw: Any) -> SleepNeedReading:
    root = as_object(raw, label="sleep_need")
    need = root.get("need_breakdown") if isinstance(root.get("need_breakdown"), dict) else {}
    rec = (
        root.get("recommended_time_in_bed_formatted")
        if isinstance(root.get("recommended_time_in_bed_formatted"), dict)
        else {}
    )
    tier = rec.get("85") if isinstance(rec.get("85"), dict) else {}
    return SleepNeedReading(
        recommended_time_in_bed=as_str(tier.get("recommended_time_in_bed_time_string")),
        recommended_time_in_bed_minutes=ms_to_min(as_number(tier.get("recommended_time_in_bed"))),
        baseline_minutes=ms_to_min(as_number(need.get("baseline"))),
        debt_minutes=ms_to_min(as_number(need.get("debt"))),
        strain_minutes=ms_to_min(as_number(need.get("strain"))),
        nap_credit_minutes=ms_to_min(as_number(need.get("naps"))),
        schedule_state=as_str(root.get("alarm_schedule_state")),
        smart_alarm_eligible=as_bool(root.get("eligible_for_smart_alarms")),
        next_schedule_day=as_str(root.get("next_schedule_day_label")),
        raw_keys=sorted(root.keys()),
    )


def decode_live_hr(raw: Any) -> LiveHrReading:
    root = as_object(raw, label="health_tab")
    show = as_bool(root.get("show_live_hr"))
    tile = (
        find_by_type(root, "LIVE_HR")
        or find_by_type(root, "HEART_RATE_LIVE")
        or find_by_type(root, "LIVE_HEART_RATE_TILE")
    ) or {}
    bpm = as_number(tile.get("value") if "value" in tile else tile.get("bpm"))
    zone = as_number(tile.get("zone"))
    zone_i = int(zone) if zone is not None and 0 <= zone <= 5 else None
    bpm_i = int(round(bpm)) if bpm is not None else None
    return LiveHrReading(
        current_bpm=bpm_i,
        hr_zone=zone_i,
        is_recording=bpm_i is not None and (show is True),
        show_live_hr=show,
        last_updated_at=as_str(tile.get("updated_at") or tile.get("timestamp")),
    )


def decode_user_state(raw: Any) -> LiveUserState:
    root = as_object(raw, label="user_state")
    activity = root.get("activity") if isinstance(root.get("activity"), dict) else {}
    return LiveUserState(
        state=as_str(root.get("state")),
        start_at=as_str(root.get("startAt") or root.get("start_at")),
        source=as_str(root.get("source")),
        tracked_sleep=as_bool(root.get("trackedSleep")),
        activity=activity,
        latest_metrics_processed=root.get("latestMetricsProcessed"),
        raw_keys=sorted(root.keys()),
    )


def decode_workout_detail(raw: Any, activity_id: str) -> WorkoutDetail:
    root = as_object(raw, label="cardio_details")
    title_bar = root.get("title_bar") if isinstance(root.get("title_bar"), dict) else {}
    horizontal = root.get("horizontal_stat") if isinstance(root.get("horizontal_stat"), dict) else {}
    strain_breakdown = (
        root.get("strain_breakdown") if isinstance(root.get("strain_breakdown"), dict) else {}
    )
    bar = root.get("bar_graph_container") if isinstance(root.get("bar_graph_container"), dict) else {}
    zones = bar.get("heart_rate_zones") if isinstance(bar.get("heart_rate_zones"), dict) else bar.get(
        "heart_rate_zones", {}
    )
    graph = root.get("graph_response") if isinstance(root.get("graph_response"), dict) else {}
    curve_points = 0
    # Count HR curve points if present under common keys.
    for key in ("points", "values", "samples"):
        value = graph.get(key)
        if isinstance(value, list):
            curve_points = max(curve_points, len(value))
    plots = graph.get("plots") if isinstance(graph.get("plots"), list) else []
    for plot_wrap in plots:
        if not isinstance(plot_wrap, dict):
            continue
        plot = plot_wrap.get("plot") if isinstance(plot_wrap.get("plot"), dict) else plot_wrap
        for seg in plot.get("segments") if isinstance(plot.get("segments"), list) else []:
            if isinstance(seg, dict) and isinstance(seg.get("points"), list):
                curve_points += len(seg["points"])

    msk = root.get("weightlifting_cardio_details")
    msk_obj = msk if isinstance(msk, dict) else {}

    strain = (
        parse_number(as_str(horizontal.get("value_display")))
        or as_number(strain_breakdown.get("strain"))
        or parse_number(as_str(title_bar.get("score_display")))
    )
    return WorkoutDetail(
        activity_id=activity_id,
        title=as_str(title_bar.get("title") or title_bar.get("name_display") or root.get("title")),
        strain=strain,
        average_hr=as_number(root.get("average_heart_rate"))
        or parse_number(as_str((root.get("metadata") or {}).get("average_heart_rate_display"))
                        if isinstance(root.get("metadata"), dict)
                        else None),
        max_hr=as_number(root.get("max_heart_rate")),
        calories=as_number(root.get("calories")) or parse_number(as_str(root.get("calories_display"))),
        zone_durations=zones if isinstance(zones, dict) else {},
        hr_curve_point_count=curve_points,
        msk=msk_obj,
        raw_keys=sorted(root.keys()),
    )


def decode_trend(raw: Any, metric: str, end_date: str) -> TrendReading:
    root = as_object(raw, label=f"trend:{metric}")
    return TrendReading(
        metric=metric,
        end_date=end_date,
        header=as_str(root.get("header_name_display")),
        raw_keys=sorted(root.keys()),
        raw=root,
    )
