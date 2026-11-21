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
          "extrasPath", "probes", "accessHint", "license", "foundation", "origin", "homepage", "sso", "pinNote",
          "binding"}
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
# binding: how a project uses a connector (Project -> Services in AIO). Schema: AIO docs/architecture/PROJECT-SERVICES.md
BINDING_FIELDS = {"label", "summary", "scope", "envs", "options", "manifests", "env", "copySecret", "podAnnotations",
                  "exportNote"}
BINDING_SCOPES = {"instance", "shared", "config"}
ENVS = ("dev", "staging", "prod")
PLACEHOLDER = re.compile(r"\$\{([^}]*)\}")
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
OPTION_ID = re.compile(r"^[a-z][a-zA-Z0-9]{0,30}$")
SECRET_KEY = re.compile(r"^[-._a-zA-Z0-9]+$")
ANNOTATION = re.compile(r"^([a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$")
SAMPLE_APP = "shop"            # sample project name for rendering binding templates


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
    check_binding(e, err)


def substitute(text, values):
    """Plain string substitution, as the platform does it. Returns (text, unknown placeholders)."""
    unknown = []

    def repl(m):
        if m.group(1) in values:
            return values[m.group(1)]
        unknown.append(m.group(0))
        return m.group(0)
    return PLACEHOLDER.sub(repl, text), unknown


