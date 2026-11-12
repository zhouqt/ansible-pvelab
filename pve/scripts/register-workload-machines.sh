#!/usr/bin/env bash
set -euo pipefail

CLIENT_VMID="${CLIENT_VMID:-1000}"
CLIENT_USER="${CLIENT_USER:-ubuntu}"
JUJU_BIN="${JUJU_BIN:-/snap/bin/juju}"
CLIENT=(pct exec "$CLIENT_VMID" -- su - "$CLIENT_USER" -c)
changed=0

juju_status() {
  "${CLIENT[@]}" "$JUJU_BIN status -m $1 --format json"
}

machine_id_exists() {
  local model=$1 mid=$2 status rc
  status=$(juju_status "$model") || {
    echo "ERROR: could not read Juju status for model $model" >&2
    exit 2
  }
  if python3 -c '
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
' "$mid" <<<"$status"; then
    return 0
  else
    rc=$?
    [[ "$rc" == 1 ]] && return 1
    exit "$rc"
  fi
}

machine_for_ip() {
  local model=$1 ip=$2 status
  status=$(juju_status "$model") || {
    echo "ERROR: could not read Juju status for model $model" >&2
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
  local model=$1 mid=$2 ip=$3 status
  status=$(juju_status "$model") || {
    echo "ERROR: could not read Juju status for model $model" >&2
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

add_machine() {
  local model=$1 ip=$2
  "${CLIENT[@]}" "/usr/local/sbin/add-juju-machine.sh $ip $model"
  changed=1
}

install_known_host() {
  local ip=$1 key=$2
  printf '%s\n' "$key" | "${CLIENT[@]}" \
    "install -d -m 0700 ~/.ssh; touch ~/.ssh/known_hosts; if ssh-keygen -F \"[$ip]:22\" -f ~/.ssh/known_hosts >/dev/null || ssh-keygen -F \"$ip\" -f ~/.ssh/known_hosts >/dev/null; then cat >/dev/null; else cat >> ~/.ssh/known_hosts; fi"
}

assert_openstack_inventory_safe() {
  local status
  status=$(juju_status openstack) || {
    echo "ERROR: could not read Juju status for model openstack" >&2
    return 1
  }
  python3 -c '
import json, sys
try:
    status = json.loads(sys.stdin.read())
except Exception as error:
    raise SystemExit(f"ERROR: invalid Juju status JSON: {error}")
if not isinstance(status, dict) or not isinstance(status.get("machines"), dict):
    raise SystemExit("ERROR: Juju status JSON has no machines object")
machines = status["machines"]
try:
    ids = {int(key) for key in machines}
except (TypeError, ValueError):
    raise SystemExit("ERROR: Juju machine IDs are not numeric")
normal = set(range(21))
fixed = normal | {22, 23}
if ids <= normal:
    if ids != set(range(len(ids))):
        raise SystemExit("ERROR: OpenStack machine IDs are not a contiguous prefix from 0")
elif ids != fixed:
    raise SystemExit("ERROR: existing OpenStack machines conflict with the fixed map; expected a contiguous prefix 0-20 or the complete map 0-20,22,23 with 21 absent")
for mid in ids:
    if mid == 21:
        raise SystemExit("ERROR: machine 21 must remain absent")
    expected_ip = "192.168.11." + str(101 + mid) if mid <= 20 else ("192.168.11.123" if mid == 22 else "192.168.11.122")
    machine = machines[str(mid)]
    if not isinstance(machine, dict):
        raise SystemExit(f"ERROR: Juju machine {mid} is invalid")
    addresses = machine.get("ip-addresses", [])
    dns_name = machine.get("dns-name", "")
    if not isinstance(addresses, list) or not all(isinstance(address, str) for address in addresses):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid ip-addresses")
    if not isinstance(dns_name, str):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid dns-name")
    if expected_ip not in addresses and dns_name != expected_ip:
        raise SystemExit(f"ERROR: Juju machine {mid} does not match {expected_ip}")
' <<<"$status"
}

assert_lma_inventory_safe() {
  local status
  status=$(juju_status lma) || {
    echo "ERROR: could not read Juju status for model lma" >&2
    return 1
  }
  python3 -c '
import json, sys
try:
    status = json.loads(sys.stdin.read())
except Exception as error:
    raise SystemExit(f"ERROR: invalid Juju status JSON: {error}")
if not isinstance(status, dict) or not isinstance(status.get("machines"), dict):
    raise SystemExit("ERROR: Juju status JSON has no machines object")
machines = status["machines"]
try:
    ids = {int(key) for key in machines}
except (TypeError, ValueError):
    raise SystemExit("ERROR: Juju machine IDs are not numeric")
if ids != set(range(len(ids))) or len(ids) > 4:
    raise SystemExit("ERROR: LMA machine IDs must be a contiguous prefix from 0 to 3")
for mid in ids:
    expected_ip = "192.168.11." + str(124 + mid)
    machine = machines[str(mid)]
    if not isinstance(machine, dict):
        raise SystemExit(f"ERROR: Juju machine {mid} is invalid")
    addresses = machine.get("ip-addresses", [])
    dns_name = machine.get("dns-name", "")
    if not isinstance(addresses, list) or not all(isinstance(address, str) for address in addresses):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid ip-addresses")
    if not isinstance(dns_name, str):
        raise SystemExit(f"ERROR: Juju machine {mid} has invalid dns-name")
    if expected_ip not in addresses and dns_name != expected_ip:
        raise SystemExit(f"ERROR: Juju machine {mid} does not match {expected_ip}")
' <<<"$status"
}

assert_openstack_inventory_safe
assert_lma_inventory_safe

for octet in $(seq 101 127); do
  ip="192.168.11.$octet"
  key=
  for _ in $(seq 1 60); do
    key=$(ssh-keyscan -T 3 -H "$ip" 2>/dev/null) && [[ -n "$key" ]] && break
    sleep 5
  done
  [[ -n "$key" ]] || { echo "ERROR: SSH is not available on $ip" >&2; exit 1; }
  install_known_host "$ip" "$key"
done

for octet in $(seq 101 121); do
  ip="192.168.11.$octet"
  expected=$((octet - 101))
  actual=$(machine_for_ip openstack "$ip")
  if [[ -z "$actual" ]]; then
    if machine_id_exists openstack "$expected"; then
      echo "ERROR: OpenStack machine $expected exists without expected IP $ip" >&2
      exit 1
    fi
    add_machine openstack "$ip"
    actual=$(machine_for_ip openstack "$ip")
  fi
  [[ "$actual" == "$expected" ]] || {
    echo "ERROR: OpenStack $ip is machine [$actual], expected $expected" >&2
    exit 1
  }
  machine_has_ip openstack "$expected" "$ip"
done

for octet in $(seq 124 127); do
  ip="192.168.11.$octet"
  expected=$((octet - 124))
  actual=$(machine_for_ip lma "$ip")
  if [[ -z "$actual" ]]; then
    if machine_id_exists lma "$expected"; then
      echo "ERROR: LMA machine $expected exists without expected IP $ip" >&2
      exit 1
    fi
    add_machine lma "$ip"
    actual=$(machine_for_ip lma "$ip")
  fi
  [[ "$actual" == "$expected" ]] || {
    echo "ERROR: LMA $ip is machine [$actual], expected $expected" >&2
    exit 1
  }
  machine_has_ip lma "$expected" "$ip"
done

assert_openstack_inventory_safe
if ! machine_id_exists openstack 22 || ! machine_id_exists openstack 23; then
  echo "ERROR: machines 22/23 are not both registered. Automatic machine-21 reservation/removal is disabled until Juju 2.9 allocation behavior is verified; fixed mapping requires machine 21 absent, machine 22=.123, machine 23=.122. No machine was removed." >&2
  exit 1
fi

echo "JUJU-WORKLOAD-MAPPING-VERIFIED"
if [[ "$changed" == 1 ]]; then
  echo "JUJU-WORKLOAD-MAPPING-CHANGED"
fi
