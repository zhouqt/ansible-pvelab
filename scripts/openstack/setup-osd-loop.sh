#!/bin/bash
echo "REFUSED: setup-osd-loop.sh is deprecated (the loop approach caused the OSD data-loss incident on 2026-10-15)." >&2
echo "  replacement: scripts/env1/setup-osd-lv.sh, called automatically by playbooks/env1/stages/04-machines.yml." >&2
exit 1

set -e
pct set 1101 --delete dev0
pct set 1102 --delete dev0
for spec in "1101 0" "1102 1"; do
  set -- $spec
  conf=/etc/pve/lxc/$1.conf
  grep -q "mount.entry" $conf || cat >> $conf <<EOF
lxc.mount.entry: /dev/loop$2 dev/osd-block none bind,optional,create=file
lxc.cgroup2.devices.allow: b 7:0 rwm
lxc.cgroup2.devices.allow: b 7:1 rwm
EOF
done
pct exec 1101 -- bash -c "vgremove -f ceph-e439f0d8-4afe-4064-9c96-9f075728425c 2>/dev/null; pvremove -f /dev/pve/ceph-osd-1101 2>/dev/null; rm -rf /var/lib/ceph/osd/ceph-0; true"
pct exec 1102 -- bash -c "vgremove -f ceph-56275833-f112-46e8-b6ae-16710491f1fa 2>/dev/null; pvremove -f /dev/pve/ceph-osd-1102 2>/dev/null; rm -rf /var/lib/ceph/osd/ceph-1; true"
lvremove -f pve/ceph-osd-1101 pve/ceph-osd-1102
for N in 0 1; do
cat > /etc/systemd/system/ceph-osd-loopback-$N.service <<EOF
[Unit]
Description=Setup loopback device for Ceph OSD $N
DefaultDependencies=no
After=local-fs.target
Before=lvm2-activation.service pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'losetup -j /var/lib/ceph-osd-files/ceph-osd-compute-$N.img --noheadings | grep -q . || losetup /dev/loop$N /var/lib/ceph-osd-files/ceph-osd-compute-$N.img'
ExecStop=/bin/bash -c 'losetup -d $(losetup -j /var/lib/ceph-osd-files/ceph-osd-compute-$N.img -O NAME --noheadings) 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
systemctl enable --now ceph-osd-loopback-0.service ceph-osd-loopback-1.service
losetup -l
echo SETUP-DONE
