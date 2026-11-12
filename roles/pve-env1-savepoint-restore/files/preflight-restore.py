#!/usr/bin/env python3

import json
import re
import subprocess
import sys

def emit(payload, rc):
    print(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(rc)

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)

def main():
    args = [a for a in sys.argv[1:] if a != "--ignore-conf-check"]

    ignore_conf = "--ignore-conf-check" in sys.argv[1:]
    if len(args) != 1:
        emit({"ok": False, "errors": ["usage: preflight-restore.py [--ignore-conf-check] <metadata>"]}, 2)
    path = args[0]

    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        emit({"ok": False, "errors": ["cannot read metadata file %s: %s" % (path, exc)]}, 1)

    volumes = []
    for line in lines:
        line = line.strip()
        if not line.startswith("vol "):
            continue
        try:
            row = dict(kv.split("=", 1) for kv in line[4:].split())
            row["vmid"] = int(row["vmid"])
        except (ValueError, KeyError):
            emit({"ok": False, "errors": ["cannot parse metadata line: %s" % line]}, 1)
        volumes.append(row)

    if not volumes:
        emit({"ok": False, "errors": ["the metadata has no vol line at all: %s" % path]}, 1)

    lvs = run(["lvs", "--noheadings", "-o", "lv_name", "pve-thin-pool"])
    if lvs.returncode != 0:
        emit({"ok": False, "errors": ["lvs pve-thin-pool failed: %s" % lvs.stderr.strip()]}, 1)
    existing = {name.strip() for name in lvs.stdout.splitlines() if name.strip()}

    errors, warnings = [], []
    conf_cache = {}

    def conf_of(vmid, kind):
        if vmid not in conf_cache:
            cmd = ["qm", "config", str(vmid)] if kind == "kvm" else ["pct", "config", str(vmid)]
            proc = run(cmd)
            conf_cache[vmid] = proc.stdout if proc.returncode == 0 else None
        return conf_cache[vmid]

    for vol in volumes:
        if vol["base"] not in existing:
            errors.append("base volume missing: %s" % vol["base"])
            continue

        if vol["kind"] == "raw":
            if vol["origin"] not in existing:
                errors.append("raw volume %s no longer exists (deleted after the savepoint?)" % vol["origin"])
            continue

        if ignore_conf:
            continue

        conf = conf_of(vol["vmid"], vol["kind"])
        if conf is None:
            errors.append("cannot read the conf of vmid %d" % vol["vmid"])
            continue

        pattern = re.escape("pve-thin-pool:" + vol["origin"]) + r"(,|\s|$)"
        if not re.search(pattern, conf):
            errors.append(
                "the conf of vmid %d no longer references %s (the topology changed after the savepoint;"
                "align it with -e pve_env1_savepoint_restore_conf=true, or handle it by hand)"
                % (vol["vmid"], vol["origin"]))

    emit({"ok": not errors, "volumes": volumes, "errors": errors, "warnings": warnings},
         0 if not errors else 1)

if __name__ == "__main__":
    main()