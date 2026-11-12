#!/bin/bash
set -euo pipefail
cd /var/tmp
IMG=ubuntu-20.04-server-cloudimg-amd64.img
if [ ! -s $IMG ]; then
  curl -fsSLO https://cloud-images.ubuntu.com/releases/focal/release/$IMG
fi
echo "image: $(ls -la $IMG)"
qm destroy 1122 --purge 2>/dev/null || true
qm create 1122 --name nova-compute-kvm --ostype l26 --cores 4 --memory 8192 --balloon 0 \
  --cpu host --sockets 1 \
  --net0 virtio,bridge=pub11,firewall=0 \
  --onboot 1 --startup order=3 --agent 1 --serial0 socket --vga std
qm importdisk 1122 $IMG pve-thin-pool
qm set 1122 --scsihw virtio-scsi-pci --scsi0 pve-thin-pool:vm-1122-disk-0,iothread=1
qm resize 1122 scsi0 32G
qm set 1122 --ide2 pve-thin-pool:cloudinit --boot order=scsi0
qm set 1122 --ciuser ubuntu --sshkeys /root/juju-key.pub \
  --ipconfig0 ip=192.168.11.122/24,gw=192.168.11.1 --nameserver 8.8.8.8
qm start 1122
echo "VM-1122-STARTED"
