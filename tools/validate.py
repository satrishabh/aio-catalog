#!/usr/bin/env python3
"""Validates every catalog entry. Same rules as the AIO platform (ConnectorCatalog) plus repo checks.

  python tools/validate.py            rules only (fast, offline)
  python tools/validate.py --render   also helm-template every managed entry at version and previousVersion with
                                      each cloud / site overlay (needs helm and network)
Exit code 1 on any error.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIELDS = {"id", "name", "category", "description", "kind", "phase", "clouds", "requires", "namespace", "deployment",
          "chartRepo", "chart", "version", "previousVersion", "releaseName", "valuesPath", "cloudValues", "siteValues",
          "extrasPath", "probes", "accessHint", "license", "foundation", "origin", "homepage", "sso", "pinNote"}
CLOUDS = {"any", "gke", "eks", "aks", "oke", "onprem"}
ID = re.compile(r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")
NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
VERSION = re.compile(r"^v?[0-9]+(\.[0-9]+){1,2}([-+][0-9A-Za-z.-]+)?$")
REL_YAML = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.ya?ml$")
REL_DIR = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$")
# OSI-approved licenses only (POLICY.md). Source-available licenses are rejected outright.
OSI = ("Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause", "MPL-2.0", "ISC", "LGPL-2.1", "LGPL-3.0", "GPL-2.0",
       "GPL-3.0", "AGPL-3.0", "EPL-2.0")
NOT_OSI = ("BSL", "BUSL", "SSPL", "Elastic", "ELv2", "FSL", "Commons Clause", "Sustainable Use", "RSAL", "CSL")
SSO_MODES = {"oidc", "proxy", "none"}


def entries():
    out = []
    for path in sorted(glob.glob(os.path.join(ROOT, "catalog", "**", "*.yaml"), recursive=True)):
        out.append((path, yaml.safe_load(open(path, encoding="utf-8"))))
    return out


def check(path, e, ids, errors):
    where = os.path.relpath(path, ROOT)

    def err(msg):
        errors.append(f"{where}: {msg}")

    unknown = set(e) - FIELDS
    if unknown:
        err(f"unknown keys {sorted(unknown)}")
    if not ID.match(str(e.get("id", ""))):
        err("invalid id")
    if os.path.splitext(os.path.basename(path))[0] != e.get("id"):
        err("file name must be <id>.yaml")
    for f in ("name", "category", "description", "license", "foundation", "homepage"):
        if not e.get(f):
            err(f"{f} is required")
    lic = str(e.get("license", ""))
    if any(bad.lower() in lic.lower() for bad in NOT_OSI) or not any(ok in lic for ok in OSI):
        err(f"license {lic!r} is not OSI-approved (POLICY.md)")
    if e.get("homepage") and not str(e["homepage"]).startswith("https://"):
        err("homepage must be https")
    for cl in e.get("clouds") or []:
        if cl not in CLOUDS:
            err(f"unknown cloud {cl}")
    for r in e.get("requires") or []:
        if r not in ids or r == e.get("id"):
            err(f"requires unknown connector {r}")
    sso = e.get("sso")
    if sso is not None:
        if sso.get("mode") not in SSO_MODES:
            err("sso.mode must be oidc, proxy or none")
        if sso.get("mode") == "oidc" and not str(sso.get("clientId", "")).startswith("aio-"):
            err("sso.clientId must start with aio-")
    kind = e.get("kind")
    if kind not in ("core", "managed", "planned"):
        err("kind must be core, managed or planned")
    if kind == "core" and not (NAME.match(str(e.get("namespace", ""))) and NAME.match(str(e.get("deployment", "")))):
        err("core needs namespace and deployment")
    if e.get("chartRepo") and not str(e["chartRepo"]).startswith("https://"):
        err("chartRepo must be https")
    for v in ("version", "previousVersion"):
        if e.get(v) is not None and not VERSION.match(str(e[v])):
            err(f"{v} must be an exact version")
    if kind == "managed":
        for f in ("namespace", "releaseName", "chart", "chartRepo", "version", "valuesPath"):
            if not e.get(f):
                err(f"managed needs {f}")
        for f in ("namespace", "releaseName", "chart"):
            if e.get(f) and not NAME.match(str(e[f])):
                err(f"invalid {f}")
        files = [e.get("valuesPath")] + list((e.get("cloudValues") or {}).values()) + list((e.get("siteValues") or {}).values())
        for f in filter(None, files):
            if not REL_YAML.match(f) or ".." in f:
                err(f"{f}: must be a relative .yaml path")
            elif not os.path.isfile(os.path.join(ROOT, f)):
                err(f"{f}: file missing")
        for cl in e.get("cloudValues") or {}:
            if cl not in CLOUDS or cl == "any":
                err(f"cloudValues key {cl} must be a cloud")
        for site in e.get("siteValues") or {}:
            if not NAME.match(site):
                err(f"siteValues key {site} must be a short name")
        x = e.get("extrasPath")
        if x and (not REL_DIR.match(x) or ".." in x or not os.path.isdir(os.path.join(ROOT, x))):
            err(f"extrasPath {x}: must be an existing relative directory")
        for p in e.get("probes") or []:
            u = urlparse(str(p.get("url", "")))
            if u.scheme not in ("http", "https") or not u.hostname or u.username \
                    or not (u.hostname.endswith(".svc") or u.hostname.endswith(".svc.cluster.local")):
                err(f"probe {p.get('name')}: url must be http(s)://<service>.<namespace>.svc")


def render(path, e, errors):
    combos = [[]] + [[v] for v in (e.get("cloudValues") or {}).values()] + [[v] for v in (e.get("siteValues") or {}).values()]
    for version in filter(None, [e.get("version"), e.get("previousVersion")]):
        with tempfile.TemporaryDirectory() as d:
            p = subprocess.run(["helm", "pull", e["chart"], "--repo", e["chartRepo"], "--version", str(version), "-d", d],
                               capture_output=True, text=True)
            if p.returncode:
                errors.append(f"{e['id']}@{version}: helm pull failed: {p.stderr.strip()[-200:]}")
                continue
            tgz = os.path.join(d, os.listdir(d)[0])
            for extra in combos:
                cmd = ["helm", "template", e["releaseName"], tgz, "-n", e["namespace"], "--skip-tests",
                       "-f", os.path.join(ROOT, e["valuesPath"])] + sum((["-f", os.path.join(ROOT, x)] for x in extra), [])
                t = subprocess.run(cmd, capture_output=True, text=True)
                label = f"{e['id']}@{version}" + (f" + {extra[0]}" if extra else "")
                if t.returncode:
                    errors.append(f"{label}: helm template failed: {t.stderr.strip()[-300:]}")
                else:
                    print(f"rendered {label}: {t.stdout.count(chr(10) + 'kind: ')} objects")


def main():
    all_entries = entries()
    ids = [e.get("id") for _, e in all_entries]
    errors = [f"duplicate id {i}" for i in sorted({i for i in ids if ids.count(i) > 1})]
    for path, e in all_entries:
        check(path, e, set(ids), errors)
    if "--render" in sys.argv:
        for path, e in all_entries:
            if e.get("kind") == "managed":
                render(path, e, errors)
    for x in errors:
        print("ERROR", x)
    kinds = {k: sum(1 for _, e in all_entries if e.get("kind") == k) for k in ("core", "managed", "planned")}
    print(f"{len(all_entries)} entries ({kinds['core']} core, {kinds['managed']} managed, {kinds['planned']} planned): "
          f"{'FAILED' if errors else 'ok'}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
