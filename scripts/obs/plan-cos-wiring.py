#!/usr/bin/env python3

import argparse
import json
import sys

def main():
    parser = argparse.ArgumentParser(description="Build the COS wiring plan for one OpenStack environment from its Juju status.")
    parser.add_argument(
        "--status-json",
        required=True,
        help="path to a `juju status --format json` document, or - for stdin",
    )
    parser.add_argument(
        "--targets",
        default="",
        help="comma-separated application names to look for (lma_nrpe_targets)",
    )
    parser.add_argument(
        "--place-on",
        required=True,
        help="application whose machine should host cos-proxy/openstack-exporter",
    )
    args = parser.parse_args()

    try:
        raw = sys.stdin.read() if args.status_json == "-" else open(
            args.status_json, encoding="utf-8"
        ).read()
        doc = json.loads(raw)
    except (OSError, ValueError) as exc:
        print(f"cannot read status JSON: {exc}", file=sys.stderr)
        return 2

    targets = [t for t in args.targets.split(",") if t]
    place_on = args.place_on
    apps = doc.get("applications") or {}
    saas = doc.get("application-endpoints") or {}

    def is_principal(name):

        return "subordinate-to" not in apps[name]

    def endpoints(name):
        return set((apps.get(name) or {}).get("endpoint-bindings") or {})

    present = sorted(a for a in targets if a in apps)
    principals = [a for a in present if is_principal(a)]

    machine_of = {}
    for name in principals:
        for unit in ((apps.get(name) or {}).get("units") or {}).values():
            if unit.get("machine") is not None:
                machine_of[name] = unit.get("machine")
                break

    place_machine = machine_of.get(place_on)
    if place_machine is None and machine_of:

        place_on = sorted(machine_of)[0]
        place_machine = machine_of[place_on]

    print(
        json.dumps(
            {
                "app_count": len(apps),
                "present_targets": present,
                "general_info": principals,
                "missing_targets": sorted(a for a in targets if a not in apps),
                "keystone_machine": machine_of.get("keystone"),
                "keystone_identity_admin": "identity-admin" in endpoints("keystone"),
                "place_on": place_on,
                "place_machine": place_machine,
                "has_nrpe": "nrpe" in apps,
                "has_cos_proxy": "cos-proxy" in apps,
                "has_grafana_agent": "grafana-agent" in apps,
                "has_openstack_exporter": "openstack-exporter" in apps,
                "consumed": sorted(saas),
            }
        )
    )
    return 0

if __name__ == "__main__":
    sys.exit(main())