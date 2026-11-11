#!/usr/bin/env python3

import argparse
import json
import sys

def iter_units(units):

    for name, unit in (units or {}).items():
        if not isinstance(unit, dict):
            continue
        workload = (unit.get("workload-status") or {}).get("current", "unknown")
        agent = (unit.get("agent-status") or {}).get("current", "unknown")
        yield name, workload, agent
        for sub_name, sub in (unit.get("subordinates") or {}).items():
            if not isinstance(sub, dict):
                continue
            sub_workload = (sub.get("workload-status") or {}).get("current", "unknown")
            sub_agent = (sub.get("agent-status") or {}).get("current", "unknown")
            yield sub_name, sub_workload, sub_agent

def main(argv=None):
    parser = argparse.ArgumentParser(description="Decide whether a `juju status --format json` snapshot of the k8s model is settled.")
    parser.add_argument("--expected", default="",
                        help="comma separated application names that must exist and be active")
    args = parser.parse_args(argv)

    try:
        status = json.load(sys.stdin)
    except ValueError as exc:
        print("INVALID-JSON %s" % exc)
        return 2
    if not isinstance(status, dict):
        print("INVALID-JSON not an object")
        return 2

    applications = status.get("applications") or {}
    expected = [name for name in args.expected.split(",") if name]

    bad_apps = []
    for name in expected:
        app = applications.get(name)
        if app is None:
            bad_apps.append("%s=absent" % name)
            continue
        current = (app.get("application-status") or {}).get("current", "unknown")
        if current != "active":
            bad_apps.append("%s=%s" % (name, current))

    bad_units = []
    for name, app in applications.items():
        for unit_name, workload, agent in iter_units(app.get("units")):
            if workload != "active" or agent not in ("idle", "executing"):
                bad_units.append("%s=%s/%s" % (unit_name, agent, workload))

    if bad_apps or bad_units:
        print("WAIT apps %s units %s" % (",".join(bad_apps) or "-", ",".join(bad_units) or "-"))
        return 0
    print("READY")
    return 0

if __name__ == "__main__":
    sys.exit(main())
