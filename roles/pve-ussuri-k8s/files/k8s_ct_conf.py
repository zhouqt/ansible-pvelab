#!/usr/bin/env python3

import argparse
import os
import re
import sys

CAP_DROP_LINES = (
    "lxc.cap.drop:",
    "lxc.cap.drop: mac_override sys_time sys_module sys_rawio",
)
CAP_DROP_RE = re.compile(r"^lxc\.cap\.drop\s*:")
DEV_RE = re.compile(r"^dev(\d+)\s*:\s*path=(\S+)\s*$")

LEGACY_ALLOW_RE = re.compile(r"^lxc\.cgroup2\.devices\.allow\s*:")
LEGACY_TUN_MOUNT_RE = re.compile(r"^lxc\.mount\.entry\s*:\s*/dev/net/tun\s")

class ConfError(Exception):
    pass

def split_active(lines):

    for index, line in enumerate(lines):
        if line.startswith("["):
            return lines[:index], lines[index:]
    return list(lines), []

def render(original_lines, devices):

    active, sections = split_active(original_lines)

    for line in active:
        stripped = line.strip()
        if LEGACY_ALLOW_RE.match(stripped) or LEGACY_TUN_MOUNT_RE.match(stripped):
            raise ConfError(
                "%r is the legacy device form; remove it before adding devN: "
                "(on PVE 9.2 both together fail the start with EEXIST)" % stripped
            )

    dev_lines = {}
    kept = []
    for line in active:
        stripped = line.strip()
        if CAP_DROP_RE.match(stripped):
            continue
        match = DEV_RE.match(stripped)
        if match:
            index, path = int(match.group(1)), match.group(2)
            if path not in devices:

                if path not in dev_lines:
                    kept.append(line.rstrip("\r"))
                    dev_lines[path] = (index, None)
                continue
            if path not in dev_lines or index < dev_lines[path][0]:
                dev_lines[path] = (index, "dev%d: path=%s" % (index, path))

            continue
        kept.append(line.rstrip("\r"))

    while kept and kept[-1].strip() == "":
        kept.pop()

    kept.extend(CAP_DROP_LINES)

    used = {index for index, _ in dev_lines.values()}
    next_free = 0
    for path in devices:
        if path in dev_lines:
            kept.append(dev_lines[path][1])
            continue
        while next_free in used:
            next_free += 1
        used.add(next_free)
        kept.append("dev%d: path=%s" % (next_free, path))

    output = list(kept)
    if sections:
        if output:
            output.append("")
        output.extend(section.rstrip("\r") for section in sections)
    return output

def main(argv=None):
    parser = argparse.ArgumentParser(description="Maintain the LXC keys of the dedicated k8s compute container (PVE 9.2).")
    parser.add_argument("conf", help="container config to edit")
    parser.add_argument("--dev", action="append", default=[],
                        dest="devices", help="character device to pass through")
    args = parser.parse_args(argv)

    devices = args.devices or ["/dev/net/tun", "/dev/kvm"]
    if len(set(devices)) != len(devices):
        print("k8s_ct_conf: duplicate --dev", file=sys.stderr)
        return 1
    try:
        with open(args.conf, "r", encoding="utf-8") as handle:
            original = handle.read()
        if not original.strip():
            raise ConfError("%s is empty" % args.conf)
        had_trailing_newline = original.endswith("\n")
        rendered = render(original.splitlines(), devices)
        updated = "\n".join(rendered) + ("\n" if had_trailing_newline else "")
        if updated == original:
            print("unchanged")
            return 0
        directory = os.path.dirname(os.path.abspath(args.conf))
        tmp = os.path.join(directory,
                           ".%s.ansible-pve.tmp" % os.path.basename(args.conf))
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, args.conf)
    except ConfError as exc:
        print("k8s_ct_conf: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("k8s_ct_conf: %s" % exc, file=sys.stderr)
        return 1
    print("changed")
    return 0

if __name__ == "__main__":
    sys.exit(main())
