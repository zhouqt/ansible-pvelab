#!/bin/bash
set -u
TPL=local:vztmpl/ubuntu-focal-cloudimg-rootfs_20.04-6_amd64.tar.xz
create_one() {
  local vmid=$1 host=$2 ip4=$3 tags=$4
  pct status "$vmid" &>/dev/null && { echo "EXISTS-SKIP $vmid $host"; return; }
  if ! pct create "$vmid" "$TPL" \
    --hostname "$host" --ostype ubuntu --cores 2 --memory 4096 --swap 0 \
    --rootfs pve-thin-pool:16 --unprivileged 0 --features nesting=1,fuse=1 \
    --net0 name=eth0,bridge=pub11,ip=192.168.11.${ip4}/24,gw=192.168.11.1 \
    --nameserver 8.8.8.8 --tags "$tags" --onboot 1 --startup order=3 \
    > /var/tmp/ctcreate-$vmid.log 2>&1; then
    echo "CREATE-FAIL $vmid $host (log: /var/tmp/ctcreate-$vmid.log)"; return
  fi
  cat >> /etc/pve/lxc/$vmid.conf <<APPCFG
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cap.drop: mac_override sys_time sys_module sys_rawio
APPCFG
  pct start "$vmid" >> /var/tmp/ctcreate-$vmid.log 2>&1 \
    && echo "CREATE-OK $vmid $host" || echo "START-FAIL $vmid $host (log: /var/tmp/ctcreate-$vmid.log)"
}
jobs=()
for i in $(seq 0 22); do create_one $((1101+i)) os$i $((101+i)) juju,openstack & jobs+=($!); while [ "$(jobs -rp | wc -l)" -ge 4 ]; do sleep 2; done; done
for i in $(seq 0 3);  do create_one $((1124+i)) lma$i $((124+i)) juju,lma & jobs+=($!); while [ "$(jobs -rp | wc -l)" -ge 4 ]; do sleep 2; done; done
wait
echo "=== all created, running init ==="
for vmid in $(seq 1101 1127); do
  ( for t in $(seq 1 15); do
      out=$(pct exec $vmid -- bash -s < /root/juju-ct-init.sh 2>/dev/null) && { echo "$out"; break; }
      sleep 4
    done ) &
  while [ "$(jobs -rp | wc -l)" -ge 6 ]; do sleep 2; done
done
wait
echo "=== done ==="
