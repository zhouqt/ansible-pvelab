#!/bin/bash
set -e
FSID=$(python3 -c 'import uuid; print(uuid.uuid4())')
echo "new-osd-fsid=$FSID"

echo "--- wipe broken LVs ---"
for VG in $(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | grep '^ceph-'); do
  vgchange -an "$VG" 2>/dev/null || true
  vgremove -f "$VG" 2>/dev/null || true
  echo "removed vg $VG"
done
pvremove -f /dev/osd-block 2>/dev/null || true
dd if=/dev/zero of=/dev/osd-block bs=1M count=10 status=none

echo "--- fresh pv/vg/lv (charm-equivalent) ---"
/sbin/vgchange -ay 2>/dev/null || true
pvcreate /dev/osd-block
vgcreate "ceph-$FSID" /dev/osd-block
lvcreate -l 100%FREE -n "osd-block-$FSID" "ceph-$FSID"

echo "--- node fixup (no udev) ---"
mkdir -p /dev/mapper /dev/"ceph-$FSID"
/sbin/dmsetup mknods 2>/dev/null || true
DM=$(lvs --noheadings --separator '|' -o vg_name,lv_name,lv_dm_path 2>/dev/null | grep "osd-block-$FSID" | cut -d'|' -f3 | tr -d ' ')
echo "dm-node=$DM"
ln -snf "$DM" "/dev/ceph-$FSID/osd-block-$FSID"
chown ceph:ceph "$DM" "/dev/ceph-$FSID/osd-block-$FSID"

echo "--- ceph-volume lvm create (timeout: final systemd spawn may hang in CT) ---"
timeout 120 ceph-volume lvm create --osd-fsid "$FSID" --bluestore --data "ceph-$FSID/osd-block-$FSID" 2>&1 | tail -15
RC=${PIPESTATUS[0]}
echo "create-rc=$RC"
systemctl disable ceph-volume@lvm-*.service 2>/dev/null || true
systemctl reset-failed 'ceph-volume@*' 2>/dev/null || true
systemctl stop 'ceph-volume@*' 2>/dev/null || true
echo MKOSD-DONE
