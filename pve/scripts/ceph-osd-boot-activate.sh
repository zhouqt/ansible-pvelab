#!/bin/bash
set -u
DEV=/dev/osd-block

vg=$(pvs --noheadings -o vg_name "$DEV" 2>/dev/null | tr -d ' ')
if [ -z "$vg" ]; then
  echo "no LVM VG on $DEV; nothing to activate"
  exit 0
fi

/sbin/vgchange -ay "$vg"
mkdir -p /dev/mapper "/dev/$vg"
/sbin/lvs --noheadings --separator '|' -o lv_name,lv_dm_path "$vg" 2>/dev/null | \
while IFS='|' read -r lv dmpath; do
  lv=${lv// /}
  dmpath=${dmpath// /}
  [ -n "$lv" ] || continue
  [ -n "$dmpath" ] && /sbin/dmsetup mknodes "$(basename "$dmpath")" 2>/dev/null
  ln -snf "$dmpath" "/dev/$vg/$lv"
done

tags="$(/sbin/lvs --noheadings -o lv_tags "$vg" 2>/dev/null | tr ',' '\n')"
osd_id="$(printf '%s\n' "$tags" | sed -n 's/^ *ceph\.osd_id=//p' | head -1)"
osd_fsid="$(printf '%s\n' "$tags" | sed -n 's/^ *ceph\.osd_fsid=//p' | head -1)"
if [ -n "$osd_id" ] && [ -n "$osd_fsid" ]; then
  /usr/sbin/ceph-volume lvm activate "$osd_id" "$osd_fsid"
else
  echo "no ceph.osd_id / ceph.osd_fsid tag on $vg; nothing to activate"
fi

systemctl disable ceph-volume@lvm-*.service 2>/dev/null || true
