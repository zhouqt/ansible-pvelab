#!/usr/bin/env python3

import sys

CAP_DROP_LINES = (
    "lxc.cap.drop:",
    "lxc.cap.drop: mac_override sys_time sys_module sys_rawio",
)

def main() -> int:
    if len(sys.argv) < 2:
        print("usage: ussuri-set-capdrop.py <vmid> [marker-suffix]", file=sys.stderr)
        return 2
    vmid = sys.argv[1]
    suffix = sys.argv[2] if len(sys.argv) > 2 else "USSURI WORKLOAD SETTINGS"
    conf = f"/etc/pve/lxc/{vmid}.conf"

    begin = f"# BEGIN ANSIBLE {suffix}"
    end = f"# END ANSIBLE {suffix}"
    owned = {begin, end, *CAP_DROP_LINES}
    block = [begin, *CAP_DROP_LINES, end]

    with open(conf) as fh:
        old = fh.read()

    lines = [l for l in old.splitlines() if l.strip() not in owned]

    out, inserted = [], False
    for line in lines:
        if not inserted and line.strip().startswith("["):
            out.extend(block)
            inserted = True
        out.append(line)
    if not inserted:
        out.extend(block)

    new = "\n".join(out) + "\n"
    if new != old:
        with open(conf, "w") as fh:
            fh.write(new)
        print("CHANGED")
    else:
        print("OK")
    return 0

if __name__ == "__main__":
    sys.exit(main())