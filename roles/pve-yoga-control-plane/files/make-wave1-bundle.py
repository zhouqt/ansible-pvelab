#!/usr/bin/env python3

import argparse
import sys

import yaml

def deep_merge(base, over):

    out = dict(base)
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out

def main():
    ap = argparse.ArgumentParser(description="derive the wave-1 bundle (P0-5)")
    ap.add_argument("--base", required=True, help="rendered base bundle (openstack-pve-bundle.yaml)")
    ap.add_argument("--overlay", required=True, help="full overlay (openstack-pve-overlay.yaml)")
    ap.add_argument("--out", required=True, help="output path of the wave-1 bundle")
    ap.add_argument("--apps", required=True, help="comma separated critical-path application names")
    args = ap.parse_args()

    with open(args.base, encoding="utf-8") as fh:
        base = yaml.safe_load(fh)
    with open(args.overlay, encoding="utf-8") as fh:
        overlay = yaml.safe_load(fh)

    want = [a.strip() for a in args.apps.split(",") if a.strip()]
    if not want:
        sys.exit("WAVE1-FAIL: --apps is empty")
    if len(set(want)) != len(want):
        sys.exit(f"WAVE1-FAIL: --apps contains duplicates: {args.apps}")

    base_apps = base.get("applications") or {}
    ovl_apps = overlay.get("applications") or {}
    ovl_machines = overlay.get("machines") or {}

    missing = [a for a in want if a not in base_apps]
    if missing:
        sys.exit(f"WAVE1-FAIL: the base bundle has no such applications: {', '.join(missing)}")
    keep = set(want)

    kept_relations, deferred_relations = [], 0
    for rel in base.get("relations") or []:
        endpoints = {e.split(":", 1)[0] for e in rel}
        if endpoints <= keep:
            kept_relations.append(rel)
        else:
            deferred_relations += 1
    if not kept_relations:
        sys.exit("WAVE1-FAIL: no relation was kept, wave-1 can never converge")

    related = {e.split(":", 1)[0] for rel in kept_relations for e in rel}

    apps = {name: deep_merge(base_apps[name], ovl_apps.get(name)) for name in want}

    for name in want:
        if not apps[name].get("num_units") and name not in related:
            sys.exit(
                f"WAVE1-FAIL: application {name} has no num_units (it is not a principal) and appears in no"
                f"retained relation -- such a subordinate cannot be deployed on its own, juju refuses it outright."
                f"Move it out of wave-1 and leave it for wave two, where it lands with its principal."
            )

    used = {str(t) for app in apps.values() for t in (app.get("to") or [])}
    undeclared = sorted(m for m in used if m not in ovl_machines)
    if undeclared:
        sys.exit(f"WAVE1-FAIL: a placement references machines the overlay does not declare: {', '.join(undeclared)}")

    wave1 = {
        "name": base["name"],
        "series": base["series"],
        "machines": {m: ovl_machines[m] for m in sorted(used, key=int)},
        "relations": kept_relations,
        "applications": {name: apps[name] for name in want},
    }
    text = yaml.safe_dump(wave1, sort_keys=False, default_flow_style=False, width=200)

    try:
        with open(args.out, encoding="utf-8") as fh:
            changed = fh.read() != text
    except FileNotFoundError:
        changed = True
    if changed:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)

    machines = sorted(used, key=int)
    deferred = [a for a in base_apps if a not in keep]
    print(f"WAVE1-{'OK' if changed else 'UNCHANGED'}")
    print(f"WAVE1-APPS {','.join(want)}")
    print(f"WAVE1-RELATIONS {len(kept_relations)} (the base leaves {deferred_relations} more cross-wave relations for wave two)")
    print(f"WAVE1-MACHINES {' '.join(machines)}")
    print(f"WAVE1-MAP-MACHINES existing,{','.join(f'{m}={m}' for m in machines)}")
    print(f"WAVE1-DEFERRED {','.join(deferred)}")

if __name__ == "__main__":
    main()
