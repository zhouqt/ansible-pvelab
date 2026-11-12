#!/bin/bash
/sbin/vgchange -ay
mkdir -p /dev/mapper
/sbin/dmsetup mknodes 2>/dev/null
/sbin/lvs --noheadings --separator '|' -o vg_name,lv_name,lv_dm_path 2>/dev/null | \
while IFS='|' read -r vg lv dmpath; do
  vg=${vg// /}
  lv=${lv// /}
  [ -n "$vg" ] || continue
  mkdir -p "/dev/$vg"
  ln -snf "$dmpath" "/dev/$vg/$lv"
done
/usr/sbin/ceph-volume lvm activate --all
systemctl disable ceph-volume@lvm-*.service 2>/dev/null || true