def check_binding(e, err):
    b = e.get("binding")
    if b is None:
        return
    if not isinstance(b, dict):
        return err("binding must be a mapping")
    if e.get("kind") != "managed":
        err("binding is only allowed on managed entries")
    unknown = set(b) - BINDING_FIELDS
    if unknown:
        err(f"binding: unknown keys {sorted(unknown)}")
    for f in ("label", "summary", "exportNote"):
        if not isinstance(b.get(f), str) or not b[f].strip():
            err(f"binding.{f} is required (text)")
    scope = b.get("scope")
    if scope not in BINDING_SCOPES:
        err("binding.scope must be instance, shared or config")
    envs = b.get("envs", list(ENVS))
    if not isinstance(envs, list) or not envs or len(set(envs)) != len(envs) or not set(envs) <= set(ENVS):
        err("binding.envs must be a non-empty subset of [dev, staging, prod] without repeats")

    values = {"app": SAMPLE_APP, "env": "dev", "namespace": "dev", "name": f"{SAMPLE_APP}-{e.get('id')}"}
    options = b.get("options") or []
    if not isinstance(options, list):
        err("binding.options must be a list")
        options = []
    for o in options:
        if not isinstance(o, dict) or set(o) - {"id", "label", "default", "choices"}:
            err(f"binding.options: {o!r} may only have id, label, default, choices")
            continue
        oid = str(o.get("id", ""))
        if not OPTION_ID.match(oid):
            err(f"binding.options: invalid id {oid!r}")
        if f"opt.{oid}" in values:
            err(f"binding.options: duplicate id {oid}")
        if not isinstance(o.get("label"), str) or not o["label"]:
            err(f"binding.options.{oid}: label is required")
        choices = o.get("choices")
        if not isinstance(choices, list) or not choices or not all(isinstance(c, str) and c for c in choices):
            err(f"binding.options.{oid}: choices must be a non-empty list of strings (quote numbers)")
            choices = []
        if not isinstance(o.get("default"), str) or o["default"] not in choices:
            err(f"binding.options.{oid}: default must be a string and one of the choices")
        values[f"opt.{oid}"] = str(o.get("default"))

    def placeholders(text, what):
        out, bad = substitute(str(text), values)
        for p in bad:
            err(f"binding.{what}: unknown placeholder {p}")
        return out

    copy = b.get("copySecret")
    if copy is not None:
        if scope != "shared":
            err("binding.copySecret is only allowed with scope shared")
        if not isinstance(copy, dict) or set(copy) != {"from", "keys", "name"}:
            err("binding.copySecret needs exactly from, keys and name")
            copy = None
        else:
            if not NAME.match(str(copy["from"])):
                err("binding.copySecret.from must be a Secret name")
            if "${app}" not in str(copy["name"]) and "${name}" not in str(copy["name"]):
                err("binding.copySecret.name must contain ${app} or ${name} (app namespaces are shared)")
            if not NAME.match(placeholders(copy["name"], "copySecret.name")):
                err("binding.copySecret.name must render to a Secret name")
            keys = copy["keys"]
            if not isinstance(keys, dict) or not keys or not all(
                    SECRET_KEY.match(str(k)) and SECRET_KEY.match(str(v)) for k, v in keys.items()):
                err("binding.copySecret.keys must map source keys to target keys")
                copy = None
            elif len(set(keys.values())) != len(keys):
                err("binding.copySecret.keys: two keys copied to the same target key")
    elif scope == "shared":
        err("binding: scope shared needs copySecret")

    names = []
    env = b.get("env") or []
    if not isinstance(env, list):
        err("binding.env must be a list")
        env = []
    for v in env:
        if not isinstance(v, dict):
            err(f"binding.env: {v!r} must be a mapping")
            continue
        n = str(v.get("name", ""))
        if not ENV_NAME.match(n):
            err(f"binding.env: invalid name {n!r}")
        names.append(n)
        has_value, has_secret = "value" in v, "secret" in v or "key" in v
        if has_value == has_secret or set(v) - {"name", "value", "secret", "key"} \
                or (has_secret and not (v.get("secret") and v.get("key"))):
            err(f"binding.env.{n}: needs either value, or secret and key")
            continue
        if has_value:
            if not isinstance(v["value"], str):
                err(f"binding.env.{n}: value must be a string (quote it)")
            placeholders(v["value"], f"env.{n}")
        else:
            if "${app}" not in str(v["secret"]) and "${name}" not in str(v["secret"]):
                err(f"binding.env.{n}: secret must contain ${{app}} or ${{name}} (app namespaces are shared)")
            if not NAME.match(placeholders(v["secret"], f"env.{n}")):
                err(f"binding.env.{n}: secret must render to a Secret name")
            if not SECRET_KEY.match(str(v["key"])):
                err(f"binding.env.{n}: invalid key")
            if copy and v["secret"] == copy["name"] and v["key"] not in copy["keys"].values():
                err(f"binding.env.{n}: key {v['key']} is not copied by copySecret")
    if len(set(names)) != len(names):
        err("binding.env: duplicate names")

    ann = b.get("podAnnotations") or {}
    if not isinstance(ann, dict):
        err("binding.podAnnotations must be a mapping")
        ann = {}
    for k, v in ann.items():
        if not ANNOTATION.match(str(k)):
            err(f"binding.podAnnotations: invalid key {k}")
        if not isinstance(v, str):
            err(f"binding.podAnnotations.{k}: value must be a string (quote it)")
        placeholders(v, f"podAnnotations.{k}")

    m = b.get("manifests")
    if scope == "instance" and not m:
        err("binding: scope instance needs manifests")
    if scope == "config" and (m or b.get("copySecret") is not None):
        err("binding: scope config takes only env and podAnnotations")
    if scope == "config" and not env and not ann:
        err("binding: scope config needs env or podAnnotations")
    if m:
        if not REL_YAML.match(str(m)) or ".." in str(m) or not str(m).startswith("bindings/"):
            return err(f"binding.manifests {m}: must be a relative .yaml path under bindings/")
        full = os.path.join(ROOT, m)
        if not os.path.isfile(full):
            return err(f"binding.manifests {m}: file missing")
        rendered = placeholders(open(full, encoding="utf-8").read(), "manifests")
        try:
            docs = [d for d in yaml.safe_load_all(rendered) if d is not None]
        except yaml.YAMLError as x:
            return err(f"binding.manifests {m}: not valid YAML after substitution: {x}")
        if not docs:
            err(f"binding.manifests {m}: no documents")
        for d in docs:
            meta = d.get("metadata") if isinstance(d, dict) else None
            if not isinstance(meta, dict) or not d.get("apiVersion") or not d.get("kind") or not meta.get("name"):
                err(f"binding.manifests {m}: every document needs apiVersion, kind and metadata.name")
                continue
            what = f"binding.manifests {m}: {d['kind']} {meta['name']}"
            if SAMPLE_APP not in str(meta["name"]) or not NAME.match(str(meta["name"])):
                err(f"{what}: metadata.name must contain ${{name}} or ${{app}} and be a valid name")
            if meta.get("namespace") not in (None, values["namespace"]):
                err(f"{what}: metadata.namespace must be ${{namespace}} or left out")


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
