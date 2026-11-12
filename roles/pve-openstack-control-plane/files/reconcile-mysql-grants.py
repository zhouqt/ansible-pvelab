#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
import time

DB_ROUTER_ENDPOINT = "db-router"
MYSQL_APP = "mysql-innodb-cluster"
ROUTER_CHARM = "mysql-router"
RW_MARKER = "Mode: R/W"

SETTLED_WORKLOAD = {"active", "blocked", "error"}

TRANSIENT_WORKLOAD = {"install", "maintenance", "unknown"}

TRANSIENT_SQL_RE = re.compile(
    r"ERROR (?:20(?:0[236]|13)|1040|1053) \(HY000\)"
    r"|Lost connection to MySQL server"
    r"|Can't connect to (?:local )?MySQL server"
    r"|MySQL server has gone away"
    r"|Too many connections")

def die(msg, code=1):
    print("RECONCILE-ERROR " + msg, file=sys.stderr)
    sys.exit(code)

def quote_id(name):

    return "`" + name.replace("`", "``") + "`"

def quote_lit(value):

    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"

class Runner:
    def __init__(self, args):
        self.args = args

    def pct(self, vmid, argv, stdin=None):

        cmd = ["pct", "exec", str(vmid), "--"] + [str(a) for a in argv]
        return subprocess.run(cmd, input=stdin, text=True,
                              capture_output=True, check=False)

    def juju(self, argv, check=True):

        inner = "JUJU_DATA={} {} {}".format(
            self.args.juju_data, self.args.juju_bin,
            " ".join("'{}'".format(a.replace("'", "'\\''")) for a in argv))
        res = self.pct(self.args.client_ct,
                       ["su", "-", self.args.client_user, "-c", inner])
        if check and res.returncode != 0:
            die("juju {} failed: {}".format(" ".join(argv[:2]), res.stderr.strip()))
        return res.stdout

    def juju_json(self, argv):
        return json.loads(self.juju(argv + ["--format", "json"]))

    def mysql(self, sql, mysql_vmid):

        delay = getattr(self.args, "mysql_retry_delay", 10)
        timeout = getattr(self.args, "mysql_retry_timeout", 600)
        retries = getattr(self.args, "mysql_retries", 30)
        deadline = time.time() + timeout
        attempt = 0
        while True:
            attempt += 1
            res = self.pct(mysql_vmid, ["mysql", "--defaults-file=/root/.my.cnf",
                                        "-N", "-B", "-e", sql])
            if res.returncode == 0 or not TRANSIENT_SQL_RE.search(res.stderr or ""):
                return res
            if attempt >= retries or time.time() >= deadline:
                return res
            tail = (res.stderr or "").strip().splitlines()
            print("RECONCILE-INFO MySQL transient connection error (attempt {}, waited {}s/{}s), retrying in {}s: {}"
                  .format(attempt, int(time.time() - (deadline - timeout)), timeout, delay,
                          tail[-1] if tail else ""))
            time.sleep(delay)

def show_unit(runner, unit):

    return runner.juju_json(["show-unit", "-m", runner.args.model, unit])

def relation_units(runner, unit, endpoint):

    data = show_unit(runner, unit)
    out = []
    for rel in (data.get(unit, {}).get("relation-info") or []):
        if rel.get("endpoint") != endpoint:
            continue
        for runit, body in (rel.get("related-units") or {}).items():
            out.append((runit, body.get("data") or {}))
    return out

def expected_requests(runner, leader):

    entries = []
    for router_unit, rdata in relation_units(runner, leader, DB_ROUTER_ENDPOINT):
        for key, user in rdata.items():
            if not key.endswith("_username"):
                continue
            prefix = key[: -len("_username")]
            host = rdata.get(prefix + "_hostname")
            if user and host:
                entries.append({"prefix": prefix, "router": router_unit,
                                "user": user, "host": host})
    return entries

def unquote(value):

    if isinstance(value, str) and len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except ValueError:
            return value
    return value

