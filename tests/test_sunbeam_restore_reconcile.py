#!/usr/bin/env python3

import importlib.util
import pathlib
import unittest
import unittest.mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "roles/sunbeam-pve/files/restore_reconcile.py"
SPEC = importlib.util.spec_from_file_location("restore_reconcile", SCRIPT)
reconcile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reconcile)

def status(error_units=(), model="model-a"):
    units = {
        "app/0": {
            "workload-status": {
                "current": "error" if "app/0" in error_units else "active",
                "message": "hook failed" if "app/0" in error_units else "",
            },
            "juju-status": {"current": "idle"},
        },
        "app/1": {
            "workload-status": {
                "current": "error" if "app/1" in error_units else "active",
                "message": "another hook failed" if "app/1" in error_units else "",
            },
            "juju-status": {"current": "idle"},
        },
    }
    return {
        "model": {"name": model},
        "applications": {"app": {"units": units}},
        "machines": {},
    }

def machine_status(hostnames=("node-a", "node-b")):
    node_ips = {node["hostname"]: node["pub_ip"] for node in NODES}
    machines = {}
    units = {}
    for index, hostname in enumerate(hostnames):
        machine_id = str(index + 4)
        address = node_ips[hostname]
        machines[machine_id] = {
            "hostname": hostname,
            "instance-id": "manual:" + address,
            "ip-addresses": [address],
        }
        units["openstack-hypervisor/%d" % index] = {"machine": machine_id}
    return {
        "model": {"name": "openstack-machines"},
        "applications": {"openstack-hypervisor": {"units": units}},
        "machines": machines,
    }

NODES = [
    {"hostname": "node-a", "fqdn": "node-a.example.test", "pub_ip": "192.0.2.1", "vmid": 1201},
    {"hostname": "node-b", "fqdn": "node-b.example.test", "pub_ip": "192.0.2.2", "vmid": 1202},
]

