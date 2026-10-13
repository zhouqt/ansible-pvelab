#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 \"<vmid:loopindex> ...\"" >&2; exit 2; }
SIZE_MB="${OSD_SIZE_MB:-30720}"
FILES_DIR="${OSD_FILES_DIR:-/var/lib/ceph-osd-files}"
mkdir -p "$FILES_DIR"

declare -A LOOP_FOR_VMID=()
for spec in $1; do
  vmid="${spec%%:*}"; idx="${spec##*:}"
  LOOP_FOR_VMID[$vmid]="$idx"

  img="$FILES_DIR/ceph-osd-compute-$idx.img"
  if [[ ! -s "$img" ]]; then
    truncate -s "${SIZE_MB}M" "$img"
  fi

  cat > "/etc/systemd/system/ceph-osd-loopback-$idx.service" <<EOF
[Unit]
Description=Setup loopback device for yoga Ceph OSD $idx
DefaultDependencies=no
After=local-fs.target
Before=lvm2-activation.service pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'losetup -j $img --noheadings | grep -q . || losetup /dev/loop$idx $img'
ExecStop=/bin/bash -c 'losetup -d \$(losetup -j $img -O NAME --noheadings) 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

  conf="/etc/pve/lxc/$vmid.conf"
  if ! grep -q "yoga-osd-loop-$idx" "$conf"; then
    python3 - "$conf" "$idx" <<'PY'
import sys
conf, idx = sys.argv[1], sys.argv[2]
lines = open(conf).read().splitlines()
block = [
    f"# yoga-osd-loop-{idx}",
    f"lxc.mount.entry: /dev/loop{idx} dev/osd-block none bind,optional,create=file",
    f"lxc.cgroup2.devices.allow: b 7:{idx} rwm",
]
out, inserted = [], False
for line in lines:
    if not inserted and line.strip().startswith("["):
        out.extend(block)
        inserted = True
    out.append(line)
if not inserted:
    out.extend(block)
open(conf, "w").write("\n".join(out) + "\n")
PY
  fi
done

systemctl daemon-reload
for spec in $1; do
  idx="${spec##*:}"
  systemctl enable --now "ceph-osd-loopback-$idx.service"
done
losetup -l
echo YOGA-SETUP-OSD-LOOP-DONE
