#!/usr/bin/env python3

import hashlib
import json
import shlex
import subprocess
import sys
import time
from typing import Callable, Dict, Iterable, List, Mapping, Sequence, Tuple

class RecoveryError(RuntimeError):
    pass

def parse_status(raw: str, model: str) -> dict:
    try:
        status = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError) as exc:
        raise RecoveryError("Juju status for %s is not valid JSON: %s" % (model, exc))
    if not isinstance(status, dict):
        raise RecoveryError("Juju status for %s is not a JSON object" % model)
    model_info = status.get("model")
    if not isinstance(model_info, dict) or not isinstance(model_info.get("name"), str):
        raise RecoveryError("Juju status for %s has no valid model identity" % model)
    expected_model = model.rsplit("/", 1)[-1]
    if model_info["name"] != expected_model:
        raise RecoveryError(
            "Juju status requested for %s reports model %s"
            % (model, model_info["name"])
        )
    if not isinstance(status.get("machines"), dict):
        raise RecoveryError("Juju status for %s has no valid machines map" % model)
    apps = status.get("applications")
    if not isinstance(apps, dict):
        raise RecoveryError("Juju status for %s has no valid applications map" % model)
    if not apps and not status["machines"]:
        raise RecoveryError("Juju status for %s has no application units or machines" % model)

    unit_count = 0
    for app_name, app in apps.items():
        if not isinstance(app, dict):
            raise RecoveryError("Juju application %s in %s is not an object" % (app_name, model))

        units = app.get("units", {})
        if not isinstance(units, dict):
            raise RecoveryError("Juju units for %s/%s is not an object" % (model, app_name))
        stack = list(units.items())
        while stack:
            unit_name, unit = stack.pop()
            if not isinstance(unit, dict):
                raise RecoveryError("Juju unit %s in %s is not an object" % (unit_name, model))
            workload = unit.get("workload-status")
            if not isinstance(workload, dict) or not isinstance(workload.get("current"), str):
                raise RecoveryError(
                    "Juju unit %s in %s has no valid workload-status.current"
                    % (unit_name, model)
                )
            unit_count += 1
            subordinates = unit.get("subordinates") or {}
            if not isinstance(subordinates, dict):
                raise RecoveryError("Juju subordinates for %s/%s is not an object" % (model, unit_name))
            stack.extend(subordinates.items())
    if not unit_count and not status["machines"]:
        raise RecoveryError("Juju status for %s contains no application units or machines" % model)
    return status

def workload_errors(status: Mapping, model: str) -> List[dict]:
    errors = []
    for app_name, app in status["applications"].items():
        stack = [
            (app_name, unit_name, unit)
            for unit_name, unit in (app.get("units") or {}).items()
        ]
        while stack:
            current_app, unit_name, unit = stack.pop()
            workload = unit["workload-status"]
            if workload["current"] == "error":
                errors.append(
                    {
                        "model": model,
                        "application": current_app,
                        "unit": unit_name,
                        "current": workload["current"],
                        "message": workload.get("message", ""),
                        "last_status": unit,
                    }
                )
            stack.extend(
                (subordinate.split("/", 1)[0], subordinate, value)
                for subordinate, value in (unit.get("subordinates") or {}).items()
            )
    return errors

def recover_workload_errors(
    models: Sequence[str],
    fetch_status: Callable[[str], dict],
    resolve_unit: Callable[[str, str], None],
    max_rounds: int,
    delay: int,
    sleep_fn: Callable[[int], None] = time.sleep,
) -> Tuple[Dict[str, dict], List[dict]]:
    snapshots = {model: parse_status(fetch_status(model), model) for model in models}
    resolved = []
    for round_number in range(max_rounds + 1):
        errors = [
            error
            for model in models
            for error in workload_errors(snapshots[model], model)
        ]
        if not errors:
            return snapshots, resolved
        if round_number == max_rounds:
            details = "; ".join(
                "%s %s workload=%s message=%s last_status=%s"
                % (
                    error["model"],
                    error["unit"],
                    error["current"],
                    error["message"] or "(none)",
                    json.dumps(error["last_status"], sort_keys=True),
                )
                for error in errors
            )
            raise RecoveryError(
                "Juju workload errors remain after %d recovery rounds: %s"
                % (max_rounds, details)
            )
        for error in errors:
            resolve_unit(error["model"], error["unit"])
            resolved.append({"model": error["model"], "unit": error["unit"]})
        if delay:
            sleep_fn(delay)
        snapshots = {model: parse_status(fetch_status(model), model) for model in models}
    raise RecoveryError("unreachable workload recovery state")

