#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 \"<vmid:idx> ...\"" >&2; exit 2; }
SIZE_MB="${OSD_SIZE_MB:-30720}"
LV_PREFIX="${OSD_LV_PREFIX:?OSD_LV_PREFIX is required (e.g. <env_slug>-osd)}"
THINPOOL="${OSD_THINPOOL:-pve-thin-pool/pve-thin-pool}"
TP_VG="${THINPOOL%%/*}"
TP_LV="${THINPOOL##*/}"
MAX_DATA_PCT="${OSD_THINPOOL_MAX_DATA_PERCENT:-90}"
ATTACH_HELPER="/usr/local/sbin/yoga-osd-lv-attach.sh"

lv_of() { echo "$LV_PREFIX-$1"; }

cat > "$ATTACH_HELPER" <<'HELPER'
#!/bin/bash
set -u
lv="$1"
TP_VG="${OSD_THINPOOL_VG:-pve-thin-pool}"
TP_LV="${OSD_THINPOOL_LV:-pve-thin-pool}"
dev="/dev/$TP_VG/$lv"

is_active() { [ "$(lvs --noheadings -o lv_active "$TP_VG/$lv" 2>/dev/null | tr -d ' ')" = "active" ]; }

for _ in $(seq 1 8); do
  is_active && [ -b "$dev" ] && exit 0
  lvchange -ay "$TP_VG/$TP_LV" >/dev/null 2>&1 || true
  lvchange -ay "$TP_VG/$lv"    >/dev/null 2>&1 || true
  udevadm settle --timeout=10 >/dev/null 2>&1 || true
  if [ ! -e "$dev" ]; then
    dm="$(lvs --noheadings -o lv_dm_path "$TP_VG/$lv" 2>/dev/null | tr -d ' ')"
    [ -n "$dm" ] && [ -b "$dm" ] && ln -sfn "$dm" "$dev" || true
  fi
  sleep 0.5
done
echo "ERROR: $dev could not be activated (lv_attr: $(lvs --noheadings -o lv_attr "$TP_VG/$lv" 2>&1))" >&2
exit 1
HELPER
chmod 0755 "$ATTACH_HELPER"

pool_data_pct() { lvs --noheadings -o data_percent "$THINPOOL" 2>/dev/null | tr -d ' '; }
pool_size_b()   { lvs --noheadings -o lv_size --units b --nosuffix "$THINPOOL" 2>/dev/null | tr -d ' '; }
thin_used_b()   {
  lvs --noheadings -o lv_size --units b --nosuffix --select 'lv_attr=~^V' "$TP_VG" 2>/dev/null \
    | tr -d ' ' | awk '{s+=$1} END{print s+0}'
}

need_create=0
for spec in $1; do
  lvs "$TP_VG/$(lv_of "${spec##*:}")" >/dev/null 2>&1 || need_create=$((need_create + 1))
done
if [ "$need_create" -gt 0 ]; then
  data_pct="$(pool_data_pct)"; size_b="$(pool_size_b)"; used_b="$(thin_used_b)"
  new_b=$((need_create * SIZE_MB * 1024 * 1024))
  printf 'thin pool %s: size=%.1fG data=%s%% thin virtual allocated=%.1fG creating=%dx%dM this round\n' \
    "$THINPOOL" "$(echo "$size_b" | awk '{print $1/1073741824}')" "$data_pct" \
    "$(echo "$used_b" | awk '{print $1/1073741824}')" "$need_create" "$SIZE_MB"
  if awk -v d="$data_pct" -v m="$MAX_DATA_PCT" 'BEGIN{exit !(d >= m)}'; then
    echo "ERROR: thin pool usage ${data_pct}% >= ${MAX_DATA_PCT}% (threshold), refusing to create more OSD volumes;" >&2
    echo "       free up pool space first (tear down unused envs: --tags pve-yoga-teardown) or raise OSD_THINPOOL_MAX_DATA_PERCENT." >&2
    exit 1
  fi
  over=$(awk -v u="$used_b" -v n="$new_b" -v s="$size_b" 'BEGIN{print (u+n > s) ? 1 : 0}')
  [ "$over" = "1" ] && echo "WARN: after creation the thin pool virtual size will exceed its physical size (overprovisioned, billed on write, acceptable but worth watching)" >&2 || true
fi

needs_change() {
  local vmid="$1" idx="$2" lv="$3"
  local conf="/etc/pve/lxc/$vmid.conf" unit="/etc/systemd/system/ceph-osd-lv-$idx.service"

  lvs "$TP_VG/$lv" >/dev/null 2>&1 || return 0
  [ "$(lvs --noheadings -o lv_active "$TP_VG/$lv" 2>/dev/null | tr -d ' ')" = "active" ] || return 0
  python3 - "$conf" "$idx" "$TP_VG" "$lv" <<'PY' || return 0
import sys
conf, idx, tp_vg, lv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
want = {
    f"# yoga-osd-lv-{idx}",
    f"lxc.mount.entry: /dev/{tp_vg}/{lv} dev/osd-block none bind,optional,create=file",
    "# yoga-osd-dm",
    "dev1: /dev/mapper/control",
    "lxc.cgroup2.devices.allow: b 252:* rwm",
}

def is_owned(s):
    if s.startswith("# yoga-osd-lv-") or s.startswith("# yoga-osd-loop-"):
        return True
    if s == "# yoga-osd-dm":
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
Description=Activate thin-LV device for yoga Ceph OSD $idx
DefaultDependencies=no
After=local-fs.target
Before=lvm2-activation.service pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=OSD_THINPOOL_VG=$TP_VG
Environment=OSD_THINPOOL_LV=$TP_LV
ExecStart=$ATTACH_HELPER $lv
ExecStop=/bin/bash -c 'lvchange -an $TP_VG/$lv 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
)
  [ "$want_unit" = "$(cat "$unit" 2>/dev/null)" ] || return 0

  return 1
}