def published_password(runner, router_unit, prefix):

    for _mysql_unit, rdata in relation_units(runner, router_unit, DB_ROUTER_ENDPOINT):
        if prefix + "_password" in rdata:
            return unquote(rdata[prefix + "_password"])
    return None

def password_for(runner, requests, user, host):

    entry = next((e for e in requests
                  if e["user"] == user and e["host"] == host), None)
    return published_password(runner, entry["router"], entry["prefix"]) if entry else None

def wait_for_published_passwords(runner, requests, missing, timeout, interval):

    pending = list(missing)
    if not pending:
        return []
    deadline = time.time() + timeout
    while True:
        pending = [p for p in pending
                   if not password_for(runner, requests, p[0], p[1])]
        if not pending:
            return []
        if time.time() >= deadline:
            print("RECONCILE-INFO after {}s, {} requests still have no password written back: {}".format(
                timeout, len(pending),
                ", ".join("{}@{}".format(u, h) for u, h in pending)))
            return pending
        time.sleep(interval)

def existing_grants(runner, mysql_vmid):
    res = runner.mysql("SELECT CONCAT(user, '@', host) FROM mysql.user", mysql_vmid)
    if res.returncode != 0:
        die("reading mysql.user failed: {}".format(res.stderr.strip()))
    pairs = set()
    for line in res.stdout.splitlines():
        line = line.strip()
        if "@" in line:
            user, _, host = line.partition("@")
            pairs.add((user, host))
    return pairs

def ensure_root_access(runner, unit, mysql_vmid, dump_db):

    if runner.pct(mysql_vmid, ["test", "-f", "/root/.my.cnf"]).returncode == 0:
        return
    print("RECONCILE-INFO wrote /root/.my.cnf (side effect of the charm mysqldump action)")

    runner.juju(["run", unit, "mysqldump", "databases=" + dump_db,
                 "--wait", "5m", "-m", runner.args.model], check=False)
    if runner.pct(mysql_vmid, ["test", "-f", "/root/.my.cnf"]).returncode != 0:
        die("the charm mysqldump action did not write /root/.my.cnf")

def super_read_only(runner, mysql_vmid):

    res = runner.mysql("SELECT @@super_read_only", mysql_vmid)
    if res.returncode != 0:
        return None
    return res.stdout.strip()

def assert_writable(runner, unit, mysql_vmid):

    val = super_read_only(runner, mysql_vmid)
    if val is None:
        die("reading @@super_read_only on {} (CT {}) failed (was /root/.my.cnf written?)".format(
            unit, mysql_vmid))
    if val != "0":
        die("{} (CT {}) is not the R/W primary (@@super_read_only={}), refusing to apply SQL here;"
            "just re-run this playbook (it is idempotent); it re-detects the primary.".format(
                unit, mysql_vmid, val))

