#!/bin/bash
set -u
export HOME=/root
J=/snap/bin/juju

for i in $(seq 101 127); do ssh-keyscan -H 192.168.11.$i >> /root/.ssh/known_hosts 2>/dev/null; done

$J add-model openstack --config enable-os-upgrade=false || $J add-model openstack
$J add-model lma --config enable-os-upgrade=false || $J add-model lma

fail=0
for i in $(seq 101 123); do
  ip=192.168.11.$i
  out=$($J add-machine "ssh:ubuntu@$ip" -m openstack 2>&1)
  echo "openstack $ip => $(echo "$out" | tail -1)"
  echo "$out" | grep -qiE "^ERROR" && fail=$((fail+1))
done
for i in $(seq 124 127); do
  ip=192.168.11.$i
  out=$($J add-machine "ssh:ubuntu@$ip" -m lma 2>&1)
  echo "lma $ip => $(echo "$out" | tail -1)"
  echo "$out" | grep -qiE "^ERROR" && fail=$((fail+1))
done
echo "ADD-FAILURES:$fail"
$J status -m openstack | sed -n '/^Machine/,$p' | head -30
$J status -m lma | sed -n '/^Machine/,$p'
