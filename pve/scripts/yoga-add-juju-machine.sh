#!/usr/bin/env bash
set -euo pipefail
ip="$1"
model="$2"
export HOME=/home/ubuntu PATH=/snap/bin:/usr/bin:/bin
juju="${JUJU_BIN:-/snap/bin/juju_yoga}"
export JUJU_DATA="${JUJU_DATA:-/home/ubuntu/.local/share/juju-yoga}"
status="$("$juju" status -m "$model" --format json)"
if python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception as error:
    print(f"ERROR: invalid Juju status JSON: {error}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(data, dict) or not isinstance(data.get("machines"), dict):
    raise SystemExit("ERROR: Juju status JSON has no machines object")
ip = sys.argv[1]
for machine_id, machine in data["machines"].items():
    if not isinstance(machine, dict):
        raise SystemExit(f"ERROR: Juju machine {machine_id} is invalid")
    addresses = machine.get("ip-addresses", [])
    dns_name = machine.get("dns-name", "")
    if not isinstance(addresses, list) or not all(isinstance(address, str) for address in addresses):
        raise SystemExit(f"ERROR: Juju machine {machine_id} has invalid ip-addresses")
    if not isinstance(dns_name, str):
        raise SystemExit(f"ERROR: Juju machine {machine_id} has invalid dns-name")
    if ip == dns_name or ip in addresses:
        raise SystemExit(0)
raise SystemExit(1)
' "$ip" <<<"$status"; then
  echo "EXISTS $model $ip"
  exit 0
else
  rc=$?
  [[ "$rc" == 1 ]] || exit "$rc"
fi
exec "$juju" add-machine "ssh:ubuntu@$ip" -m "$model"
