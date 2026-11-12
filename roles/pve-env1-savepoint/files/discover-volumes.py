#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys

DISK_RE = re.compile(r"^(rootfs|mp\d+|scsi\d+|virtio\d+|sata\d+|ide\d+):\s*([^,\s]+)")

def die(msg):
    sys.stderr.write(msg + "\n")
    raise SystemExit(1)

def read_config(vmid, kind):
    cmd = ["qm", "config", str(vmid)] if kind == "kvm" else ["pct", "config", str(vmid)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        die("DISCOVER-FAIL: %s -> %s" % (" ".join(cmd), proc.stderr.strip()))
    return proc.stdout

def pool_lv_names():
    proc = subprocess.run(
        ["lvs", "--noheadings", "-o", "lv_name", "pve-thin-pool"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        die("DISCOVER-FAIL: lvs pve-thin-pool -> %s" % proc.stderr.strip())
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True, help="JSON spec passed by the role")
    spec = json.loads(parser.parse_args().spec)

    kvms = {int(v) for v in spec["kvms"]}
    controller = int(spec["controller_vmid"])
    client = int(spec["client_vmid"])
    excluded = set(spec["exclude_volumes"])

    existing = pool_lv_names()
    volumes, warnings = [], []

    for raw_vmid in list(spec["cts"]) + list(spec["kvms"]):
        vmid = int(raw_vmid)
        kind = "kvm" if vmid in kvms else "ct"
        if vmid == controller:
            role = "ctrl"
        elif vmid == client:
            role = "client"
        elif kind == "kvm":
            role = "kvm"
        else:
            role = "v%d" % vmid

        for line in read_config(vmid, kind).splitlines():
            match = DISK_RE.match(line.strip())
            if not match:
                continue
            key, ref = match.group(1), match.group(2)
            if not ref.startswith("pve-thin-pool:"):
                continue
            origin = ref.split(":", 1)[1]

            skip = None
            if origin in excluded:
                skip = "excluded-by-name"
            elif key == "ide2" and not spec["include_cloudinit"]:
                skip = "cloudinit-disabled"
            elif key == "mp0" and vmid == client and not spec["include_maas_mp"]:
                skip = "maas-mp-disabled"
            elif origin not in existing:

                die("DISCOVER-FAIL: vmid %d references %s, which points at a missing volume %s" % (vmid, key, origin))

            volumes.append({"vmid": vmid, "kind": kind, "role": role, "key": key,
                            "origin": origin, "skip": skip})

    if spec["include_extra_lvs"]:
        for lv_name in spec["extra_lvs"]:
            if lv_name in existing:
                volumes.append({"vmid": 0, "kind": "raw", "role": "osd", "key": lv_name,
                                "origin": lv_name, "skip": None})
            else:
                warnings.append("extra LV %s does not exist, skipped" % lv_name)

    print(json.dumps({"volumes": volumes, "warnings": warnings}, ensure_ascii=False))

if __name__ == "__main__":
    main()