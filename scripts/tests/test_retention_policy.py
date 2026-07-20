import datetime as dt
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "retention_policy.py"
SPEC = importlib.util.spec_from_file_location("retention_policy", MODULE_PATH)
retention_policy = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(retention_policy)


def object_pair(timestamp: dt.datetime, run: int, with_recovery: bool = True):
    stamp = timestamp.strftime("%Y%m%dT%H%M%SZ")
    date = timestamp.strftime("%Y/%m/%d")
    key = f"etcd/{date}/{stamp}-{run}.db"
    objects = [
        {
            "Key": key,
            "LastModified": timestamp.isoformat(),
            "Size": 100 + run,
            "VerifiedSet": True,
        },
        {"Key": f"{key}.json", "LastModified": timestamp.isoformat(), "Size": 100},
    ]
    if with_recovery:
        recovery = f"control-plane/{date}/{stamp}-{run}.tar.age"
        objects.extend(
            [
                {"Key": recovery, "LastModified": timestamp.isoformat(), "Size": 200},
                {"Key": f"{recovery}.json", "LastModified": timestamp.isoformat(), "Size": 100},
            ]
        )
    return objects


class RetentionPolicyTests(unittest.TestCase):
    def test_keeps_recent_and_tiered_recovery_points(self):
        start = dt.datetime(2026, 1, 31, 18, tzinfo=dt.timezone.utc)
        inventory = []
        for run in range(48):
            inventory.extend(object_pair(start - dt.timedelta(hours=6 * run), run))

        result = retention_policy.plan(inventory, recent=4, daily=3, weekly=2, monthly=2)
        retained = result["retainedBackupSets"]
        self.assertGreaterEqual(len(retained), 4)
        self.assertTrue(any("daily" in item["reasons"] for item in retained))
        self.assertTrue(any("weekly" in item["reasons"] for item in retained))
        self.assertTrue(any("monthly" in item["reasons"] for item in retained))
        self.assertEqual(
            len(result["deleteObjects"]),
            4 * len(result["deleteBackupSets"]),
        )

    def test_never_deletes_snapshot_without_success_sidecar(self):
        timestamp = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        inventory = []
        for run in range(5):
            inventory.extend(object_pair(timestamp + dt.timedelta(hours=run), run))
        orphan = "etcd/2025/01/01/20250101T000000Z-orphan.db"
        inventory.append({"Key": orphan, "LastModified": "2025-01-01T00:00:00Z", "Size": 99})

        result = retention_policy.plan(inventory, recent=2, daily=0, weekly=0, monthly=0)
        self.assertNotIn(orphan, result["deleteObjects"])

    def test_never_deletes_unverified_cross_reference(self):
        timestamp = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        inventory = []
        for run in range(4):
            inventory.extend(object_pair(timestamp + dt.timedelta(hours=run), run))
        inventory[0]["VerifiedSet"] = False

        result = retention_policy.plan(inventory, recent=2, daily=0, weekly=0, monthly=0)
        self.assertNotIn(inventory[0]["Key"], result["deleteObjects"])

    def test_requires_two_recent_snapshots(self):
        with self.assertRaisesRegex(ValueError, "at least 2"):
            retention_policy.plan([], recent=1, daily=0, weekly=0, monthly=0)


if __name__ == "__main__":
    unittest.main()