CHANGED=0
for spec in $1; do
  vmid="${spec%%:*}"; idx="${spec##*:}"; lv="$(lv_of "$idx")"

  if ! needs_change "$vmid" "$idx" "$lv"; then
    echo "UNCHANGED vmid=$vmid idx=$idx lv=$lv"
    continue
  fi
  CHANGED=1

  if ! lvs "$TP_VG/$lv" >/dev/null 2>&1; then
    lvcreate --yes --virtualsize "${SIZE_MB}M" --thin "$THINPOOL" --name "$lv"
  else
    cur_mb=$(lvs --noheadings -o lv_size --units m --nosuffix "$TP_VG/$lv" | tr -d ' ' | cut -d. -f1)
    if [ "${cur_mb:-0}" -ne "$SIZE_MB" ]; then
      echo "WARN: $TP_VG/$lv is ${cur_mb}M, expected ${SIZE_MB}M (not resized automatically, please check by hand)" >&2
    fi
  fi

  if [ "$(pct status "$vmid" 2>/dev/null)" = "status: running" ]; then
    pct stop "$vmid"
    for _ in $(seq 1 60); do
      [ "$(pct status "$vmid" 2>/dev/null)" = "status: stopped" ] && break
      sleep 1
    done
  fi

  systemctl disable --now "ceph-osd-lv-$idx.service" >/dev/null 2>&1 || true
  if [ -e "/etc/systemd/system/ceph-osd-loopback-$idx.service" ]; then
    echo "WARN: /etc/systemd/system/ceph-osd-loopback-$idx.service still exists on the host (left over from the old yoga setup or the reference environment);" >&2
    echo "      this script leaves it alone. If it is left over from the old yoga setup, run the old teardown first." >&2
  fi

  OSD_THINPOOL_VG="$TP_VG" OSD_THINPOOL_LV="$TP_LV" "$ATTACH_HELPER" "$lv"
  [ -b "/dev/$TP_VG/$lv" ] || { echo "ERROR: /dev/$TP_VG/$lv does not exist" >&2; exit 1; }

  cat > "/etc/systemd/system/ceph-osd-lv-$idx.service" <<EOF
[Unit]
Description=Activate thin-LV device for yoga Ceph OSD $idx
DefaultDependencies=no
After=local-fs.target
Before=lvm2-activation.service pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=OSD_THINPOOL_VG=$TP_VG
Environment=OSD_THINPOOL_LV=$TP_LV
ExecStart=$ATTACH_HELPER $lv
ExecStop=/bin/bash -c 'lvchange -an $TP_VG/$lv 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

  conf="/etc/pve/lxc/$vmid.conf"
  python3 - "$conf" "$idx" "$TP_VG" "$lv" <<'PY'
import sys
conf, idx, tp_vg, lv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lv_marker = f"# yoga-osd-lv-{idx}"
dm_marker = "# yoga-osd-dm"
lv_block = [
    lv_marker,
    f"lxc.mount.entry: /dev/{tp_vg}/{lv} dev/osd-block none bind,optional,create=file",
]
dm_block = [
    dm_marker,
    "dev1: /dev/mapper/control",
    "lxc.cgroup2.devices.allow: b 252:* rwm",
]

def is_owned(line):
    s = line.strip()
    if s.startswith("# yoga-osd-lv-") or s.startswith("# yoga-osd-loop-"):
        return True
    if s == dm_marker:
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
        final.extend(lv_block)
        final.extend(dm_block)
        inserted = True
    final.append(line)
if not inserted:
    final.extend(lv_block)
    final.extend(dm_block)
open(conf, "w").write("\n".join(final) + "\n")
PY
done

systemctl daemon-reload
for spec in $1; do
  idx="${spec##*:}"
  systemctl enable --now "ceph-osd-lv-$idx.service"
done
lvs -a "$TP_VG" | grep -E "$LV_PREFIX|$TP_LV" || true
if [ "$CHANGED" -eq 1 ]; then
  echo YOGA-SETUP-OSD-LV-DONE
else
  echo YOGA-SETUP-OSD-LV-UNCHANGED
fi
