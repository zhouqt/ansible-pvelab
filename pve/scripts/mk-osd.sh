#!/bin/bash
set -e
DEV=/dev/osd-block

own_vg() { pvs --noheadings -o vg_name "$DEV" 2>/dev/null | tr -d ' '; }

VG_NOW="$(own_vg)"
if [ -n "$VG_NOW" ] && lvs --noheadings -o lv_tags "$VG_NOW" 2>/dev/null | grep -q 'ceph\.osd_id'; then
  echo "MKOSD-SKIP-EXISTS: lvm tag ceph.osd_id present on $DEV; refusing to wipe"
  exit 0
fi

FSID=$(python3 -c 'import uuid; print(uuid.uuid4())')
echo "new-osd-fsid=$FSID"

if [ ! -f /var/lib/ceph/bootstrap-osd/ceph.keyring ]; then
  echo "MKOSD-FAILED: /var/lib/ceph/bootstrap-osd/ceph.keyring is missing (the ceph-osd charm has not run mon-relation-changed yet); refusing to create disks without the bootstrap keyring" >&2
  exit 1
fi

echo "--- wipe broken LVs ---"
if [ -n "$VG_NOW" ]; then
  vgchange -an "$VG_NOW" 2>/dev/null || true
  vgremove -f "$VG_NOW" 2>/dev/null || true
  echo "removed vg $VG_NOW"
fi
pvremove -f "$DEV" 2>/dev/null || true
dd if=/dev/zero of="$DEV" bs=1M count=10 status=none

echo "--- fresh pv/vg/lv (charm-equivalent) ---"
pvcreate "$DEV"
vgcreate "ceph-$FSID" "$DEV"
lvcreate -l 100%FREE -n "osd-block-$FSID" "ceph-$FSID"

echo "--- node fixup (no udev) ---"
mkdir -p /dev/mapper /dev/"ceph-$FSID"
DM=$(lvs --noheadings --separator '|' -o lv_name,lv_dm_path "ceph-$FSID" 2>/dev/null \
       | grep "osd-block-$FSID" | cut -d'|' -f2 | tr -d ' ')
echo "dm-path=$DM"
[ -n "$DM" ] && /sbin/dmsetup mknodes "$(basename "$DM")" 2>/dev/null || true
ln -snf "$DM" "/dev/ceph-$FSID/osd-block-$FSID"
chown ceph:ceph "$DM" "/dev/ceph-$FSID/osd-block-$FSID"

echo "--- ceph-volume lvm create (timeout: final systemd spawn may hang in CT) ---"
timeout 120 ceph-volume lvm create --osd-fsid "$FSID" --bluestore --data "ceph-$FSID/osd-block-$FSID" 2>&1 | tail -15
RC=${PIPESTATUS[0]}
echo "create-rc=$RC"
if [ "$RC" -ne 0 ]; then
  echo "MKOSD-FAILED: ceph-volume lvm create rc=$RC (see the ceph-volume output above)" >&2
  exit 1
fi
systemctl disable ceph-volume@lvm-*.service 2>/dev/null || true
systemctl reset-failed 'ceph-volume@*' 2>/dev/null || true
systemctl stop 'ceph-volume@*' 2>/dev/null || true
echo MKOSD-DONE
