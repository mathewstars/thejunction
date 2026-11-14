"""Generates a small synthetic Apple Health export.xml (same element shapes as a real export) for testing
AppleHealthXMLImporter and HealthSummaryBuilder. 30 days by default. Not a real person.

    python3 make_example_health_export.py --out apple-health-export-synthetic.xml --days 30 --seed 11 \
        --end 2026-11-14
"""

from __future__ import annotations

import argparse
import math
import random
from datetime import datetime, timedelta, timezone

TZ = timezone(timedelta(hours=2))  # Europe/Helsinki in November


def fmt(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M:%S %z")


def record(type_, start, end, value, unit=None, source="Apple Watch", device=None, meta=None) -> str:
    attrs = [f'type="{type_}"', f'sourceName="{source}"', 'sourceVersion="11.1"']
    if device:
        attrs.append(f'device="{device}"')
    if unit:
        attrs.append(f'unit="{unit}"')
    attrs += [f'creationDate="{fmt(end)}"', f'startDate="{fmt(start)}"', f'endDate="{fmt(end)}"', f'value="{value}"']
    if meta:
        inner = "".join(f'\n  <MetadataEntry key="{k}" value="{v}"/>' for k, v in meta.items())
        return f" <Record {' '.join(attrs)}>{inner}\n </Record>\n"
    return f" <Record {' '.join(attrs)}/>\n"


WATCH = "&lt;&lt;HKDevice: 0x1&gt;, name:Apple Watch, manufacturer:Apple Inc., model:Watch, hardware:Watch7,1, software:11.1&gt;"
PHONE = "&lt;&lt;HKDevice: 0x2&gt;, name:iPhone, manufacturer:Apple Inc., model:iPhone, hardware:iPhone16,1, software:17.6.1&gt;"


def generate(out: str, days: int, seed: int, end_day: datetime) -> dict:
    rnd = random.Random(seed)
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<!DOCTYPE HealthData [', ']>', '<HealthData locale="en_FI">',
             f' <ExportDate value="{fmt(end_day.replace(hour=9))}"/>',
             ' <Me HKCharacteristicTypeIdentifierDateOfBirth="" HKCharacteristicTypeIdentifierBiologicalSex="HKBiologicalSexNotSet" HKCharacteristicTypeIdentifierBloodType="HKBloodTypeNotSet" HKCharacteristicTypeIdentifierFitzpatrickSkinType="HKFitzpatrickSkinTypeNotSet"/>']
    counts = {"records": 0, "workouts": 0}

    def add(s: str) -> None:
        lines.append(s.rstrip("\n"))
        counts["records"] += 1

    for d in range(days):
        day = end_day - timedelta(days=days - 1 - d)
        # A slow drift: week 3 has shorter sleep and lower HRV so longitudinal change is visible.
        dip = 1.0 if not (14 <= d < 21) else 0.8
        # Sleep: previous night 23:10 ± 40 min to 07:00 ± 30 min, stages in 30–90 min blocks.
        bed = day.replace(hour=23, minute=10) - timedelta(days=1) + timedelta(minutes=rnd.randint(-40, 40))
        wake = day.replace(hour=7, minute=0) + timedelta(minutes=rnd.randint(-30, 30)) - timedelta(minutes=int(60 * (1 - dip)))
        t = bed
        add(record("HKCategoryTypeIdentifierSleepAnalysis", bed - timedelta(minutes=10), wake + timedelta(minutes=5), "HKCategoryValueSleepAnalysisInBed", source="iPhone", device=PHONE))
        while t < wake:
            block = timedelta(minutes=rnd.randint(30, 90))
            end = min(t + block, wake)
            stage = rnd.choices(["AsleepCore", "AsleepDeep", "AsleepREM", "Awake"], weights=[5, 2, 2.5, 0.6])[0]
            add(record("HKCategoryTypeIdentifierSleepAnalysis", t, end, f"HKCategoryValueSleepAnalysis{stage}", device=WATCH))
            t = end
        # Respiratory rate and wrist temperature during sleep.
        add(record("HKQuantityTypeIdentifierRespiratoryRate", bed + timedelta(hours=2), bed + timedelta(hours=2, minutes=5), round(rnd.gauss(14.5, 0.8), 1), "count/min", device=WATCH))
        add(record("HKQuantityTypeIdentifierAppleSleepingWristTemperature", bed, wake, round(rnd.gauss(35.6, 0.15), 2), "degC", device=WATCH))
        # HRV: 2–4 readings, mostly at night.
        for _ in range(rnd.randint(2, 4)):
            ts = bed + timedelta(minutes=rnd.randint(30, 420))
            add(record("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", ts, ts + timedelta(minutes=1), round(max(12, rnd.gauss(46 * dip, 9)), 1), "ms", device=WATCH))
        # Resting heart rate, daily.
        add(record("HKQuantityTypeIdentifierRestingHeartRate", day.replace(hour=0), day.replace(hour=23, minute=59), round(rnd.gauss(58 / dip, 2.5)), "count/min", device=WATCH))
        add(record("HKQuantityTypeIdentifierWalkingHeartRateAverage", day.replace(hour=0), day.replace(hour=23, minute=59), round(rnd.gauss(98, 5)), "count/min", device=WATCH))
        # Heart rate every 10 min while awake.
        t = wake
        while t < day.replace(hour=22, minute=30):
            hour = t.hour + t.minute / 60
            base = 62 + 18 * math.exp(-((hour - 17.5) ** 2) / 2) + 6 * math.sin(hour)
            add(record("HKQuantityTypeIdentifierHeartRate", t, t, round(max(45, rnd.gauss(base, 6))), "count/min", device=WATCH, meta={"HKMetadataKeyHeartRateMotionContext": "1"}))
            t += timedelta(minutes=10)
        # Steps: hourly from both iPhone and Watch (overlapping on purpose).
        total = 0
        for h in range(7, 23):
            s = max(0, int(rnd.gauss(600 * dip, 350)))
            if h in (8, 17):
                s += 1500
            total += s
            a, b = day.replace(hour=h), day.replace(hour=h, minute=59)
            add(record("HKQuantityTypeIdentifierStepCount", a, b, s, "count", source="iPhone", device=PHONE))
            add(record("HKQuantityTypeIdentifierStepCount", a, b, int(s * rnd.uniform(0.85, 1.05)), "count", device=WATCH))
            add(record("HKQuantityTypeIdentifierDistanceWalkingRunning", a, b, round(s * 0.00072, 3), "km", source="iPhone", device=PHONE))
            add(record("HKQuantityTypeIdentifierActiveEnergyBurned", a, b, round(s * 0.04 + rnd.uniform(5, 20), 1), "kcal", device=WATCH))
            if rnd.random() < 0.7:
                add(record("HKCategoryTypeIdentifierAppleStandHour", a, b, "HKCategoryValueAppleStandHourStood", device=WATCH))
        add(record("HKQuantityTypeIdentifierAppleExerciseTime", day.replace(hour=17), day.replace(hour=17, minute=30), int(rnd.gauss(28 * dip, 8)), "min", device=WATCH))
        add(record("HKQuantityTypeIdentifierFlightsClimbed", day.replace(hour=12), day.replace(hour=12, minute=5), rnd.randint(2, 14), "count", source="iPhone", device=PHONE))
        add(record("HKQuantityTypeIdentifierWalkingSpeed", day.replace(hour=12, minute=10), day.replace(hour=12, minute=20), round(rnd.gauss(1.32 * dip, 0.08), 2), "km/hr" if False else "m/s", source="iPhone", device=PHONE))
        add(record("HKQuantityTypeIdentifierOxygenSaturation", day.replace(hour=3), day.replace(hour=3, minute=1), round(rnd.uniform(0.95, 0.99), 2), "%", device=WATCH))
        if d % 7 == 0:
            add(record("HKQuantityTypeIdentifierBodyMass", day.replace(hour=7, minute=30), day.replace(hour=7, minute=30), round(72.4 + rnd.gauss(0, 0.4), 1), "kg", source="Scale", device=None))
        if rnd.random() < 0.5:
            add(record("HKQuantityTypeIdentifierDietaryCaffeine", day.replace(hour=8, minute=15), day.replace(hour=8, minute=15), rnd.choice([80, 95, 160]), "mg", source="Coffee app"))
        if rnd.random() < 0.4:
            add(record("HKCategoryTypeIdentifierMindfulSession", day.replace(hour=21), day.replace(hour=21, minute=10), "HKCategoryValueNotApplicable", source="Mindfulness", device=WATCH))
        if rnd.random() < 0.3:
            a = day.replace(hour=17, minute=5)
            b = a + timedelta(minutes=rnd.randint(25, 50))
            lines.append(f' <Workout workoutActivityType="HKWorkoutActivityTypeWalking" duration="{(b - a).total_seconds() / 60:.2f}" durationUnit="min" '
                         f'totalDistance="{rnd.uniform(2.0, 4.5):.3f}" totalDistanceUnit="km" totalEnergyBurned="{rnd.uniform(120, 260):.1f}" totalEnergyBurnedUnit="kcal" '
                         f'sourceName="Apple Watch" sourceVersion="11.1" device="{WATCH}" creationDate="{fmt(b)}" startDate="{fmt(a)}" endDate="{fmt(b)}">\n'
                         f'  <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" startDate="{fmt(a)}" endDate="{fmt(b)}" sum="{rnd.uniform(120, 260):.1f}" unit="kcal"/>\n'
                         f' </Workout>')
            counts["workouts"] += 1
    lines.append("</HealthData>")
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return counts


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="apple-health-export-synthetic.xml")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--end", default="2026-11-14")
    a = ap.parse_args()
    end_day = datetime.strptime(a.end, "%Y-%m-%d").replace(tzinfo=TZ)
    print(generate(a.out, a.days, a.seed, end_day))


if __name__ == "__main__":
    main()
