#!/bin/bash
set -u

HELPER=${HELPER:-/usr/local/lib/ansible-pve/patch_smbios_uuid.py}
DEST=${DEST:-/var/lib/ansible-pve/dmi}
SOURCE=${SOURCE:-/sys/firmware/dmi/tables/DMI}
CONF_DIR=${CONF_DIR:-/etc/pve/lxc}
REGISTRY=${REGISTRY:-/etc/pve/priv/ansible-pve/ct-system-uuid.conf}

if [ ! -r "$HELPER" ]; then
  echo "pve-ct-dmi-sync: helper $HELPER is missing" >&2
  exit 1
fi
if [ ! -r "$SOURCE" ]; then
  echo "pve-ct-dmi-sync: $SOURCE is missing; cannot rebuild the DMI copies" >&2
  exit 1
fi
if [ ! -d "$CONF_DIR" ]; then
  echo "pve-ct-dmi-sync: $CONF_DIR is not mounted; refusing to guess" >&2
  exit 1
fi

if [ ! -e "$REGISTRY" ]; then
  echo "pve-ct-dmi-sync: no registry at $REGISTRY; nothing to do"
  exit 0
fi
if [ ! -r "$REGISTRY" ]; then
  echo "pve-ct-dmi-sync: $REGISTRY is unreadable" >&2
  exit 1
fi

rows=$(awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  NF != 2 || $1 !~ /^[0-9]+$/ {
    printf "pve-ct-dmi-sync: %s:%d: expected \"<vmid> <uuid>\", got \"%s\"\n", FILENAME, FNR, $0 > "/dev/stderr"
    bad = 1
    next
  }
  { print $1, $2 }
  END { exit bad }
' "$REGISTRY") || exit 1

managed=0
failed=0
registered=" "
while read -r vmid uuid; do
  [ -n "$vmid" ] || continue
  managed=$((managed + 1))
  registered="$registered$vmid "
  if ! out=$(python3 "$HELPER" --source "$SOURCE" --dest-dir "$DEST/$vmid" --uuid "$uuid" 2>&1); then
    echo "pve-ct-dmi-sync: vmid $vmid: $out" >&2
    failed=$((failed + 1))
    continue
  fi
  echo "pve-ct-dmi-sync: vmid $vmid: $out"
done <<< "$rows"

for conf in "$CONF_DIR"/*.conf; do
  [ -e "$conf" ] || continue
  vmid=$(basename "$conf" .conf)
  case "$registered" in
    *" $vmid "*) continue ;;
  esac
  if awk -v dest="$DEST/" '
      /^\[/ { exit }
      /^lxc\.mount\.entry[[:space:]]*[:=]/ && index($0, dest) { found = 1; exit }
      END { exit found ? 0 : 1 }
    ' "$conf"; then
    if [ -e "$DEST/$vmid/DMI" ]; then
      echo "pve-ct-dmi-sync: warning: vmid $vmid binds $DEST but is not in $REGISTRY" >&2
    else
      echo "pve-ct-dmi-sync: vmid $vmid binds $DEST/$vmid/DMI, which is missing, and it is not in $REGISTRY" >&2
      failed=$((failed + 1))
    fi
  fi
done

echo "pve-ct-dmi-sync: $managed managed container(s), $failed failure(s)"
[ "$failed" -eq 0 ] || exit 1
exit 0
