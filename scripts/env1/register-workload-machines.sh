#!/usr/bin/env bash
set -euo pipefail

CLIENT_VMID="${CLIENT_VMID:-1000}"
CLIENT_USER="${CLIENT_USER:-ubuntu}"
JUJU_BIN="${JUJU_BIN:-/snap/bin/juju}"
MODEL="${MODEL:-openstack}"
IP_OFFSET="${IP_OFFSET:-1000}"
PRIMARY_PREFIX="${PRIMARY_PREFIX:-192.168.11}"
WORKLOAD_VMIDS="${WORKLOAD_VMIDS:?WORKLOAD_VMIDS is required (space separated vmid list, table order = machine number order)}"
read -r -a VMIDS <<<"$WORKLOAD_VMIDS"
[[ ${#VMIDS[@]} -gt 0 ]] || { echo "ERROR: WORKLOAD_VMIDS is empty" >&2; exit 2; }

CLIENT=(pct exec "$CLIENT_VMID" -- su - "$CLIENT_USER" -c)
changed=0

juju_status() {
  "${CLIENT[@]}" "$JUJU_BIN status -m $MODEL --format json"
}

machine_id_exists() {
  local mid=$1 status
  status=$(juju_status) || {
    echo "ERROR: could not read Juju status for model $MODEL" >&2
    exit 2
  }
  python3 -c '
import json, sys
try:
    status = json.loads(sys.stdin.read())
except Exception as error:
    print(f"ERROR: invalid Juju status JSON: {error}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(status, dict) or not isinstance(status.get("machines"), dict):
    print("ERROR: Juju status JSON has no machines object", file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(0 if sys.argv[1] in status["machines"] else 1)
' "$mid" <<<"$status"
}

machine_for_ip() {
  local ip=$1 status
  status=$(juju_status) || {
    echo "ERROR: could not read Juju status for model $MODEL" >&2
    exit 2
  }
  python3 -c '
import json, sys
try:
    status = json.loads(sys.stdin.read())
except Exception as error:
    raise SystemExit(f"ERROR: invalid Juju status JSON: {error}")
if not isinstance(status, dict) or not isinstance(status.get("machines"), dict):
    raise SystemExit("ERROR: Juju status JSON has no machines object")
found = None
for mid, machine in status["machines"].items():
    if not isinstance(machine, dict):
        raise SystemExit(f"ERROR: Juju machine {mid} is invalid")
    addresses = machine.get("ip-addresses", [])
    dns_name = machine.get("dns-name", "")
    if not isinstance(addresses, list) or not all(isinstance(address, str) for address in addresses):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid ip-addresses")
    if not isinstance(dns_name, str):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid dns-name")
    if sys.argv[1] == dns_name or sys.argv[1] in addresses:
        if found is not None and found != mid:
            raise SystemExit(f"ERROR: address {sys.argv[1]} appears on multiple Juju machines")
        found = mid
if found is not None:
    print(found)
' "$ip" <<<"$status"
}

machine_has_ip() {
  local mid=$1 ip=$2 status
  status=$(juju_status) || {
    echo "ERROR: could not read Juju status for model $MODEL" >&2
    exit 2
  }
  python3 -c '
import json, sys
try:
    status = json.loads(sys.stdin.read())
except Exception as error:
    raise SystemExit(f"ERROR: invalid Juju status JSON: {error}")
if not isinstance(status, dict) or not isinstance(status.get("machines"), dict):
    raise SystemExit("ERROR: Juju status JSON has no machines object")
machine = status["machines"].get(sys.argv[1])
if not isinstance(machine, dict):
    raise SystemExit(f"ERROR: Juju machine {sys.argv[1]} is missing or invalid")
addresses = machine.get("ip-addresses", [])
dns_name = machine.get("dns-name", "")
if not isinstance(addresses, list) or not all(isinstance(address, str) for address in addresses):
    raise SystemExit(f"ERROR: Juju machine {sys.argv[1]} has invalid ip-addresses")
if not isinstance(dns_name, str):
    raise SystemExit(f"ERROR: Juju machine {sys.argv[1]} has invalid dns-name")
if sys.argv[2] not in addresses and sys.argv[2] != dns_name:
    raise SystemExit(f"ERROR: Juju machine {sys.argv[1]} does not match {sys.argv[2]}")
' "$mid" "$ip" <<<"$status"
}

next_machine_id() {
  local status
  status=$(juju_status) || {
    echo "ERROR: could not read Juju status for model $MODEL" >&2
    exit 2
  }
  python3 -c '
import json, sys
try:
    status = json.loads(sys.stdin.read())
except Exception as error:
    raise SystemExit(f"ERROR: invalid Juju status JSON: {error}")
machines = status.get("machines", {})
try:
    ids = [int(key) for key in machines]
except (TypeError, ValueError):
    raise SystemExit("ERROR: Juju machine IDs are not numeric")
print(max(ids) + 1 if ids else 0)
' <<<"$status"
}

add_machine() {
  local ip=$1
  "${CLIENT[@]}" "/usr/local/sbin/add-juju-machine.sh $ip $MODEL"
  changed=1
}

install_known_host() {
  local ip=$1 key=$2
  printf '%s\n' "$key" | "${CLIENT[@]}" \
    "install -d -m 0700 ~/.ssh; touch ~/.ssh/known_hosts; ssh-keygen -R \"$ip\" -f ~/.ssh/known_hosts >/dev/null 2>&1 || true; ssh-keygen -R \"[$ip]:22\" -f ~/.ssh/known_hosts >/dev/null 2>&1 || true; cat >> ~/.ssh/known_hosts"
}

assert_inventory_safe() {
  local status
  status=$(juju_status) || {
    echo "ERROR: could not read Juju status for model $MODEL" >&2
    return 1
  }
  python3 -c '
import json, os, sys
try:
    status = json.loads(sys.stdin.read())
except Exception as error:
    raise SystemExit(f"ERROR: invalid Juju status JSON: {error}")
machines = status.get("machines")
if not isinstance(machines, dict):
    raise SystemExit("ERROR: Juju status JSON has no machines object")
try:
    ids = {int(key) for key in machines}
except (TypeError, ValueError):
    raise SystemExit("ERROR: Juju machine IDs are not numeric")
vmids = [int(v) for v in os.environ["WORKLOAD_VMIDS"].split()]
offset = int(os.environ.get("IP_OFFSET", "1000"))
prefix = os.environ.get("PRIMARY_PREFIX", "192.168.11")
if len(vmids) != len(set(vmids)):
    raise SystemExit("ERROR: WORKLOAD_VMIDS contains duplicates")
if not ids <= set(range(len(vmids))):
    raise SystemExit(
        f"ERROR: existing machine IDs {sorted(ids)} fall outside 0..{len(vmids) - 1}")
if ids != set(range(len(ids))):
    raise SystemExit(f"ERROR: machine IDs {sorted(ids)} are not a contiguous prefix from 0")
for mid in sorted(ids):
    expected = f"{prefix}.{vmids[mid] - offset}"
    machine = machines[str(mid)]
    if not isinstance(machine, dict):
        raise SystemExit(f"ERROR: Juju machine {mid} is invalid")
    addresses = machine.get("ip-addresses", [])
    dns_name = machine.get("dns-name", "")
    if not isinstance(addresses, list) or not all(isinstance(address, str) for address in addresses):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid ip-addresses")
    if not isinstance(dns_name, str):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid dns-name")
    if expected not in addresses and dns_name != expected:
        raise SystemExit(
            f"ERROR: machine {mid} should be {expected} (WORKLOAD_VMIDS[{mid}]={vmids[mid]}), "
            f"got dns-name={dns_name!r} addresses={addresses}")
' <<<"$status"
}

assert_inventory_safe

for vmid in "${VMIDS[@]}"; do
  ip="${PRIMARY_PREFIX}.$((vmid - IP_OFFSET))"
  key=
  for _ in $(seq 1 60); do
    key=$(ssh-keyscan -T 3 -H "$ip" 2>/dev/null) && [[ -n "$key" ]] && break
    sleep 5
  done
  [[ -n "$key" ]] || { echo "ERROR: SSH is not available on $ip" >&2; exit 1; }
  install_known_host "$ip" "$key"
done

for i in "${!VMIDS[@]}"; do
  vmid="${VMIDS[$i]}"
  ip="${PRIMARY_PREFIX}.$((vmid - IP_OFFSET))"
  actual=$(machine_for_ip "$ip")
  if [[ -n "$actual" ]]; then
    [[ "$actual" == "$i" ]] || {
      echo "ERROR: $ip is machine [$actual], topology (WORKLOAD_VMIDS[$i]=$vmid) expects $i" >&2
      exit 1
    }
    machine_has_ip "$i" "$ip"
    continue
  fi
  if machine_id_exists "$i"; then
    echo "ERROR: machine $i exists without the expected IP $ip" >&2
    exit 1
  fi
  next=$(next_machine_id)
  [[ "$next" == "$i" ]] || {
    echo "ERROR: Juju would assign machine $next next, but the topology expects machine $i;" >&2
    echo "       the model is not a clean contiguous prefix — rebuild it (juju destroy-model + add-model) first." >&2
    exit 1
  }
  add_machine "$ip"
  machine_has_ip "$i" "$ip"
done

assert_inventory_safe
count=$(juju_status | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("machines", {})))')
[[ "$count" == "${#VMIDS[@]}" ]] || {
  echo "ERROR: model has $count machines, topology expects ${#VMIDS[@]}" >&2
  exit 1
}

echo "JUJU-WORKLOAD-MAPPING-VERIFIED"
if [[ "$changed" == 1 ]]; then
  echo "JUJU-WORKLOAD-MAPPING-CHANGED"
fi