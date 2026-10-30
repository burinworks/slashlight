"""Turns raw reports into public/stats.json for the dashboard, then deletes raw reports older than 90 days.

Run it hourly. Every number on the public dashboard comes from the file this writes, and nothing else is kept
except per-day aggregates (table `daily`) and each install hash's first and last active day (for retention).
"""

import json
import os
import statistics
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone

from collector import DATA_DIR, connect

PUBLIC_DIR = os.environ.get("PUBLIC_DIR", "public")
RETENTION_DAYS = 90
# Breakdowns only show values reported by at least this many installs; the rest become "Other".
K = int(os.environ.get("K_THRESHOLD", "5"))
WINDOW = 30  # days covered by the "current" breakdowns


def load(db, since):
    rows = db.execute("SELECT install, day, payload FROM reports WHERE day >= ?", (since.isoformat(),)).fetchall()
    return [(install, date.fromisoformat(day), json.loads(payload)) for install, day, payload in rows]


def anonymize(counter, k=K):
    """[{key, installs}] sorted by count, with every value below k folded into "Other"."""
    shown = [(key, n) for key, n in counter.most_common() if n >= k]
    hidden = sum(n for key, n in counter.items() if n < k)
    out = [{"key": key, "installs": n} for key, n in shown]
    if hidden:
        out.append({"key": "Other", "installs": hidden})
    return out


def day_stats(reports, day):
    """Aggregates for one day from the reports of the 30 days up to it."""
    on = [r for r in reports if r[1] == day]
    week = {r[0] for r in reports if day - timedelta(days=6) <= r[1] <= day}
    month = {r[0] for r in reports if day - timedelta(days=29) <= r[1] <= day}
    actions = [p["usage"]["actions"] for _, _, p in on]
    return {
        "day": day.isoformat(),
        "dau": len({r[0] for r in on}),
        "wau": len(week),
        "mau": len(month),
        "actions": sum(actions),
        "actionsPerInstall": statistics.median(actions) if actions else 0,
    }


