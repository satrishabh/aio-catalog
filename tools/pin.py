#!/usr/bin/env python3
"""Pin chart versions in the catalog.

For every entry with chartRepo + chart, finds the newest stable chart version released at least MIN_AGE_DAYS ago
(default 14) and the one before it (the rollback target).

  python tools/pin.py              report: what would change (no writes)
  python tools/pin.py --write      write version/previousVersion into planned entries that have none yet
  python tools/pin.py --write --all also move managed entries (review the chart's release notes first)

Managed entries are never changed without --all, because a new chart version can need values changes.
"""
import datetime as dt
import glob
import os
import re
import sys
import urllib.request

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIN_AGE_DAYS = int(os.environ.get("MIN_AGE_DAYS", "14"))
STABLE = re.compile(r"^v?\d+\.\d+\.\d+$")
Loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)


def index(repo, cache={}):
    if repo not in cache:
        url = repo.rstrip("/") + "/index.yaml"
        req = urllib.request.Request(url, headers={"User-Agent": "aio-catalog-pin"})
        with urllib.request.urlopen(req, timeout=120) as r:
            cache[repo] = yaml.load(r.read(), Loader=Loader)
    return cache[repo]


def created(e):
    c = e.get("created")
    if isinstance(c, dt.datetime):
        return c if c.tzinfo else c.replace(tzinfo=dt.timezone.utc)
    if not c:
        return None
    # Helm writes nanoseconds; Python accepts at most microseconds
    s = re.sub(r"(\.\d{6})\d+", r"\1", str(c).replace("Z", "+00:00"))
    return dt.datetime.fromisoformat(s)


def vkey(v):
    return tuple(int(x) for x in v.lstrip("v").split("."))


def pick(repo, chart):
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=MIN_AGE_DAYS)
    entries = index(repo).get("entries", {}).get(chart)
    if not entries:
        raise LookupError(f"chart {chart} not in {repo}")
    ok = sorted({e["version"] for e in entries if STABLE.match(str(e["version"]))
                 and (created(e) is None or created(e) <= cutoff)}, key=vkey, reverse=True)
    if not ok:
        raise LookupError(f"no stable {chart} version older than {MIN_AGE_DAYS} days")
    return ok[0], (ok[1] if len(ok) > 1 else None)


def main():
    write, move_managed = "--write" in sys.argv, "--all" in sys.argv
    failed = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "catalog", "**", "*.yaml"), recursive=True)):
        text = open(path, encoding="utf-8").read()
        e = yaml.safe_load(text)
        if not (e.get("chartRepo") and e.get("chart")):
            continue
        try:
            latest, previous = pick(e["chartRepo"], e["chart"])
        except Exception as ex:  # noqa: BLE001 - report and continue
            failed += 1
            print(f"FAIL  {e['id']:<24} {ex}")
            continue
        current = e.get("version")
        status = "ok" if current == latest else ("new" if not current else "behind")
        print(f"{status:<5} {e['id']:<24} pinned={current or '-':<12} latest>={MIN_AGE_DAYS}d={latest:<12} previous={previous}")
        if write and (not current or (move_managed and current != latest)):
            if e.get("kind") == "managed" and not move_managed:
                continue
            e["version"], e["previousVersion"] = latest, previous
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                yaml.safe_dump(e, f, sort_keys=False, allow_unicode=True, width=110)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
