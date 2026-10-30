import json
import os
import sqlite3
import sys
import threading
import unittest
import urllib.request
from datetime import date, timedelta
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import collector  # noqa: E402
import aggregate  # noqa: E402

TODAY = date(2026, 10, 30)
INSTALL = "1F0C6A0E-5E5B-4C55-9E0B-0C1D2E3F4A5B"


def report(day="2026-10-29", install=INSTALL, **usage):
    u = {"opens": 5, "actions": 4, "byExtension": {"apps": 3, "external": 1}, "inputs": {"key": 3, "click": 1},
         "firstResult": 3, "ranked": 4, "latencyP50": 1200, "queryLengthP50": 3}
    u.update(usage)
    return {"schema": 1, "install": install, "day": day,
            "app": {"version": "0.4.0", "build": 7, "channel": "stable"},
            "system": {"macos": "26.1", "arch": "arm64", "region": "DE", "language": "en"},
            "settings": {"hotkey": "opt+space", "appearance": "system", "disabled": [], "externalExtensions": 1},
            "usage": u}


def memory_db():
    return collector.connect(":memory:")


class ValidateTests(unittest.TestCase):
    def test_accepts_a_good_report_and_drops_the_id(self):
        install, clean = collector.validate(report(), today=TODAY)
        self.assertEqual(install, INSTALL)
        self.assertNotIn("install", clean)
        self.assertEqual(clean["usage"]["byExtension"], {"apps": 3, "external": 1})

    def test_drops_unknown_fields(self):
        r = report()
        r["usage"]["secretQuery"] = "my bank password"
        r["extra"] = "x"
        _, clean = collector.validate(r, today=TODAY)
        self.assertNotIn("secretQuery", json.dumps(clean))
        self.assertNotIn("extra", clean)

    def test_rejects_bad_input(self):
        bad = [
            {**report(), "schema": 2},
            {**report(), "install": "not-a-uuid"},
            report(day="2020-01-01"),
            report(day="2026-13-01"),
            report(actions=-1),
            report(firstResult=9, ranked=4),
            report(byExtension={"Has Spaces": 1}),
            report(inputs={"telepathy": 1}),
        ]
        for r in bad:
            with self.assertRaises(collector.Invalid, msg=json.dumps(r)[:80]):
                collector.validate(r, today=TODAY)

    def test_hash_is_keyed_and_case_insensitive(self):
        self.assertEqual(collector.install_hash(INSTALL, "a"), collector.install_hash(INSTALL.lower(), "a"))
        self.assertNotEqual(collector.install_hash(INSTALL, "a"), collector.install_hash(INSTALL, "b"))
        self.assertNotIn(INSTALL.lower(), collector.install_hash(INSTALL, "a"))


class StoreTests(unittest.TestCase):
    def test_one_row_per_install_and_day(self):
        db = memory_db()
        for _ in range(3):
            install, clean = collector.validate(report(), today=TODAY)
            collector.store(db, install, clean)
        install, clean = collector.validate(report(day="2026-10-28"), today=TODAY)
        collector.store(db, install, clean)
        self.assertEqual(db.execute("SELECT count(*) FROM reports").fetchone()[0], 2)
        first, last = db.execute("SELECT first_day, last_day FROM installs").fetchone()
        self.assertEqual((first, last), ("2026-10-28", "2026-10-29"))
        self.assertNotIn(INSTALL, json.dumps(db.execute("SELECT * FROM reports").fetchall()))


class AggregateTests(unittest.TestCase):
    def seed(self, installs=8, days=10):
        db = memory_db()
        for n in range(installs):
            install = f"00000000-0000-4000-8000-{n:012d}"
            for d in range(days if n < installs - 1 else 1):
                r = report(day=(TODAY - timedelta(days=d + 1)).isoformat(), install=install)
                r["system"]["region"] = "IS" if n == 0 else "DE"  # one rare region
                _, clean = collector.validate(r, today=TODAY - timedelta(days=d))
                collector.store(db, install, clean)
        return db

    def test_builds_stats(self):
        stats = aggregate.build(self.seed(), today=TODAY, k=5)
        last = stats["daily"][-1]
        self.assertEqual(last["day"], "2026-10-29")
        self.assertEqual(last["dau"], 8)
        self.assertEqual(last["mau"], 8)
        self.assertEqual(stats["totals"]["installs"], 8)
        self.assertEqual(stats["current"]["firstResultRate"], 0.75)
        apps = next(e for e in stats["current"]["extensions"] if e["id"] == "apps")
        self.assertEqual(apps["share"], 1.0)

    def test_small_groups_are_folded_into_other(self):
        stats = aggregate.build(self.seed(), today=TODAY, k=5)
        regions = {r["key"]: r["installs"] for r in stats["current"]["regions"]}
        self.assertEqual(regions, {"DE": 7, "Other": 1})

    def test_too_few_installs_hide_rates(self):
        stats = aggregate.build(self.seed(installs=3), today=TODAY, k=5)
        self.assertIsNone(stats["current"]["firstResultRate"])
        self.assertEqual(stats["current"]["extensions"], [])

    def test_prune_keeps_daily_aggregates(self):
        db = self.seed()
        aggregate.build(db, today=TODAY)
        aggregate.prune(db, today=TODAY + timedelta(days=200))
        self.assertEqual(db.execute("SELECT count(*) FROM reports").fetchone()[0], 0)
        self.assertGreater(db.execute("SELECT count(*) FROM daily").fetchone()[0], 0)


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        collector.SECRET = "test"
        cls.db = memory_db()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), collector.make_handler(cls.db, collector.RateLimiter(limit=5)))
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def post(self, body):
        req = urllib.request.Request(self.url + "/v1/report", data=body, method="POST", headers={"Content-Type": "application/json"})
        try:
            return urllib.request.urlopen(req).status
        except urllib.error.HTTPError as e:
            return e.code

    def test_endpoints(self):
        today = date.today()
        self.assertEqual(urllib.request.urlopen(self.url + "/health").read(), b"ok")
        self.assertEqual(self.post(json.dumps(report(day=(today - timedelta(days=1)).isoformat())).encode()), 204)
        self.assertEqual(self.post(b"{not json"), 400)
        self.assertEqual(self.post(b"x" * (collector.MAX_BODY + 1)), 413)
        statuses = [self.post(b"{}") for _ in range(5)]
        self.assertEqual(statuses[-1], 429)


if __name__ == "__main__":
    unittest.main()
