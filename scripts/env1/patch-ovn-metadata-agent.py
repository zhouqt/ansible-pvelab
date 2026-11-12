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
            # PVE patch: pyroute2 0.5.9 tags RTM_DELADDR with NLM_F_CREATE |
            # NLM_F_EXCL, which the PVE 9.x kernel (7.0.2-pve) rejects with
            # EOPNOTSUPP; the exception aborts provision_datapath and the OVN
            # metadata proxy never comes up for VMs on this chassis. Only IPv4
            # is ever meaningful here (metadata is IPv4-only).
            if utils.get_ip_version(ipaddr) == 4:
                ip2.addr.delete(ipaddr)
"""

PATCHED_LEGACY = """\
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
    elif PATCHED_LEGACY in content:

        content = content.replace(PATCHED_LEGACY, PATCHED, 1)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(content)
        print("PATCHED: %s (corrected the comment of the old patch)" % target)
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

        service = "neutron-ovn-metadata-agent.service"
        if subprocess.call(["systemctl", "cat", service],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL) != 0:

            print("RESTART-SKIPPED: %s is not installed" % service)
            return 0
        rc = subprocess.call(["systemctl", "restart", service])
        if rc != 0:
            print("RESTART-FAILED: %s" % service)
            return rc
        print("RESTARTED: %s" % service)

    return 0

if __name__ == "__main__":
    sys.exit(main())