class StatusTests(unittest.TestCase):
    def test_iaas_status_allows_subordinate_applications_without_top_level_units(self):
        status_data = machine_status(("node-a", "node-b"))
        status_data["applications"]["cinder-volume-ceph"] = {
            "charm": "cinder-volume",
            "charm-origin": "charmhub",
            "subordinate-to": ["cinder"],
        }
        status_data["applications"]["epa-orchestrator"] = {
            "charm": "epa-orchestrator",
            "charm-origin": "charmhub",
            "subordinate-to": ["openstack-hypervisor"],
        }
        for unit in status_data["applications"]["openstack-hypervisor"]["units"].values():
            unit["workload-status"] = {"current": "active", "message": ""}
            unit["subordinates"] = {
                "epa-orchestrator/0": {
                    "workload-status": {"current": "active", "message": ""},
                    "juju-status": {"current": "idle", "message": ""},
                }
            }
        parsed = reconcile.parse_status(
            __import__("json").dumps(status_data), "admin/openstack-machines"
        )
        self.assertEqual([], reconcile.workload_errors(parsed, "admin/openstack-machines"))
        self.assertEqual(2, len(reconcile.match_hypervisor_units(parsed, NODES)))

    def test_subordinate_application_without_units_does_not_hide_subordinate_error(self):
        status_data = machine_status(("node-a", "node-b"))
        status_data["applications"]["epa-orchestrator"] = {
            "charm": "epa-orchestrator",
            "charm-origin": "charmhub",
            "subordinate-to": ["openstack-hypervisor"],
        }
        first = status_data["applications"]["openstack-hypervisor"]["units"]["openstack-hypervisor/0"]
        for unit in status_data["applications"]["openstack-hypervisor"]["units"].values():
            unit["workload-status"] = {"current": "active", "message": ""}
        first["subordinates"] = {
            "epa-orchestrator/0": {
                "workload-status": {"current": "error", "message": "hook failed"},
                "juju-status": {"current": "idle", "message": ""},
            }
        }
        parsed = reconcile.parse_status(
            __import__("json").dumps(status_data), "admin/openstack-machines"
        )
        self.assertEqual(
            ["epa-orchestrator/0"],
            [error["unit"] for error in reconcile.workload_errors(parsed, "admin/openstack-machines")],
        )

    def test_recovery_entrypoint_executes_full_reconciliation(self):
        config = {
            "pct_bin": "/usr/sbin/pct",
            "primary_vmid": 1201,
            "node_user": "sunbeam",
            "openstack_model": "openstack",
            "machines_model": "admin/openstack-machines",
            "external_nic": "eth2",
            "physnet": "physnet1",
            "juju_recovery_rounds": 0,
            "juju_recovery_delay": 0,
            "gateway_timeout": 0,
            "gateway_poll_interval": 1,
            "nodes": NODES,
        }
        caas = status(model="openstack")
        iaas = machine_status(("node-a", "node-b"))
        for unit in iaas["applications"]["openstack-hypervisor"]["units"].values():
            unit["workload-status"] = {"current": "active", "message": ""}
            unit["subordinates"] = {}
        gateway = {
            "ready": True,
            "missing": [],
        }
        with unittest.mock.patch.object(
            reconcile, "read_model", side_effect=[caas, iaas]
        ), unittest.mock.patch.object(
            reconcile, "probe_node", return_value=gateway
        ), unittest.mock.patch.object(
            reconcile, "time"
        ):
            result = reconcile.execute_recovery(config)
        self.assertFalse(result["changed"])
        self.assertEqual("br-physnet1:physnet1:eth2", result["bridge_mapping"])
        self.assertEqual({"node-a", "node-b"}, set(result["gateway_states"]))

    def test_main_invokes_recovery_entrypoint_and_emits_json(self):
        output = __import__("io").StringIO()
        with unittest.mock.patch.object(reconcile.sys, "stdin", __import__("io").StringIO("{}")), \
             unittest.mock.patch.object(reconcile.sys, "stdout", output), \
             unittest.mock.patch.object(reconcile, "execute_recovery", return_value={"changed": False}):
            self.assertEqual(0, reconcile.main())
        self.assertEqual('{"changed": false}\n', output.getvalue())

    def test_iaas_status_rejects_invalid_subordinate_units_field(self):
        status_data = machine_status(("node-a", "node-b"))
        status_data["applications"]["cinder-volume-ceph"] = {"units": []}
        for unit in status_data["applications"]["openstack-hypervisor"]["units"].values():
            unit["workload-status"] = {"current": "active", "message": ""}
        with self.assertRaisesRegex(reconcile.RecoveryError, "Juju units for.*cinder-volume-ceph"):
            reconcile.parse_status(
                __import__("json").dumps(status_data), "admin/openstack-machines"
            )

    def test_valid_status_without_error(self):
        parsed = reconcile.parse_status(__import__("json").dumps(status()), "model-a")
        self.assertEqual([], reconcile.workload_errors(parsed, "model-a"))

    def test_status_with_multiple_error_units(self):
        parsed = reconcile.parse_status(
            __import__("json").dumps(status(("app/0", "app/1"))), "model-a"
        )
        self.assertEqual(
            ["app/1", "app/0"],
            [error["unit"] for error in reconcile.workload_errors(parsed, "model-a")],
        )

    def test_error_recovery_checks_both_models_and_retries_only_errors(self):
        models = ("model-a", "iaas")
        calls = []
        responses = {
            "model-a": [status(("app/0",)), status()],
            "iaas": [status(("app/1",), model="iaas"), status(model="iaas")],
        }

        def fetch(model):
            return responses[model].pop(0)

        def resolve(model, unit):
            calls.append((model, unit))

        _, resolved = reconcile.recover_workload_errors(
            models, fetch, resolve, max_rounds=2, delay=0, sleep_fn=lambda _: None
        )
        self.assertEqual([("model-a", "app/0"), ("iaas", "app/1")], calls)
        self.assertEqual(2, len(resolved))

    def test_rejects_invalid_or_missing_applications(self):
        for raw in ("not-json", "{}", "[]", '{"applications": []}'):
            with self.subTest(raw=raw), self.assertRaises(reconcile.RecoveryError):
                reconcile.parse_status(raw, "model-a")

    def test_subordinate_workload_errors_are_recovered(self):
        subordinate = {
            "workload-status": {"current": "error", "message": "subordinate hook failed"},
            "juju-status": {"current": "idle"},
        }
        current = status()
        current["applications"]["app"]["units"]["app/0"]["subordinates"] = {
            "nrpe/0": subordinate
        }
        parsed = reconcile.parse_status(__import__("json").dumps(current), "model-a")
        errors = reconcile.workload_errors(parsed, "model-a")
        self.assertEqual(["nrpe/0"], [error["unit"] for error in errors])

    def test_error_persists_after_bounded_recovery(self):
        with self.assertRaisesRegex(reconcile.RecoveryError, "last_status=.*workload-status"):
            reconcile.recover_workload_errors(
                ("model-a",),
                lambda _: status(("app/0",)),
                lambda *_: None,
                max_rounds=1,
                delay=0,
                sleep_fn=lambda _: None,
            )