def build(db, today=None, k=K):
    today = today or datetime.now(timezone.utc).date()
    since = today - timedelta(days=RETENTION_DAYS)
    reports = load(db, since)

    # Per-day series: recompute the days we still have raw data for, keep older ones from the `daily` table.
    days_with_data = sorted({r[1] for r in reports})
    first_seen = dict(db.execute("SELECT install, first_day FROM installs").fetchall())
    new_per_day = Counter(first_seen.values())
    # Days near the start of the raw window lack the 30 days before them that WAU/MAU need; their stored values,
    # computed while that data still existed, are better than a recomputation now.
    complete_from = since + timedelta(days=29)
    with db:
        for d in (d for d in days_with_data if d >= complete_from or not db.execute(
                "SELECT 1 FROM daily WHERE day = ?", (d.isoformat(),)).fetchone()):
            s = day_stats(reports, d)
            s["new"] = new_per_day.get(d.isoformat(), 0)
            db.execute("INSERT INTO daily (day, stats) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET stats = excluded.stats",
                       (d.isoformat(), json.dumps(s)))
    daily = [json.loads(s) for (s,) in db.execute("SELECT stats FROM daily ORDER BY day")]

    # Current breakdowns: each install active in the last 30 days, counted once, from its latest report.
    window_start = today - timedelta(days=WINDOW)
    latest = {}
    usage_by_install = defaultdict(lambda: {"actions": 0, "byExtension": Counter(), "inputs": Counter(),
                                            "firstResult": 0, "ranked": 0, "latency": [], "query": []})
    for install, d, p in sorted(reports, key=lambda r: r[1]):
        if d < window_start:
            continue
        latest[install] = p
        u, src = usage_by_install[install], p["usage"]
        u["actions"] += src["actions"]
        u["byExtension"].update(src["byExtension"])
        u["inputs"].update(src["inputs"])
        u["firstResult"] += src["firstResult"]
        u["ranked"] += src["ranked"]
        if src.get("latencyP50") is not None:
            u["latency"].append(src["latencyP50"])
        if src.get("queryLengthP50") is not None:
            u["query"].append(src["queryLengthP50"])

    def breakdown(get):
        return anonymize(Counter(v for v in (get(p) for p in latest.values()) if v is not None), k)

    ext_installs, ext_actions, inputs = Counter(), Counter(), Counter()
    first, ranked, latencies, queries = 0, 0, [], []
    for u in usage_by_install.values():
        ext_installs.update(u["byExtension"].keys())
        ext_actions.update(u["byExtension"])
        inputs.update(u["inputs"])
        first += u["firstResult"]
        ranked += u["ranked"]
        if u["latency"]:
            latencies.append(statistics.median(u["latency"]))
        if u["query"]:
            queries.append(statistics.median(u["query"]))
    active = len(latest)
    disabled = Counter(x for p in latest.values() for x in p["settings"]["disabled"])

    current = {
        "window": WINDOW,
        "activeInstalls": active,
        "extensions": [
            {"id": e, "installs": n, "share": round(n / active, 4) if active else 0, "actions": ext_actions[e]}
            for e, n in ext_installs.most_common() if n >= k
        ],
        "versions": breakdown(lambda p: p["app"]["version"]),
        "channels": breakdown(lambda p: p["app"]["channel"]),
        "macos": breakdown(lambda p: p["system"]["macos"]),
        "arch": breakdown(lambda p: p["system"]["arch"]),
        "regions": breakdown(lambda p: p["system"].get("region")),
        "languages": breakdown(lambda p: p["system"].get("language")),
        "hotkeys": breakdown(lambda p: p["settings"]["hotkey"]),
        "appearance": breakdown(lambda p: p["settings"]["appearance"]),
        "disabled": [{"key": e, "installs": n} for e, n in disabled.most_common() if n >= k],
        "inputs": dict(inputs) if active >= k else {},
        "firstResultRate": round(first / ranked, 4) if ranked and active >= k else None,
        "medianLatency": round(statistics.median(latencies)) if len(latencies) >= k else None,
        "medianQueryLength": statistics.median(queries) if len(queries) >= k else None,
    }

    return {
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "threshold": k,
        "totals": {"installs": len(first_seen), "activeInstalls30d": active},
        "daily": daily,
        "current": current,
        "retention": retention(db, today, k),
    }


def retention(db, today, k=K):
    """Weekly cohorts by first active day: share still active 1, 2 and 4 weeks later.

    Uses each install's first and last active day, so "still active after N weeks" means "seen on or after week N".
    """
    rows = db.execute("SELECT first_day, last_day FROM installs").fetchall()
    cohorts = defaultdict(list)
    for first, last in rows:
        f = date.fromisoformat(first)
        monday = f - timedelta(days=f.weekday())
        cohorts[monday].append((f, date.fromisoformat(last)))
    out = []
    for monday in sorted(cohorts)[-12:]:
        members = cohorts[monday]
        if len(members) < k:
            continue
        row = {"cohort": monday.isoformat(), "size": len(members)}
        for weeks in (1, 2, 4):
            if monday + timedelta(weeks=weeks + 1) > today:
                row[f"w{weeks}"] = None  # not enough time has passed
            else:
                row[f"w{weeks}"] = round(sum(1 for f, l in members if l >= f + timedelta(weeks=weeks)) / len(members), 4)
        out.append(row)
    return out


def prune(db, today=None):
    today = today or datetime.now(timezone.utc).date()
    with db:
        db.execute("DELETE FROM reports WHERE day < ?", ((today - timedelta(days=RETENTION_DAYS)).isoformat(),))


def main():
    db = connect()
    stats = build(db)
    prune(db)
    os.makedirs(PUBLIC_DIR, exist_ok=True)
    tmp = os.path.join(PUBLIC_DIR, "stats.json.tmp")
    with open(tmp, "w") as f:
        json.dump(stats, f, separators=(",", ":"))
    os.replace(tmp, os.path.join(PUBLIC_DIR, "stats.json"))
    print(f"wrote stats.json: {stats['totals']['installs']} installs, {len(stats['daily'])} days", flush=True)


if __name__ == "__main__":
    os.makedirs(DATA_DIR, exist_ok=True)
    main()
