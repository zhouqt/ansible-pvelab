#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 \"<vmid:loopindex> ...\"" >&2; exit 2; }
SIZE_MB="${OSD_SIZE_MB:-30720}"
FILES_DIR="${OSD_FILES_DIR:-/var/lib/ceph-osd-files}"
LOOP_BASE="${OSD_LOOP_BASE:-100}"
ATTACH_HELPER="/usr/local/sbin/yoga-osd-loop-attach.sh"
mkdir -p "$FILES_DIR"

cat > "$ATTACH_HELPER" <<'HELPER'
#!/bin/bash
set -u
idx="$1"
FILES_DIR="${OSD_FILES_DIR:-/var/lib/ceph-osd-files}"
LOOP_BASE="${OSD_LOOP_BASE:-100}"
img="$FILES_DIR/ceph-osd-compute-$idx.img"
loop_num=$((LOOP_BASE + idx))
loop_dev="/dev/loop$loop_num"

attached() { losetup -j "$img" -O NAME --noheadings 2>/dev/null | tr '\n' ' '; }

case " $(attached) " in *" $loop_dev "*) exit 0;; esac

for _ in $(seq 1 6); do
  rest=$(attached)
  [ -z "$(echo $rest)" ] && break
  for d in $rest; do [ "$d" = "$loop_dev" ] || losetup -d "$d" 2>/dev/null || true; done
  sleep 0.5
done

[ -b "$loop_dev" ] || mknod "$loop_dev" b 7 "$loop_num"
for _ in $(seq 1 10); do
  losetup "$loop_dev" "$img" 2>/dev/null && break
  sleep 0.5
done
case " $(attached) " in
  *" $loop_dev "*) exit 0;;
esac
echo "ERROR: $img could not be attached to $loop_dev (currently: $(attached))" >&2
exit 1
HELPER
chmod 0755 "$ATTACH_HELPER"

needs_change() {
  local vmid="$1" idx="$2" img="$3" loop_num="$4" loop_dev="$5"
  local conf="/etc/pve/lxc/$vmid.conf" unit="/etc/systemd/system/ceph-osd-loopback-$idx.service"

  [[ -s "$img" ]] || return 0
  case " $(losetup -j "$img" -O NAME --noheadings 2>/dev/null | tr '\n' ' ') " in
    *" $loop_dev "*) ;;
    *) return 0;;
  esac
  python3 - "$conf" "$idx" "$loop_num" <<'PY' || return 0
import sys
conf, idx, loop_num = sys.argv[1], sys.argv[2], sys.argv[3]
want = {
    f"# yoga-osd-loop-{idx}",
    f"lxc.mount.entry: /dev/loop{loop_num} dev/osd-block none bind,optional,create=file",
    f"lxc.cgroup2.devices.allow: b 7:{loop_num} rwm",
    "# yoga-osd-dm",
    "dev1: /dev/mapper/control",
    "lxc.cgroup2.devices.allow: b 252:* rwm",
}

def is_owned(s):
    if s in ("# yoga-osd-loop-" + idx, "# yoga-osd-dm"):
        return True
    if "dev/osd-block" in s:
        return True
    if s.startswith("lxc.cgroup2.devices.allow: b 7:"):
        return True
    if s.startswith("lxc.cgroup2.devices.allow: b 252:"):
        return True
    if s == "dev1: /dev/mapper/control":
        return True
    return False

got = {l.strip() for l in open(conf).read().splitlines() if is_owned(l.strip())}
sys.exit(0 if got == want else 1)
PY
  local want_unit
  want_unit=$(cat <<EOF
[Unit]
Description=Setup loopback device for yoga Ceph OSD $idx
DefaultDependencies=no
After=local-fs.target
Before=lvm2-activation.service pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ATTACH_HELPER $idx
ExecStop=/bin/bash -c 'losetup -d \$(losetup -j $img -O NAME --noheadings) 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
)
  [ "$want_unit" = "$(cat "$unit" 2>/dev/null)" ] || return 0

  return 1
}

