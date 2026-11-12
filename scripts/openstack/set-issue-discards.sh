#!/bin/bash

set -euo pipefail

CONF=/etc/lvm/lvm.conf
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

[ -f "$CONF" ] || { echo "ERROR: $CONF does not exist" >&2; echo "ISSUE-DISCARDS value=? changed=0"; exit 1; }

out=$(python3 - "$CONF" "$DRY" <<'PY'
import os, re, shutil, sys, time

path, dry = sys.argv[1], sys.argv[2] == "1"
lines = open(path).read().splitlines(True)

live = re.compile(r'^\s*issue_discards\s*=\s*(\d+)\s*$')
commented = re.compile(r'^\s*#\s*issue_discards\s*=')
devices_open = re.compile(r'^\s*devices\s*\{')

cur = None
live_idx = None
for i, l in enumerate(lines):
    m = live.match(l)
    if m:
        cur, live_idx = m.group(1), i
        break

if cur == "1":
    print("UNCHANGED: a live `issue_discards = 1` line already exists (line %d)" % (live_idx + 1))
    print("RESULT changed=0")
    sys.exit(0)

if live_idx is not None:
    lines[live_idx] = "issue_discards = 1\n"
    where = "changed `issue_discards = %s` on line %d to 1" % (cur, live_idx + 1)
else:
    anchor = None
    for i, l in enumerate(lines):
        if commented.match(l):
            anchor, how = i, "inserted the live line after the commented default on line %d" % (i + 1)
            break
    else:
        for i, l in enumerate(lines):
            if devices_open.match(l):
                anchor, how = i, "inserted at the top of the devices section (line %d)" % (i + 1)
                break
    if anchor is None:
        sys.stderr.write("ERROR: there is neither an issue_discards line nor a devices section, cannot locate an insertion point safely\n")
        print("RESULT changed=error")
        sys.exit(0)
    lines.insert(anchor + 1, "issue_discards = 1\n")
    where = how

if dry:
    print("DRY-RUN: %s" % where)
    print("RESULT changed=1")
    sys.exit(0)

bak = path + ".yoga-bak-" + time.strftime("%Y%m%d%H%M%S")
shutil.copy2(path, bak)
tmp = path + ".yoga-new"
with open(tmp, "w") as f:
    f.write("".join(lines))
shutil.copymode(path, tmp)
os.replace(tmp, path)
print("CHANGED: %s (backup %s)" % (where, bak))
print("RESULT changed=1")
PY
)
printf '%s\n' "$out" | grep -v '^RESULT ' | sed 's/^/  /'

changed=$(printf '%s\n' "$out" | sed -n 's/^RESULT changed=\([01]\)$/\1/p')
case "$changed" in
  0|1) ;;
  *) echo "ERROR: the rewriter produced no usable result (changes dropped, file left as is)" >&2
     echo "ISSUE-DISCARDS value=? changed=0"; exit 1 ;;
esac

if [ "$DRY" = "1" ]; then
    echo "ISSUE-DISCARDS value=1 changed=$changed"
    exit 0
fi

val=$(/sbin/lvmconfig --type current devices/issue_discards 2>/dev/null | sed 's/.*=//' | tr -d " '\"\t") || true
if [ "$val" != "1" ]; then
    echo "ERROR: lvmconfig reads issue_discards='${val:-<empty>}', the rewrite did not take effect" >&2
    echo "ISSUE-DISCARDS value=${val:-?} changed=$changed"
    exit 1
fi

echo "ISSUE-DISCARDS value=1 changed=$changed"
