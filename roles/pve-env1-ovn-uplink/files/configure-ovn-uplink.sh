#!/bin/bash
set -euo pipefail

JUJU_BIN=${JUJU_BIN:-/snap/bin/juju}
MODEL=${MODEL:-pve-ctrl:openstack}
EXPECTED_MAPPING=${EXPECTED_MAPPING:-br-ex:ens22}
APP=${APP:-ovn-chassis}

current=$($JUJU_BIN config -m "$MODEL" "$APP" bridge-interface-mappings)
current=${current//$'\r'/}
case "$current" in
  null|None|\(unset\)|'<empty>') current='' ;;
esac
read -r -a entries <<<"$current"
updated=()
found=0
changed=0
for entry in "${entries[@]}"; do
  [[ -n "$entry" ]] || continue
  if [[ "$entry" == br-ex:* ]]; then
    if [[ "$entry" != "$EXPECTED_MAPPING" ]]; then
      changed=1
    fi
    if (( found == 0 )); then
      updated+=("$EXPECTED_MAPPING")
      found=1
    else
      changed=1
    fi
  else
    updated+=("$entry")
  fi
done
(( found == 1 )) || { updated+=("$EXPECTED_MAPPING"); changed=1; }

joined=$(IFS=' '; printf '%s' "${updated[*]}")
if (( changed == 1 )) || [[ "$joined" != "$current" ]]; then
  $JUJU_BIN config -m "$MODEL" "$APP" "bridge-interface-mappings=$joined"
  updated_config=1
else
  updated_config=0
fi

actual=$($JUJU_BIN config -m "$MODEL" "$APP" bridge-interface-mappings)
read -r -a actual_entries <<<"$actual"
count=0
for entry in "${actual_entries[@]}"; do
  [[ "$entry" == "$EXPECTED_MAPPING" ]] && ((count += 1))
done
[[ "$count" -eq 1 ]] || {
  printf 'Expected exactly one %s mapping, got: %s\n' "$EXPECTED_MAPPING" "$actual" >&2
  exit 1
}
printf 'OVN-UPLINK-MAPPING-OK changed=%s %s\n' "$updated_config" "$actual"
