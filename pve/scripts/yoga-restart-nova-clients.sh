#!/bin/bash

set -uo pipefail

rc=0

for unit in nova-conductor nova-scheduler nova-compute; do
    if ! systemctl is-active --quiet "$unit"; then
        echo "NOVA-SKIP $unit"
        continue
    fi
    if systemctl restart "$unit"; then
        echo "NOVA-REFRESHED $unit"
    else
        echo "NOVA-REFRESH-FAILED $unit"
        rc=1
    fi
done

if systemctl is-active --quiet apache2 \
   && ls /etc/apache2/sites-enabled/ 2>/dev/null | grep -qi '^nova'; then
    if systemctl reload apache2; then
        echo "NOVA-REFRESHED apache2(nova-api)"
    else
        echo "NOVA-REFRESH-FAILED apache2"
        rc=1
    fi
fi

echo "NOVA-REFRESH-DONE"
exit "$rc"
