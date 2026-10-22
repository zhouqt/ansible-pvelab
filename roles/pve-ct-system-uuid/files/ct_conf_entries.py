#!/usr/bin/env python3

import argparse
import os
import re
import sys

MOUNT_KEY_RE = re.compile(r"^lxc\.mount\.entry\s*[:=]\s*(.*)$")

UUID_RECORD_PREFIX = "# ansible-pve system_uuid="

class ConfError(Exception):
    pass

def parse_entry(entry):

    fields = entry.split()
    if not 4 <= len(fields) <= 6:
        raise ConfError(
            "--entry %r must have 4-6 fields (source target type options [0 0])" % entry
        )
    target = fields[1]
    if target.startswith("/"):
        raise ConfError(
            "--entry %r targets an absolute path; use the container-relative form "
            "such as sys/firmware/dmi/tables/DMI" % entry
        )
    if target in (".", ".."):
        raise ConfError("--entry %r has no usable destination" % entry)
    return " ".join(fields), target

def mount_destination(line):

    match = MOUNT_KEY_RE.match(line.strip())
    if not match:
        return None
    fields = match.group(1).split()
    return fields[1] if len(fields) >= 2 else None

def mount_source(line):

    match = MOUNT_KEY_RE.match(line.strip())
    if not match:
        return None
    fields = match.group(1).split()
    return fields[0] if fields else None

def split_active(lines):

    for index, line in enumerate(lines):
        if line.startswith("["):
            return lines[:index], lines[index:]
    return list(lines), []

def render(original_lines, entries, remove, prune_sources=()):

    active, sections = split_active(original_lines)
    destinations = {target for _, target in entries}

    kept = []
    for line in active:
        if mount_destination(line) in destinations:
            continue
        if line.startswith(UUID_RECORD_PREFIX):
            continue
        source = mount_source(line)
        if source is not None and any(
                source == prefix or source.startswith(prefix.rstrip("/") + "/")
                for prefix in prune_sources):
            continue
        kept.append(line.rstrip("\r"))

    while kept and kept[-1].strip() == "":
        kept.pop()

    if not remove:
        for value, _ in entries:
            kept.append("lxc.mount.entry: " + value)

    output = list(kept)
    if sections:
        if output:
            output.append("")
        output.extend(section.rstrip("\r") for section in sections)
    return output

def main(argv=None):
    parser = argparse.ArgumentParser(description="Maintain ``lxc.mount.entry`` lines in a PVE container config, safely.")
    parser.add_argument("--conf", required=True, help="container config to edit")
    parser.add_argument("--entry", action="append", default=[],
                        help="lxc.mount.entry value 'source target type options 0 0'")
    parser.add_argument("--remove", action="store_true",
                        help="drop the given destinations (and any legacy identity line)")
    parser.add_argument("--prune-source", action="append", default=[], metavar="PREFIX",
                        help="also drop managed mounts whose source is under PREFIX "
                             "but whose destination is not requested any more")
    args = parser.parse_args(argv)

    if not args.entry:
        parser.error("at least one --entry is required")
    try:
        entries = [parse_entry(entry) for entry in args.entry]
        destinations = [target for _, target in entries]
        if len(set(destinations)) != len(destinations):
            raise ConfError("duplicate destinations in --entry: %s" % destinations)

        try:
            with open(args.conf, "r", encoding="utf-8") as handle:
                original = handle.read()
        except OSError as exc:
            raise ConfError("cannot read %s: %s" % (args.conf, exc))
        if not original.strip():
            raise ConfError("%s is empty" % args.conf)

        had_trailing_newline = original.endswith("\n")
        rendered = render(original.splitlines(), entries, args.remove,
                          args.prune_source)
        updated = "\n".join(rendered) + ("\n" if had_trailing_newline else "")
        if updated == original:
            print("unchanged")
            return 0

        directory = os.path.dirname(os.path.abspath(args.conf))
        tmp = os.path.join(directory, ".%s.ansible-pve.tmp" % os.path.basename(args.conf))
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, args.conf)
    except ConfError as exc:
        print("ct_conf_entries: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("ct_conf_entries: %s" % exc, file=sys.stderr)
        return 1

    print("changed")
    return 0

if __name__ == "__main__":
    sys.exit(main())