def match_hypervisor_units(status: Mapping, nodes: Sequence[Mapping]) -> List[dict]:
    applications = status.get("applications")
    hypervisor = (applications or {}).get("openstack-hypervisor")
    if not isinstance(hypervisor, dict) or not isinstance(hypervisor.get("units"), dict):
        raise RecoveryError("IAAS Juju status has no openstack-hypervisor units")
    if not hypervisor["units"]:
        raise RecoveryError("IAAS Juju status has an empty openstack-hypervisor unit map")
    machines = status.get("machines")
    if not isinstance(machines, dict) or not machines:
        raise RecoveryError("IAAS Juju status has no machines map")

    node_by_hostname = {}
    node_by_fqdn = {}
    node_by_ip = {}
    for node in nodes:
        hostname, fqdn, address = node.get("hostname"), node.get("fqdn"), node.get("pub_ip")
        if not hostname or not fqdn or not address:
            raise RecoveryError("Configured node lacks hostname/fqdn/pub_ip: %r" % node)
        if hostname in node_by_hostname or fqdn in node_by_fqdn or address in node_by_ip:
            raise RecoveryError("Configured nodes have duplicate identity fields: %r" % node)
        node_by_hostname[hostname] = node
        node_by_fqdn[fqdn] = node
        node_by_ip[address] = node

    mapping, matched_nodes, matched_machines = [], set(), set()
    for unit_name, unit in hypervisor["units"].items():
        if not isinstance(unit, dict):
            raise RecoveryError("Hypervisor unit %s is not an object" % unit_name)
        unit_parts = unit_name.rsplit("/", 1)
        if len(unit_parts) != 2 or unit_parts[0] != "openstack-hypervisor" or not unit_parts[1].isdigit():
            raise RecoveryError("Malformed hypervisor unit name: %s" % unit_name)
        machine_id = str(unit.get("machine", ""))
        machine = machines.get(machine_id)
        if not machine_id or not isinstance(machine, dict):
            raise RecoveryError("Hypervisor unit %s refers to missing machine %r" % (unit_name, machine_id))

        addresses = machine.get("ip-addresses") or []
        if not isinstance(addresses, list):
            raise RecoveryError("Machine %s has invalid ip-addresses: %r" % (machine_id, addresses))
        candidates = {}
        machine_hostname = machine.get("hostname")
        if machine_hostname in node_by_hostname:
            node = node_by_hostname[machine_hostname]
            candidates[node["hostname"]] = node
        elif machine_hostname in node_by_fqdn:
            node = node_by_fqdn[machine_hostname]
            candidates[node["hostname"]] = node
        for address in addresses:
            if address in node_by_ip:
                node = node_by_ip[address]
                candidates[node["hostname"]] = node
        instance_id = str(machine.get("instance-id", ""))
        for address, node in node_by_ip.items():
            if instance_id.endswith(":" + address):
                candidates[node["hostname"]] = node
        if len(candidates) != 1:
            raise RecoveryError(
                "Cannot uniquely map hypervisor unit %s machine=%s hostname=%r instance-id=%r "
                "addresses=%r to configured nodes; candidates=%s"
                % (unit_name, machine_id, machine_hostname, instance_id, addresses, sorted(candidates))
            )
        node = next(iter(candidates.values()))
        if node["hostname"] in matched_nodes or machine_id in matched_machines:
            raise RecoveryError(
                "Duplicate hypervisor mapping: unit=%s node=%s machine=%s"
                % (unit_name, node["hostname"], machine_id)
            )
        matched_nodes.add(node["hostname"])
        matched_machines.add(machine_id)
        mapping.append({"unit": unit_name, "machine": machine_id, "node": dict(node)})

    missing = sorted(set(node_by_hostname) - matched_nodes)
    if missing or len(mapping) != len(nodes):
        raise RecoveryError(
            "Incomplete hypervisor mapping; missing=%s mappings=%s"
            % (missing, mapping)
        )
    return mapping

