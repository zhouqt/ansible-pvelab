#!/usr/bin/env python3

import argparse
import json
import sys

def machine_id_for(status, ip):
    matches = []
    for mid, machine in (status.get("machines") or {}).items():
        if not isinstance(machine, dict):
            continue
        if machine.get("dns-name") == ip or ip in (machine.get("ip-addresses") or []):
            matches.append(mid)
    if not matches:
        return None
    return sorted(matches, key=lambda m: (not m.isdigit(), int(m) if m.isdigit() else 0, m))[0]

def units_on(status, app, machine):
    app_doc = (status.get("applications") or {}).get(app) or {}
    found = []
    for name, unit in (app_doc.get("units") or {}).items():
        if not isinstance(unit, dict) or str(unit.get("machine")) != str(machine):
            continue
        found.append(name)
    return found

def unit_state(status, unit_name):
    for app in (status.get("applications") or {}).values():
        unit = (app.get("units") or {}).get(unit_name)
        if isinstance(unit, dict):
            agent = (unit.get("agent-status") or {}).get("current", "unknown")
            workload = (unit.get("workload-status") or {}).get("current", "unknown")
            return agent, workload
    return "unknown", "unknown"

def main(argv=None):
    parser = argparse.ArgumentParser(description="Small queries against a `juju status --format json` snapshot (Juju 2.9/3.x).")
    parser.add_argument("query", choices=["machine-ip", "unit-on"])
    parser.add_argument("--ip")
    parser.add_argument("--app")
    parser.add_argument("--machine")
    args = parser.parse_args(argv)

    try:
        status = json.load(sys.stdin)
    except ValueError as exc:
        print("INVALID-JSON %s" % exc)
        return 2
    if not isinstance(status, dict):
        print("INVALID-JSON not an object")
        return 2

    if args.query == "machine-ip":
        if not args.ip:
            parser.error("machine-ip needs --ip")
        machine = machine_id_for(status, args.ip)
        print("MACHINE %s" % (machine if machine is not None else "NONE"))
        return 0

    if not args.app or args.machine is None:
        parser.error("unit-on needs --app and --machine")
    units = units_on(status, args.app, args.machine)
    if not units:
        print("NOUNIT")
        return 0
    problems = []
    for name in units:
        agent, workload = unit_state(status, name)
        if agent == "idle" and workload == "active":
            print("ACTIVE %s" % name)
            return 0
        problems.append("%s=%s/%s" % (name, agent, workload))
    print("WAIT %s" % ",".join(problems))
    return 0

if __name__ == "__main__":
    sys.exit(main())