def parse_juju_run_json(out):

    for line in reversed((out or "").splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            return json.loads(line)
        except ValueError:
            continue
    return None

def primary_from_status(units):

    rw = sorted(u for u, v in units.items()
                if RW_MARKER in ((v.get("workload-status") or {}).get("message") or ""))
    return rw[0] if len(rw) == 1 else None

def primary_from_action(runner, units, any_unit):

    out = runner.juju(["run", any_unit, "cluster-status", "--format", "json",
                       "--wait", "2m", "-m", runner.args.model], check=False)
    payload = parse_juju_run_json(out)
    if not payload:
        return None
    raw = ((payload.get(any_unit) or {}).get("results") or {}).get("cluster-status")
    if not raw:
        return None
    try:
        primary = json.loads(raw)["defaultReplicaSet"]["primary"]
    except (ValueError, KeyError, TypeError):
        return None
    octet = str(primary).split(":")[0].rsplit(".", 1)[-1]
    hits = sorted(u for u, v in units.items()
                  if str(v.get("public-address") or "").rsplit(".", 1)[-1] == octet)
    return hits[0] if len(hits) == 1 else None

def router_units(status):

    out = []
    for app in (status.get("applications") or {}).values():
        if (app.get("charm") or app.get("charm-name")) != ROUTER_CHARM:
            continue
        out.extend((app.get("units") or {}).items())
    return out

def routers_settled(runner, args):

    status = runner.juju_json(["status", "-m", args.model])
    pending = []
    for unit_name, body in router_units(status):
        agent = (body.get("juju-status") or {}).get("current")
        wl = (body.get("workload-status") or {}).get("current")
        if agent != "idle" or wl not in SETTLED_WORKLOAD:
            pending.append("{}(agent={}, workload={})".format(unit_name, agent, wl))
    return sorted(pending)

def routers_transient(runner, args):

    status = runner.juju_json(["status", "-m", args.model])
    out = []
    for unit_name, body in router_units(status):
        agent = (body.get("juju-status") or {}).get("current")
        wl = (body.get("workload-status") or {}).get("current")
        if agent != "idle" or wl in TRANSIENT_WORKLOAD:
            out.append("{}(agent={}, workload={})".format(unit_name, agent, wl))
    return sorted(out)

def clone_grants(runner, user, src_host, dst_host, mysql_vmid):

    res = runner.mysql("SHOW GRANTS FOR {}@{}".format(
        quote_id(user), quote_id(src_host)), mysql_vmid)
    if res.returncode != 0:
        return None
    markers = [("`@`{}`".format(src_host), "`@`{}`".format(dst_host)),
               ("'@'{}'".format(src_host), "'@'{}'".format(dst_host))]
    stmts = []
    for line in res.stdout.splitlines():
        line = line.strip().rstrip(";").strip()
        if not line:
            continue
        for old, new in markers:
            line = line.replace(old, new)
        stmts.append(line + ";")
    return stmts or None

def pick_source_host(user, existing):

    hosts = sorted(h for u, h in existing if u == user)
    if not hosts:
        return None
    if "127.0.0.1" in hosts:
        return "127.0.0.1"
    for h in hosts:
        if h != "%":
            return h
    return hosts[0]

def assert_same_model(runner, leader, status_address):

    data = show_unit(runner, leader)
    unit_body = data.get(leader) or {}
    got = unit_body.get("public-address")
    if got != status_address:
        die("show-unit and status point at different models: the public-address of {} "
            "show-unit={!r} / status={!r}. Check that the juju client's current model "
            "(juju switch) and the -m argument.".format(leader, got, status_address))

def machine_of(units, unit):
    machine = units[unit].get("machine")
    if machine is None:
        die("cannot determine the machine of {}".format(unit))
    return int(machine)

def vmid_of(machine_vmids, machine, unit):
    if not (0 <= machine < len(machine_vmids)):
        die("{}: machine {} is outside the {} entries of --machine-vmids".format(
            unit, machine, len(machine_vmids)))
    return machine_vmids[machine]

def detect_write_target(runner, args, leader, machine_vmids, status=None):

    if status is None:
        status = runner.juju_json(["status", "-m", args.model])
    units = ((status.get("applications") or {}).get(MYSQL_APP) or {}).get("units") or {}
    if not units:
        die("status has no unit for {}".format(MYSQL_APP))

    unit = primary_from_status(units)
    how = "{} from workload-status".format(RW_MARKER)
    if not unit:
        unit = primary_from_action(runner, units, leader)
        how = "defaultReplicaSet.primary from the cluster-status action"
    if not unit:
        print("RECONCILE-INFO warning: neither path identified an R/W primary, falling back to juju leader {}"
              "(if it happens to be an R/O replica, assert_writable below will stop it)".format(leader))
        unit = leader
        how = "juju leader (fallback)"

    machine = machine_of(units, unit)
    vmid = vmid_of(machine_vmids, machine, unit)
    print("RECONCILE-INFO write target {} machine={} CT={} (detected from {})".format(
        unit, machine, vmid, how))
    return unit, vmid

def main():
    parser = argparse.ArgumentParser(description="Fill in the mysql-innodb-cluster user entries that were skipped because the service unit shares a machine with the MySQL leader.")
    parser.add_argument("--client-ct", type=int, required=True,
                        help="vmid of the Juju client CT")
    parser.add_argument("--client-user", required=True, help="Juju client user name")
    parser.add_argument("--juju-bin", required=True, help="path to the juju executable")
    parser.add_argument("--juju-data", required=True, help="JUJU_DATA directory")
    parser.add_argument("--model", required=True, help="<controller>:<model>")
    parser.add_argument("--machine-vmids", required=True,
                        help="Juju machine number -> vmid mapping, comma separated, ascending by machine"
                             "(machine i corresponds to entry i, the order is the numbering, see group_vars "
                             " pve_openstack_workload_vmids)")
    parser.add_argument("--wait", type=int, default=300,
                        help="fallback timeout in seconds (default 300). The normal path is **event driven**:"
                             "the expected set stayed quiet for --quiet-rounds rounds and no mysql-router "
                             "is in a transitional state it stops at once (empty delta -> RECONCILE-OK, returns immediately;"
                             "delta not empty -> starts applying SQL at once). It really waits only while the request set keeps changing (the charm is still"
                             "handling relations); see the \"Waiting\" section at the top of the file")
    parser.add_argument("--interval", type=int, default=20,
                        help="poll interval in seconds (default 20)")
    parser.add_argument("--quiet-rounds", type=int, default=3,
                        help="how many consecutive polls the expected set must stay unchanged before the requests count as complete"
                             "(default 3; with --interval 20 that is a ~60s quiet window;"
                             "see the \"Integrity\" section at the top of the file)")
    parser.add_argument("--password-wait", type=int, default=180,
                        help="before filling in, wait for the charm to write back the password of every request that is **still missing one** "
                             "upper bound in seconds for <prefix>_password (default 180). Only kicks in when something really is missing;"
                             "see the notes on wait_for_published_passwords()")
    parser.add_argument("--mysql-retries", type=int, default=30,
                        help="retry budget of a single SQL statement on a **transient connection error** (2013/2002/2003/2006/1040/1053)"
                             "maximum attempts (default 30, a secondary cap; the main cap is --mysql-retry-timeout)")
    parser.add_argument("--mysql-retry-timeout", type=int, default=600,
                        help="total retry budget in seconds for transient connection errors (default 600). ★ The main cap is **time**, not"
                             "count: a single attempt measured up to ~25s on a loaded host, so a count alone runs out inside the rolling restart's"
                             "downtime window (measured on env-4 on 2026-10-18: it died 3 seconds early, see"
                             " the docstring of Runner.mysql)")
    parser.add_argument("--mysql-retry-delay", type=int, default=10,
                        help="retry interval in seconds for transient connection errors (default 10)")
    parser.add_argument("--dump-db", default="mysql",
                        help="database used when writing /root/.my.cnf (default: the mysql system schema)")
    args = parser.parse_args()

    runner = Runner(args)

    status = runner.juju_json(["status", "-m", args.model])
    app = status.get("applications", {}).get(MYSQL_APP)
    if not app:
        die("the model has no {} application".format(MYSQL_APP))
    units = app.get("units") or {}
    leaders = sorted(u for u, v in units.items() if v.get("leader"))
    if not leaders:
        die("{} has not elected a leader yet".format(MYSQL_APP))

    leader = leaders[0]
    machine_vmids = [int(x) for x in args.machine_vmids.split(",") if x.strip()]
    print("RECONCILE-INFO leader={} machine={}".format(leader, machine_of(units, leader)))

    assert_same_model(runner, leader, units[leader].get("public-address"))

    target_unit, mysql_vmid = detect_write_target(
        runner, args, leader, machine_vmids, status=status)

    ensure_root_access(runner, target_unit, mysql_vmid, args.dump_db)

    assert_writable(runner, target_unit, mysql_vmid)

    requests = expected_requests(runner, leader)
    if not requests:
        die("leader {} has no (user, host) in its db-router relation data,"
            "confirm the bundle is deployed and mysql-router is related".format(leader))
    expected = {(e["user"], e["host"]) for e in requests}
    print("RECONCILE-INFO expected {} grants".format(len(expected)))

    deadline = time.time() + args.wait
    stable = 0
    prev = None
    while True:
        requests = expected_requests(runner, leader)
        expected = {(e["user"], e["host"]) for e in requests}
        existing = existing_grants(runner, mysql_vmid)
        missing = sorted(expected - existing)
        transient = routers_transient(runner, args)
        stable = stable + 1 if expected == prev else 0
        if stable >= args.quiet_rounds and not transient:
            if not missing:
                print("RECONCILE-OK all {} grants are present (the charm built them itself;"
                      "the request set has been quiet for {}s)".format(len(expected),
                                                args.quiet_rounds * args.interval))
                return 0
            print("RECONCILE-INFO the request set has been quiet for {}s and no router is transitional, yet {} are still missing"
                  " -> filling in right away (without waiting out --wait)".format(args.quiet_rounds * args.interval,
                                                    len(missing)))
            break
        prev = expected
        if time.time() >= deadline:
            break
        time.sleep(args.interval)

    print("RECONCILE-INFO after waiting {}s: {} expected, {} missing{}".format(
        args.wait, len(expected), len(missing),
        ("(" + ", ".join("{}@{}".format(u, h) for u, h in missing) + ")")
        if missing else ""))
    pending = routers_settled(runner, args)
    if pending:
        print("RECONCILE-INFO mysql-router units still not settled: {}".format(", ".join(pending)))

    if super_read_only(runner, mysql_vmid) != "0":
        print("RECONCILE-INFO write target {} (CT {}) is no longer the R/W primary, re-detecting".format(
            target_unit, mysql_vmid))
        target_unit, mysql_vmid = detect_write_target(
            runner, args, leader, machine_vmids)
        ensure_root_access(runner, target_unit, mysql_vmid, args.dump_db)
        assert_writable(runner, target_unit, mysql_vmid)

    requests = expected_requests(runner, leader)
    expected = {(e["user"], e["host"]) for e in requests}
    existing = existing_grants(runner, mysql_vmid)
    missing = sorted(expected - existing)

    wait_for_published_passwords(runner, requests, missing, args.password_wait,
                                 args.interval)

    created, skipped = [], []
    for user, host in missing:
        entry = next((e for e in requests
                      if e["user"] == user and e["host"] == host), None)
        password = password_for(runner, requests, user, host)
        if not password:
            skipped.append((user, host, "the charm has not written {}_password back yet (relation not settled)"
                            .format(entry["prefix"] if entry else "?")))
            continue
        src = pick_source_host(user, existing)
        grants = clone_grants(runner, user, src, host, mysql_vmid) if src else None
        if src and not grants:
            skipped.append((user, host, "cannot read the GRANT definition from clone source {}".format(src)))
            continue

        stmts = ["CREATE USER {}@{} IDENTIFIED BY {};".format(
            quote_id(user), quote_id(host), quote_lit(password))]
        stmts += grants or []
        res = runner.mysql(" ".join(stmts), mysql_vmid)
        if res.returncode != 0:
            tail = res.stderr.strip().splitlines()
            skipped.append((user, host, tail[-1] if tail else "execution failed"))
            continue
        created.append((user, host, src))
        print("RECONCILE-CREATED {}@{} (password from charm, grants cloned from {})"
              .format(user, host, src or "(none)"))

    for user, host, why in skipped:
        print("RECONCILE-SKIPPED {}@{}: {}".format(user, host, why))

    final = existing_grants(runner, mysql_vmid)
    still_missing = sorted(expected - final)
    print("RECONCILE-SUMMARY created={} skipped={} missing={}".format(
        len(created), len(skipped), len(still_missing)))
    if still_missing:
        die("{} grants are still missing: {}".format(
            len(still_missing),
            ", ".join("{}@{}".format(u, h) for u, h in still_missing)))
    return 0

if __name__ == "__main__":
    sys.exit(main())
