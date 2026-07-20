#!/usr/bin/env python3
"""Select verified etcd backup sets for tiered retention.

The input is a JSON array returned from S3 ListObjectsV2. Only snapshots with
an adjacent .db.json success marker participate in automatic deletion. This
keeps incomplete, legacy, and otherwise unrecognised objects fail-closed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from collections import OrderedDict


SNAPSHOT = re.compile(
    r"^etcd/(?P<year>\d{4})/(?P<month>\d{2})/(?P<day>\d{2})/"
    r"(?P<stamp>\d{8}T\d{6}Z)-(?P<run>[A-Za-z0-9._-]+)\.db$"
)


def nonnegative(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("retention values cannot be negative")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--recent", type=nonnegative, default=28)
    parser.add_argument("--daily", type=nonnegative, default=7)
    parser.add_argument("--weekly", type=nonnegative, default=4)
    parser.add_argument("--monthly", type=nonnegative, default=3)
    return parser.parse_args()


def backup_sets(inventory: list[dict]) -> list[dict]:
    keys = {item.get("Key", "") for item in inventory}
    snapshots: list[dict] = []
    for item in inventory:
        key = item.get("Key", "")
        match = SNAPSHOT.fullmatch(key)
        if not match or f"{key}.json" not in keys or item.get("VerifiedSet") is not True:
            continue
        timestamp = dt.datetime.strptime(match.group("stamp"), "%Y%m%dT%H%M%SZ").replace(
            tzinfo=dt.timezone.utc
        )
        relative = key.removeprefix("etcd/").removesuffix(".db")
        recovery = f"control-plane/{relative}.tar.age"
        objects = [key, f"{key}.json"]
        for candidate in (recovery, f"{recovery}.json"):
            if candidate in keys:
                objects.append(candidate)
        snapshots.append(
            {
                "key": key,
                "timestamp": timestamp,
                "objects": objects,
                "bytes": int(item.get("Size", 0)),
            }
        )
    return sorted(snapshots, key=lambda item: item["timestamp"], reverse=True)


def first_per_bucket(snapshots: list[dict], bucket, count: int) -> list[dict]:
    selected: OrderedDict[object, dict] = OrderedDict()
    for snapshot in snapshots:
        key = bucket(snapshot["timestamp"])
        selected.setdefault(key, snapshot)
    return list(selected.values())[:count]


def plan(inventory: list[dict], recent: int, daily: int, weekly: int, monthly: int) -> dict:
    if recent < 2:
        raise ValueError("recent retention must be at least 2")
    snapshots = backup_sets(inventory)
    reasons: dict[str, set[str]] = {}

    def keep(items: list[dict], reason: str) -> None:
        for item in items:
            reasons.setdefault(item["key"], set()).add(reason)

    keep(snapshots[:recent], "recent")
    keep(first_per_bucket(snapshots, lambda value: value.date(), daily), "daily")
    keep(
        first_per_bucket(
            snapshots,
            lambda value: (value.isocalendar().year, value.isocalendar().week),
            weekly,
        ),
        "weekly",
    )
    keep(first_per_bucket(snapshots, lambda value: (value.year, value.month), monthly), "monthly")

    retained = []
    deleted = []
    for snapshot in snapshots:
        output = {
            "key": snapshot["key"],
            "createdAt": snapshot["timestamp"].isoformat().replace("+00:00", "Z"),
            "bytes": snapshot["bytes"],
        }
        if snapshot["key"] in reasons:
            output["reasons"] = sorted(reasons[snapshot["key"]])
            retained.append(output)
        else:
            output["objects"] = snapshot["objects"]
            deleted.append(output)

    return {
        "policy": {"recent": recent, "daily": daily, "weekly": weekly, "monthly": monthly},
        "eligibleBackupSets": len(snapshots),
        "retainedBackupSets": retained,
        "deleteBackupSets": deleted,
        "deleteObjects": [obj for item in deleted for obj in item["objects"]],
    }


def main() -> None:
    args = parse_args()
    inventory = json.load(sys.stdin)
    if not isinstance(inventory, list):
        raise SystemExit("inventory must be a JSON array")
    try:
        result = plan(inventory, args.recent, args.daily, args.weekly, args.monthly)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    json.dump(result, sys.stdout, separators=(",", ":"), sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