class GatewayTests(unittest.TestCase):
    def test_machine_mapping_does_not_assume_unit_index_matches_inventory(self):
        machines = machine_status(("node-b", "node-a"))
        mapping = reconcile.match_hypervisor_units(machines, NODES)
        self.assertEqual(
            {"node-a": "openstack-hypervisor/1", "node-b": "openstack-hypervisor/0"},
            {entry["node"]["hostname"]: entry["unit"] for entry in mapping},
        )

    def test_mapping_fails_if_a_node_is_missing(self):
        with self.assertRaisesRegex(reconcile.RecoveryError, "node-b"):
            reconcile.match_hypervisor_units(machine_status(("node-a",)), NODES)

    def test_mapping_fails_if_identity_candidates_are_ambiguous(self):
        status_data = machine_status(("node-a", "node-b"))
        status_data["machines"]["4"]["ip-addresses"].append("192.0.2.2")
        with self.assertRaisesRegex(reconcile.RecoveryError, "candidates"):
            reconcile.match_hypervisor_units(status_data, NODES)

    def test_bridge_name_matches_sunbeam_long_physnet_algorithm(self):
        self.assertEqual("br-physnet1", reconcile.bridge_name("physnet1"))
        long_name = reconcile.bridge_name("verylongphysnetname")
        self.assertTrue(long_name.startswith("br-verylon-"))
        self.assertEqual(15, len(long_name))

    def test_complete_gateway_requires_flag_bridge_nic_and_patch_port(self):
        ready = reconcile.gateway_state(
            '"enable-chassis-as-gw"', ["br-ex"], ["eth2", "patch-provnet-x"], "eth2"
        )
        self.assertTrue(ready["ready"])
        for options, bridges, ports, missing in (
            ("", ["br-ex"], ["eth2", "patch-x"], "gateway-flag"),
            ("enable-chassis-as-gw", [], ["eth2", "patch-x"], "br-ex"),
            ("enable-chassis-as-gw", ["br-ex"], ["patch-x"], "external-nic"),
            ("enable-chassis-as-gw", ["br-ex"], ["eth2"], "patch-port"),
        ):
            with self.subTest(missing=missing):
                state = reconcile.gateway_state(options, bridges, ports, "eth2")
                self.assertIn(missing, state["missing"])

    def test_gateway_state_reports_a_bridge_that_is_down(self):
        state = reconcile.gateway_state(
            "enable-chassis-as-gw", ["br-ex"], ["eth2", "patch-x"], "eth2", link_up=False
        )
        self.assertEqual(["br-ex-down"], state["missing"])
        self.assertFalse(state["ready"])

    def test_ovs_binary_falls_back_and_is_cached_per_node(self):
        calls = []

        class Result:
            def __init__(self, returncode):
                self.returncode, self.stdout, self.stderr = returncode, "", "not found"

        def fake_exec(config, node, argv, timeout=30):
            calls.append(argv[0])
            return Result(0 if argv[0] == "/usr/bin/ovs-vsctl" else 127)

        cache = {}
        node = {"hostname": "node-a", "vmid": 1201}
        with unittest.mock.patch.object(reconcile, "exec_in_node", fake_exec):
            self.assertEqual("/usr/bin/ovs-vsctl", reconcile.resolve_ovs_bin({}, node, cache))
            self.assertEqual("/usr/bin/ovs-vsctl", reconcile.resolve_ovs_bin({}, node, cache))
        self.assertEqual(["/snap/bin/ovs-vsctl", "/usr/bin/ovs-vsctl"], calls)

    def test_ovs_binary_absence_is_a_hard_failure(self):
        class Result:
            returncode, stdout, stderr = 127, "", "missing"

        with unittest.mock.patch.object(
            reconcile, "exec_in_node", lambda *a, **k: Result()
        ), self.assertRaisesRegex(reconcile.RecoveryError, "No usable ovs-vsctl"):
            reconcile.resolve_ovs_bin({}, {"hostname": "node-a", "vmid": 1201}, {})

    def test_initial_probe_waits_for_br_ex_and_patch_topology(self):
        mapping = reconcile.match_hypervisor_units(machine_status(), NODES)
        calls = {"node-a": 0, "node-b": 0}

        def probe(node):
            hostname = node["hostname"]
            calls[hostname] += 1
            if calls[hostname] == 1:
                raise reconcile.RecoveryError("ovsdb not ready")
            return {"ready": True, "missing": []}

        probes = reconcile.wait_for_ovs_availability(
            mapping,
            probe,
            timeout=10,
            interval=1,
            sleep_fn=lambda _: None,
        )
        self.assertEqual({"node-a", "node-b"}, set(probes))

    def test_initial_probe_fails_when_ovs_never_becomes_available(self):
        mapping = reconcile.match_hypervisor_units(machine_status(), NODES)
        with self.assertRaisesRegex(reconcile.RecoveryError, "ovsdb not ready"):
            reconcile.wait_for_ovs_availability(
                mapping,
                lambda _: (_ for _ in ()).throw(reconcile.RecoveryError("ovsdb not ready")),
                timeout=1,
                interval=1,
                sleep_fn=lambda _: None,
            )

    def test_only_nodes_with_missing_gateway_configuration_receive_action(self):
        mapping = reconcile.match_hypervisor_units(machine_status(), NODES)
        probes = {
            "node-a": {"ready": True, "missing": []},
            "node-b": {"ready": False, "missing": ["external-nic", "br-ex-down"]},
        }
        self.assertEqual([], reconcile.select_gateway_repairs(mapping, probes))
        probes["node-b"]["missing"] = ["gateway-flag", "external-nic"]
        repairs = reconcile.select_gateway_repairs(mapping, probes)
        self.assertEqual(["openstack-hypervisor/1"], [entry["unit"] for entry in repairs])

if __name__ == "__main__":
    unittest.main(verbosity=2)
