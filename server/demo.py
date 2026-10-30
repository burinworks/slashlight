"""Fills a database with made-up reports, for trying the dashboard locally:

    SECRET=dev DATA_DIR=demo-data PUBLIC_DIR=dashboard python3 demo.py && python3 -m http.server -d dashboard
"""

import os
import random
import uuid
from datetime import datetime, timedelta, timezone

from collector import connect, store

random.seed(7)
EXTENSIONS = {"apps": 40, "window-switcher": 14, "terminal": 9, "clipboard": 9, "calculator": 7, "files": 6,
              "window-management": 5, "snippets": 3, "emoji": 3, "system": 2, "insights": 1, "external": 2}


def report(install, day, profile):
    actions = max(1, int(random.gauss(profile["rate"], profile["rate"] / 3)))
    picks = random.choices(list(EXTENSIONS), weights=[w * profile["taste"].get(e, 1) for e, w in EXTENSIONS.items()], k=actions)
    by_ext = {e: picks.count(e) for e in set(picks)}
    ranked = actions - by_ext.get("calculator", 0)
    first = int(ranked * random.uniform(0.7, 0.95))
    clicks = int(actions * profile["mouse"])
    return {
        "schema": 1, "install": install, "day": day.isoformat(),
        "app": {"version": profile["version"], "build": 1, "channel": profile["channel"]},
        "system": {"macos": profile["macos"], "arch": profile["arch"], "region": profile["region"], "language": profile["language"]},
        "settings": {"hotkey": profile["hotkey"], "appearance": profile["appearance"], "disabled": profile["disabled"],
                     "externalExtensions": profile["external"]},
        "usage": {"opens": actions + random.randint(0, 6), "actions": actions, "byExtension": by_ext,
                  "inputs": {"key": actions - clicks - 1, "click": clicks, "number": 1},
                  "firstResult": first, "ranked": ranked, "latencyP50": random.randint(900, 2200),
                  "queryLengthP50": random.randint(2, 5)},
    }


def main():
    os.makedirs(os.environ.get("DATA_DIR", "data"), exist_ok=True)
    db = connect()
    today = datetime.now(timezone.utc).date()
    for n in range(420):
        start = today - timedelta(days=int(random.triangular(0, 75, 5)))
        loyalty = random.random()
        profile = {
            "rate": random.choice([8, 15, 25, 40]), "mouse": random.choice([0.02, 0.05, 0.2]),
            "taste": {random.choice(list(EXTENSIONS)): 3},
            "version": random.choices(["0.4.0", "0.3.1", "0.3.0", "0.5.0-beta.2"], weights=[50, 25, 10, 15])[0],
            "macos": random.choices(["26.1", "26.0", "15.6", "14.7"], weights=[45, 25, 22, 8])[0],
            "arch": random.choices(["arm64", "x86_64"], weights=[88, 12])[0],
            "region": random.choices(["US", "DE", "GB", "RU", "FR", "NL", "IN", "BR", "JP", "PL"], weights=[30, 14, 10, 8, 7, 6, 6, 5, 4, 3])[0],
            "language": random.choices(["en", "de", "ru", "fr", "ja"], weights=[60, 12, 10, 8, 4])[0],
            "hotkey": random.choices(["opt+space", "cmd+space", "ctrl+space", "cmd+shift+space"], weights=[50, 35, 10, 5])[0],
            "appearance": random.choices(["system", "dark", "light"], weights=[70, 22, 8])[0],
            "disabled": random.sample(["files", "web-search", "emoji", "clipboard"], k=random.choice([0, 0, 0, 1, 2])),
            "external": random.choice([0, 0, 0, 1, 2, 4]), "channel": "stable",
        }
        if profile["version"].endswith("beta.2"):
            profile["channel"] = "beta"
        install = str(uuid.uuid4()).upper()
        day = start
        while day <= today - timedelta(days=1):
            if random.random() < (0.85 if day.weekday() < 5 else 0.35):
                r = report(install, day, profile)
                store(db, install, {k: v for k, v in r.items() if k != "install"})
            day += timedelta(days=1)
            if random.random() > 0.97 + loyalty * 0.029:  # churn
                break
    print("demo data written")


if __name__ == "__main__":
    main()