CHANGED=0
for spec in $1; do
  vmid="${spec%%:*}"; idx="${spec##*:}"
  img="$FILES_DIR/ceph-osd-compute-$idx.img"
  loop_num=$((LOOP_BASE + idx))
  loop_dev="/dev/loop$loop_num"

  if ! needs_change "$vmid" "$idx" "$img" "$loop_num" "$loop_dev"; then
    echo "UNCHANGED vmid=$vmid idx=$idx"
    continue
  fi
  CHANGED=1

  if [[ ! -s "$img" ]]; then
    truncate -s "${SIZE_MB}M" "$img"
  fi

  if [ "$(pct status "$vmid" 2>/dev/null)" = "status: running" ]; then
    pct stop "$vmid"
    for _ in $(seq 1 60); do
      [ "$(pct status "$vmid" 2>/dev/null)" = "status: stopped" ] && break
      sleep 1
    done
  fi

  systemctl disable --now "ceph-osd-loopback-$idx.service" >/dev/null 2>&1 || true

  OSD_FILES_DIR="$FILES_DIR" OSD_LOOP_BASE="$LOOP_BASE" "$ATTACH_HELPER" "$idx"
  cur="$(losetup -j "$img" -O NAME --noheadings 2>/dev/null | tr '\n' ' ' || true)"
  case " $cur " in
    *" $loop_dev "*) ;;
    *) echo "ERROR: $img is not attached to $loop_dev (currently: $cur)" >&2; exit 1;;
  esac
  strays="$(for d in $cur; do [ "$d" = "$loop_dev" ] || echo "$d"; done | tr '\n' ' ')"
  if [ -n "$strays" ]; then
    echo "WARN: $img still has stale aliases: $strays (harmless, they vanish after a reboot)" >&2
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
ExecStart=$ATTACH_HELPER $idx
ExecStop=/bin/bash -c 'losetup -d \$(losetup -j $img -O NAME --noheadings) 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

  conf="/etc/pve/lxc/$vmid.conf"
  python3 - "$conf" "$idx" "$loop_num" <<'PY'
import sys
conf, idx, loop_num = sys.argv[1], sys.argv[2], sys.argv[3]
loop_marker = f"# yoga-osd-loop-{idx}"
dm_marker = "# yoga-osd-dm"
loop_block = [
    loop_marker,
    f"lxc.mount.entry: /dev/loop{loop_num} dev/osd-block none bind,optional,create=file",
    f"lxc.cgroup2.devices.allow: b 7:{loop_num} rwm",
]
dm_block = [
    dm_marker,
    "dev1: /dev/mapper/control",
    "lxc.cgroup2.devices.allow: b 252:* rwm",
]

def is_owned(line):
    s = line.strip()
    if s in (loop_marker, dm_marker):
        return True
    if "dev/osd-block" in s:
        return True
    if s.startswith("lxc.cgroup2.devices.allow: b 7:"):
        return True
    if s.startswith("lxc.cgroup2.devices.allow: b 252:"):
        return True
    if s == "dev1: /dev/mapper/control":
        return True
    return False

lines = [l for l in open(conf).read().splitlines() if not is_owned(l)]

final, inserted = [], False
for line in lines:
    if not inserted and line.strip().startswith("["):
        final.extend(loop_block)
        final.extend(dm_block)
        inserted = True
    final.append(line)
if not inserted:
    final.extend(loop_block)
    final.extend(dm_block)
open(conf, "w").write("\n".join(final) + "\n")
PY
done

systemctl daemon-reload
for spec in $1; do
  idx="${spec##*:}"
  systemctl enable --now "ceph-osd-loopback-$idx.service"
done
losetup -l
if [ "$CHANGED" -eq 1 ]; then
  echo YOGA-SETUP-OSD-LOOP-DONE
else
  echo YOGA-SETUP-OSD-LOOP-UNCHANGED
fi