def bridge_name(physnet: str) -> str:
    if not isinstance(physnet, str) or not physnet:
        raise RecoveryError("Physical network name must be a non-empty string")
    if len(physnet) <= 12:
        return "br-" + physnet
    return "br-%s-%s" % (physnet[:7], hashlib.sha256(physnet.encode("utf-8")).hexdigest()[:4])

def gateway_state(
    options: str, bridges: Iterable[str], ports: Iterable[str], nic: str, link_up: bool = True
) -> dict:
    bridge_set = {str(value).strip() for value in bridges}
    port_set = {str(value).strip() for value in ports}
    if isinstance(options, list):
        raw_options = ",".join(str(value).strip().strip('"') for value in options)
    else:
        raw_options = str(options).strip().strip('"')
    missing = []
    if "enable-chassis-as-gw" not in raw_options.split(","):
        missing.append("gateway-flag")
    if "br-ex" not in bridge_set:
        missing.append("br-ex")
    if "br-ex" in bridge_set and not link_up:
        missing.append("br-ex-down")
    if "br-ex" in bridge_set and nic not in port_set:
        missing.append("external-nic")
    if "br-ex" in bridge_set and not any(port.startswith("patch-") for port in port_set):
        missing.append("patch-port")
    return {"ready": not missing, "missing": missing}

def select_gateway_repairs(mapping: Sequence[Mapping], probes: Mapping[str, Mapping]) -> List[dict]:
    configuration_missing = {"gateway-flag", "br-ex", "patch-port"}
    return [
        entry
        for entry in mapping
        if configuration_missing.intersection(probes[entry["node"]["hostname"]]["missing"])
    ]

