set -e
grep -q "r|/dev/loop" /etc/lvm/lvm.conf || sed -i 's|^global_filter=.*|global_filter=["r\|/dev/zd.*\|","r\|/dev/rbd.*\|","r\|/dev/loop.*\|"]|' /etc/lvm/lvm.conf
lvmconfig devices/global_filter
for vg in $(vgs --noheadings -o vg_name 2>/dev/null | grep "^ceph-" | tr -d ' '); do
  vgchange -an $vg || true
done
pvs 2>/dev/null | grep ceph- || echo "host: no ceph PVs visible now"
for id in 1101 1102; do
  conf=/etc/pve/lxc/$id.conf
  grep -q "cgroup2.devices.allow: b 252" $conf || echo "lxc.cgroup2.devices.allow: b 252:* rwm" >> $conf
  grep -E "cgroup2.devices.allow|mount.entry" $conf
done
echo FIX-DONE
