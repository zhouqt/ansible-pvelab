#!/usr/bin/env python3

import argparse
import os
import shutil
import sys

DEFAULT_TARGET = "/usr/lib/python3/dist-packages/neutron/agent/ovn/metadata/agent.py"

ORIGINAL = """\
        for ipaddr in current_cidrs - metadata_port.ip_addresses:
            ip2.addr.delete(ipaddr)
"""

PATCHED = """\
        for ipaddr in current_cidrs - metadata_port.ip_addresses:
            # LXC(pve) patch: deleting an IPv6 link-local address inside a
            # container netns returns EOPNOTSUPP ("Operation not supported"),
            # which aborts provision_datapath and leaves the OVN metadata
            # proxy unusable for VMs hosted on this chassis. Only IPv4
            # addresses are ever meaningful here (metadata is IPv4-only).
            if utils.get_ip_version(ipaddr) == 4:
                ip2.addr.delete(ipaddr)
"""

def main() -> int:
    parser = argparse.ArgumentParser(description="Idempotent patch: let the neutron OVN metadata agent build the metadata proxy inside an LXC (PVE) container.")
    parser.add_argument("--file", default=DEFAULT_TARGET, help="path of the agent.py to patch")
    parser.add_argument("--restart", action="store_true", help="restart the metadata agent service after patching")
    args = parser.parse_args()

    target = args.file
    if not os.path.exists(target):
        print("PATTERN-NOT-FOUND: %s does not exist" % target)
        return 1

    with open(target, "r", encoding="utf-8") as fh:
        content = fh.read()

    if PATCHED in content:
        print("ALREADY-PATCHED: %s" % target)
    elif ORIGINAL in content:
        backup = target + ".lxc-patch.bak"
        if not os.path.exists(backup):
            shutil.copy2(target, backup)
        content = content.replace(ORIGINAL, PATCHED, 1)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(content)
        print("PATCHED: %s (backup %s)" % (target, backup))
    else:
        print("PATTERN-NOT-FOUND: %s has neither the original block nor any trace of a patch" % target)
        return 1

    if args.restart:
        import subprocess

        for service in ("neutron-ovn-metadata-agent.service",):
            rc = subprocess.call(["systemctl", "restart", service])
            if rc != 0:
                print("RESTART-FAILED: %s" % service)
                return rc
            print("RESTARTED: %s" % service)

    return 0

if __name__ == "__main__":
    sys.exit(main())