def wait_for_ovs_availability(
    mapping: Sequence[Mapping],
    probe: Callable[[Mapping], Mapping],
    timeout: int,
    interval: int,
    sleep_fn: Callable[[int], None] = time.sleep,
) -> Dict[str, dict]:
    attempts = max(0, timeout // max(1, interval))
    latest, last_errors = {}, {}
    for attempt in range(attempts + 1):
        latest, last_errors = {}, {}
        for entry in mapping:
            node = entry["node"]
            hostname = node["hostname"]
            try:
                latest[hostname] = probe(node)
            except (RecoveryError, subprocess.TimeoutExpired) as exc:
                last_errors[hostname] = str(exc)
        if not last_errors:

            return latest
        if attempt < attempts:
            sleep_fn(interval)
    raise RecoveryError(
        "OVS was not queryable on every node within %ss: %s"
        % (timeout, "; ".join("%s: %s" % item for item in sorted(last_errors.items())))
    )

def run_command(argv: Sequence[str], timeout: int = 60, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(list(argv), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    if check and result.returncode:
        raise RecoveryError(
            "Command failed (rc=%d): %s\nstdout=%s\nstderr=%s"
            % (result.returncode, shlex.join(argv), result.stdout.strip(), result.stderr.strip())
        )
    return result

def juju_command(config: Mapping, args: Sequence[str], timeout: int = 120) -> str:
    command = shlex.join(["juju"] + list(args))
    result = run_command(
        [config["pct_bin"], "exec", str(config["primary_vmid"]), "--", "su", "-", config["node_user"], "-c", command],
        timeout=timeout,
    )
    return result.stdout

def read_model(config: Mapping, model: str) -> dict:
    return parse_status(
        juju_command(config, ["status", "-m", model, "--format", "json"], timeout=120),
        model,
    )

OVS_CANDIDATES = ("/snap/bin/ovs-vsctl", "/usr/bin/ovs-vsctl")

def exec_in_node(config: Mapping, node: Mapping, argv: Sequence[str], timeout: int = 30):
    return run_command(
        [config["pct_bin"], "exec", str(node["vmid"]), "--"] + list(argv),
        timeout=timeout,
        check=False,
    )

def resolve_ovs_bin(config: Mapping, node: Mapping, cache: Dict[str, str]) -> str:
    hostname = node["hostname"]
    if hostname in cache:
        return cache[hostname]
    errors = []
    for candidate in OVS_CANDIDATES:
        result = exec_in_node(config, node, [candidate, "--version"])
        if result.returncode == 0:
            cache[hostname] = candidate
            return candidate
        errors.append("%s: %s" % (candidate, result.stderr.strip() or "rc=%d" % result.returncode))
    raise RecoveryError(
        "No usable ovs-vsctl in CT %s (%s): %s"
        % (node["vmid"], hostname, "; ".join(errors))
    )

def probe_node(config: Mapping, node: Mapping, cache: Dict[str, str]) -> dict:
    ovs = resolve_ovs_bin(config, node, cache)

    def ovs_probe(args: Sequence[str], allow_missing_option: bool = False) -> subprocess.CompletedProcess:
        result = exec_in_node(config, node, [ovs] + list(args))
        if result.returncode:
            missing_option = (
                allow_missing_option
                and "no key" in result.stderr.lower()
                and "ovn-cms-options" in result.stderr.lower()
            )
            if missing_option:
                result.stdout = ""
                return result
            raise RecoveryError(
                "OVS probe failed on %s (vmid=%s): ovs-vsctl %s rc=%d stderr=%s"
                % (node["hostname"], node["vmid"], shlex.join(args), result.returncode, result.stderr.strip())
            )
        return result

    options = ovs_probe(
        ["get", "Open_vSwitch", ".", "external_ids:ovn-cms-options"],
        allow_missing_option=True,
    ).stdout.strip()
    bridges = ovs_probe(["list-br"]).stdout.splitlines()
    if "br-ex" in bridges:
        ports = ovs_probe(["list-ports", "br-ex"]).stdout.splitlines()
    else:
        ports = []
    link = exec_in_node(config, node, ["ip", "-o", "link", "show", "dev", "br-ex"])
    link_text = link.stdout.strip() if link.returncode == 0 else ""
    link_up = bool(link_text and "UP" in link_text.split("<", 1)[-1].split(">", 1)[0].split(","))
    return gateway_state(options, bridges, ports, config["external_nic"], link_up)

def execute_recovery(config: Mapping) -> dict:
    if not isinstance(config, Mapping):
        raise RecoveryError("Recovery configuration must be a JSON object")
    required_config_fields = (
        "pct_bin", "primary_vmid", "node_user", "external_nic", "physnet", "nodes",
        "openstack_model", "machines_model",
    )
    for key in required_config_fields:
        if key not in config or config[key] in (None, ""):
            raise RecoveryError("Missing recovery configuration field %s" % key)
    models = [config["openstack_model"], config["machines_model"]]
    if len(set(models)) != 2:
        raise RecoveryError("The CAAS and IAAS Juju model names must be distinct")
    try:
        recovery_rounds = int(config.get("juju_recovery_rounds", 3))
        recovery_delay = int(config.get("juju_recovery_delay", 10))
        gateway_timeout = int(config.get("gateway_timeout", 360))
        gateway_interval = int(config.get("gateway_poll_interval", 10))
    except (TypeError, ValueError) as exc:
        raise RecoveryError("Invalid recovery timeout/retry configuration: %s" % exc)
    if recovery_rounds < 0 or recovery_delay < 0 or gateway_timeout < 0 or gateway_interval <= 0:
        raise RecoveryError("Recovery retry counts/delays must be non-negative and poll interval positive")
    nodes = config["nodes"]
    if not isinstance(nodes, list) or not nodes:
        raise RecoveryError("Recovery configuration has no nodes")
    required_node_fields = {"hostname", "fqdn", "pub_ip", "vmid"}
    for node in nodes:
        if not isinstance(node, dict) or not required_node_fields.issubset(node):
            raise RecoveryError("Each configured node must include hostname/fqdn/pub_ip/vmid: %r" % node)
        try:
            int(node["vmid"])
        except (TypeError, ValueError):
            raise RecoveryError("Invalid PVE VMID for node %r" % node)

    def fetch(model: str) -> dict:
        return read_model(config, model)

    def resolve(model: str, unit: str) -> None:

        result = run_command(
            [
                config["pct_bin"],
                "exec",
                str(config["primary_vmid"]),
                "--",
                "su",
                "-",
                config["node_user"],
                "-c",
                shlex.join(["juju", "resolved", "-m", model, unit]),
            ],
            timeout=120,
            check=False,
        )
        if result.returncode and "is not in an error state" not in result.stderr:
            raise RecoveryError(
                "Command failed (rc=%d): juju resolved -m %s %s\nstdout=%s\nstderr=%s"
                % (result.returncode, model, unit, result.stdout.strip(), result.stderr.strip())
            )

    snapshots, resolved_units = recover_workload_errors(
        models,
        fetch,
        resolve,
        recovery_rounds,
        recovery_delay,
    )
    mapping = match_hypervisor_units(snapshots[config["machines_model"]], nodes)
    ovs_cache: Dict[str, str] = {}
    initial = wait_for_ovs_availability(
        mapping,
        lambda node: probe_node(config, node, ovs_cache),
        gateway_timeout,
        gateway_interval,
    )
    repairs = select_gateway_repairs(mapping, initial)
    bridge_mapping = "%s:%s:%s" % (bridge_name(config["physnet"]), config["physnet"], config["external_nic"])
    gateway_actions = []
    for entry in repairs:
        juju_command(
            config,
            ["run", "-m", config["machines_model"], "--wait=5m", entry["unit"],
             "set-hypervisor-local-settings", "bridge-mapping=" + bridge_mapping],
            timeout=360,
        )
        gateway_actions.append(entry["unit"])

    attempts = max(0, gateway_timeout // gateway_interval)
    uplinks_added, bridges_raised, last_errors, final = [], [], [], {}
    for attempt in range(attempts + 1):
        final = {}
        for entry in mapping:
            node, hostname = entry["node"], entry["node"]["hostname"]
            try:
                state = probe_node(config, node, ovs_cache)
            except (RecoveryError, subprocess.TimeoutExpired) as exc:
                final[hostname] = {"ready": False, "missing": ["ovs-unavailable"]}
                last_errors.append("%s probe: %s" % (hostname, exc))
                continue
            if "br-ex" not in state["missing"]:
                if "external-nic" in state["missing"]:
                    ovs = resolve_ovs_bin(config, node, ovs_cache)
                    add = exec_in_node(
                        config, node,
                        [ovs, "--may-exist", "add-port", "br-ex", config["external_nic"]],
                    )
                    if add.returncode:
                        last_errors.append("%s add-port: %s" % (hostname, add.stderr.strip()))
                    elif hostname not in uplinks_added:
                        uplinks_added.append(hostname)
                if "br-ex-down" in state["missing"]:
                    up = exec_in_node(config, node, ["ip", "link", "set", "br-ex", "up"])
                    if up.returncode:
                        last_errors.append("%s br-ex up: %s" % (hostname, up.stderr.strip()))
                    elif hostname not in bridges_raised:
                        bridges_raised.append(hostname)
            try:
                final[hostname] = probe_node(config, node, ovs_cache)
            except (RecoveryError, subprocess.TimeoutExpired) as exc:
                final[hostname] = {"ready": False, "missing": ["ovs-unavailable"]}
                last_errors.append("%s final probe: %s" % (hostname, exc))
        if all(state["ready"] for state in final.values()):
            return {
                "changed": bool(resolved_units or gateway_actions or uplinks_added or bridges_raised),
                "resolved_units": resolved_units,
                "gateway_actions": gateway_actions,
                "uplinks_added": sorted(set(uplinks_added)),
                "bridges_raised": sorted(set(bridges_raised)),
                "gateway_states": final,
                "bridge_mapping": bridge_mapping,
            }
        if attempt < attempts:
            time.sleep(gateway_interval)
    details = "; ".join("%s missing=%s" % (hostname, state["missing"]) for hostname, state in sorted(final.items()))
    if last_errors:
        details += "; uplink commands: " + "; ".join(last_errors[-10:])
    raise RecoveryError("OVN gateway dataplane did not converge within %ss: %s" % (gateway_timeout, details))

def main() -> int:
    try:
        config = json.load(sys.stdin)
        if not isinstance(config, dict):
            raise RecoveryError("Recovery configuration must be a JSON object")
        print(json.dumps(execute_recovery(config), sort_keys=True))
        return 0
    except (RecoveryError, OSError, subprocess.TimeoutExpired, ValueError) as exc:
        print("RESTORE-RECONCILE-ERROR: %s" % exc, file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
