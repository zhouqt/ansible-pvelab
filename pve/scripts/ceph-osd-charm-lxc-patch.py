#!/usr/bin/env python3

import re
import sys

MARK = "PVE-LXC-PASSTHROUGH-PATCH"
FUNC = "def is_mapped_luks_device(dev):"
STMT = "_, dirs, _ = next(os.walk("

def patch(path):
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()

    if MARK in src:
        return "PATCHED-ALREADY", None

    if FUNC not in src:
        return None, "no {} in {}".format(FUNC, path)

    body_at = src.index(FUNC)
    head, body = src[:body_at], src[body_at:]

    nxt = re.search(r"\ndef \w", body[1:])
    body, tail = (body[: nxt.start() + 1], body[nxt.start() + 1 :]) if nxt else (body, "")

    lines = body.split("\n")
    try:
        i = next(k for k, l in enumerate(lines) if l.strip().startswith(STMT))
    except StopIteration:
        return None, "no {!r} statement inside {}".format(STMT, FUNC)

    try:
        j = next(k for k in range(i + 1, len(lines)) if lines[k].strip() == ")")
    except StopIteration:
        return None, "unterminated os.walk( call inside {}".format(FUNC)

    indent = "    "
    stmt = lines[i : j + 1]
    if not all(l.startswith(indent) for l in stmt):
        return None, "unexpected indentation of the os.walk( statement"

    replacement = (
        [indent + "try:"]
        + [indent + l for l in stmt]
        + [
            indent + "except StopIteration:",
            indent * 2 + "# {}: PVE LXC passthrough device nodes have no".format(MARK),
            indent * 2 + "# sysfs entry; treat as unheld instead of crashing the hook.",
            indent * 2 + "return False",
        ]
    )
    out = head + "\n".join(lines[:i] + replacement + lines[j + 1 :]) + tail

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(out)
    return "PATCHED", None

def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: {} <utils.py path>\n".format(sys.argv[0]))
        return 2
    status, err = patch(sys.argv[1])
    if status is None:
        print("UNPATCHED:{}".format(err))
        return 1
    print(status)
    return 0

if __name__ == "__main__":
    sys.exit(main())
