#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  teardown-osd-lvs.sh --vg <vg> --prefix <lv-prefix> --indices "<0 1 2>"
                      [--remove-lvs] [--no-discard] [--apply]

Dry run by default; --apply is required to disable units or delete volumes.
EOF
}

vg=
prefix=
indices=
remove_lvs=0
discard=1
apply=0

while [ $# -gt 0 ]; do
    case "$1" in
        --vg) vg="${2:?--vg needs a value}"; shift 2 ;;
        --prefix) prefix="${2:?--prefix needs a value}"; shift 2 ;;
        --indices) indices="${2:?--indices needs a value}"; shift 2 ;;
        --remove-lvs) remove_lvs=1; shift ;;
        --no-discard) discard=0; shift ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$vg" ] || { echo "--vg is required" >&2; exit 2; }
[ -n "$prefix" ] || { echo "--prefix is required" >&2; exit 2; }
[ -n "$indices" ] || { echo "--indices is required" >&2; exit 2; }

changed=0
trimmed=0
failed=0

for idx in $indices; do
    lv="$prefix-$idx"

    unit="/etc/systemd/system/ceph-osd-lv-$idx.service"
    if [ -f "$unit" ]; then
        if [ "$apply" -eq 1 ]; then
            systemctl disable --now "ceph-osd-lv-$idx.service" >/dev/null 2>&1 || true
            rm -f "$unit"
            echo "UNIT-REMOVED:ceph-osd-lv-$idx.service"
            changed=1
        else
            echo "WOULD-REMOVE-UNIT:ceph-osd-lv-$idx.service"
        fi
    fi

    if ! lvs "$vg/$lv" >/dev/null 2>&1; then
        echo "ABSENT:$vg/$lv"
        continue
    fi

    if [ "$remove_lvs" -eq 0 ]; then
        echo "KEPT:$vg/$lv"
        continue
    fi
    if [ "$apply" -eq 0 ]; then
        echo "WOULD-REMOVE:$vg/$lv"
        if [ "$discard" -eq 1 ]; then
            echo "WOULD-TRIM:$vg/$lv"
        fi
        continue
    fi

    dmpath=""
    [ -e "/dev/$vg/$lv" ] && dmpath=$(readlink -f "/dev/$vg/$lv" 2>/dev/null || true)
    [ -n "$dmpath" ] || dmpath=$(lvs --noheadings -o lv_dm_path "$vg/$lv" 2>/dev/null | tr -d ' ')
    if [ -n "$dmpath" ] && [ -e "$dmpath" ]; then
        dmb=$(basename "$dmpath")
        for h in $(ls "/sys/block/$dmb/holders" 2>/dev/null || true); do
            for h2 in $(ls "/sys/block/$h/holders" 2>/dev/null || true); do
                n2=$(cat "/sys/block/$h2/dm/name" 2>/dev/null || true)
                if [ -n "$n2" ] && dmsetup remove "$n2" >/dev/null 2>&1; then
                    echo "DM-REMOVED:$n2"
                fi
            done
            dmname=$(cat "/sys/block/$h/dm/name" 2>/dev/null || true)
            if [ -n "$dmname" ] && dmsetup remove "$dmname" >/dev/null 2>&1; then
                echo "DM-REMOVED:$dmname"
            fi
        done
    fi

    if [ "$discard" -eq 1 ]; then
        lvchange -ay "$vg/$lv" >/dev/null 2>&1 || true
        ddev=""
        if [ -b "/dev/$vg/$lv" ]; then
            ddev="/dev/$vg/$lv"
        fi
        if [ -z "$ddev" ]; then
            ddev=$(lvs --noheadings -o lv_dm_path "$vg/$lv" 2>/dev/null | tr -d ' ')
            [ -n "$ddev" ] && [ -b "$ddev" ] || ddev=""
        fi
        if [ -n "$ddev" ] && blkdiscard -f "$ddev" >/dev/null 2>&1; then
            echo "TRIMMED:$vg/$lv"
            trimmed=$((trimmed + 1))
        else
            echo "TRIM-SKIPPED:$vg/$lv"
        fi
    fi

    lvchange -an "$vg/$lv" >/dev/null 2>&1 || true
    if lvremove -f "$vg/$lv" >/dev/null 2>&1; then
        echo "REMOVED:$vg/$lv"
        changed=1
    else
        echo "FAILED:$vg/$lv ($(lvremove -f "$vg/$lv" 2>&1 | tail -1))"
        failed=1
    fi
done

if [ "$apply" -eq 1 ]; then
    systemctl daemon-reload
fi

echo "OSD-TEARDOWN changed=$changed trimmed=$trimmed"
exit "$failed"