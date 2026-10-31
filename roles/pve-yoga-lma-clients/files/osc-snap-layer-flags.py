#!/usr/bin/env python3

import os
import subprocess
import sys

charm_dir = os.environ.get("JUJU_CHARM_DIR") or os.getcwd()
sys.path.insert(0, charm_dir)

from charmhelpers.core import unitdata
from charms import reactive

WANTED = ("core18", "snapd")

def snap_line(name):

    try:
        out = subprocess.run(
            ["snap", "list", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return None
    if out.returncode != 0:
        return None
    lines = out.stdout.decode("utf-8", "replace").strip().splitlines()
    return lines[1].strip() if len(lines) > 1 else None

snapd = snap_line("snapd")
if snapd:
    cols = snapd.split()
    print("SNAPD %s rev %s" % (cols[1], cols[2]))

applied, skipped = [], []
for name in WANTED:
    flag = "snap.installed.%s" % name
    if not snap_line(name):
        skipped.append(name)
        continue
    if reactive.is_flag_set(flag):
        continue
    reactive.set_flag(flag)
    applied.append(flag)

if applied:

    unitdata.kv().flush()

for name in skipped:
    print("SKIP-NOT-INSTALLED %s" % name)
if applied:
    print("FLAG-APPLIED %s" % ",".join(applied))
else:
    print("FLAG-ALREADY-SET")
