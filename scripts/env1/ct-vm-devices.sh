#!/bin/bash
set -euo pipefail

DEVICES=(/dev/net/tun /dev/kvm)
MAX_DEV_SLOT=99

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <vmid> [<vmid> ...]" >&2
  exit 2
fi

for vmid in "$@"; do
  if ! pct status "$vmid" >/dev/null 2>&1; then
    echo "CT-$vmid-UNKNOWN: no such container, skipping" >&2
    exit 1
  fi

  conf="$(pct config "$vmid")"

  for dev in "${DEVICES[@]}"; do
    dev_re="${dev//./\\.}"
    if grep -qE "^dev[0-9]+: .*path=${dev_re}(,|$)" <<<"$conf"; then
      echo "PRESENT $vmid $dev"
      continue
    fi

    slot=""
    for n in $(seq 0 "$MAX_DEV_SLOT"); do
      if ! grep -qE "^dev${n}:" <<<"$conf"; then
        slot="$n"
        break
      fi
    done
    if [[ -z "$slot" ]]; then
      echo "CT-$vmid-NO-FREE-DEV-SLOT: dev0..dev${MAX_DEV_SLOT} are all taken" >&2
      exit 1
    fi

    pct set "$vmid" "--dev${slot}" "path=${dev}"
    echo "ADDED $vmid dev${slot} ${dev}"

    conf="$(pct config "$vmid")"
  done
done

echo "USSURI-CT-VM-DEVICES-DONE"
