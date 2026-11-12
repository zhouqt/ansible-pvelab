#!/bin/bash
set -euo pipefail

MIRROR="${1:-}"
if [ -z "$MIRROR" ]; then
  echo "APT-MIRROR mirror= changed=0 (disabled)"
  exit 0
fi

files=()
[ -f /etc/apt/sources.list ] && files+=(/etc/apt/sources.list)
if [ -d /etc/apt/sources.list.d ]; then
  while IFS= read -r -d '' f; do files+=("$f"); done < <(
    find /etc/apt/sources.list.d -maxdepth 1 -type f \
      \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null
  )
fi

changed=0
for f in "${files[@]}"; do
  before=$(sha1sum "$f" | awk '{print $1}')
  sed -i -E \
    -e "s@https?://(archive|security)\.ubuntu\.com/ubuntu@http://${MIRROR}/ubuntu@g" \
    -e "s@https?://ports\.ubuntu\.com/ubuntu-ports@http://${MIRROR}/ubuntu-ports@g" \
    "$f"
  after=$(sha1sum "$f" | awk '{print $1}')
  [ "$before" = "$after" ] || changed=1
done

echo "APT-MIRROR mirror=${MIRROR} changed=${changed}"
