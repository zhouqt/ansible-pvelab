#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import time

DB_ROUTER_ENDPOINT = "db-router"
MYSQL_APP = "mysql-innodb-cluster"

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
        return self.pct(mysql_vmid, ["mysql", "--defaults-file=/root/.my.cnf",
                                     "-N", "-B", "-e", sql])

def relation_units(runner, unit, endpoint):

    data = runner.juju_json(["show-unit", unit])
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

def ensure_root_access(runner, leader, mysql_vmid, dump_db):

    if runner.pct(mysql_vmid, ["test", "-f", "/root/.my.cnf"]).returncode == 0:
        return
    print("RECONCILE-INFO wrote /root/.my.cnf (side effect of the charm mysqldump action)")

    runner.juju(["run", leader, "mysqldump", "databases=" + dump_db,
                 "--wait", "5m", "-m", runner.args.model], check=False)
    if runner.pct(mysql_vmid, ["test", "-f", "/root/.my.cnf"]).returncode != 0:
        die("the charm mysqldump action did not write /root/.my.cnf")

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
                             " pve_yoga_workload_vmids)")
    parser.add_argument("--wait", type=int, default=300,
                        help="seconds to wait for the charm to finish the db-router relation (default 300)")
    parser.add_argument("--interval", type=int, default=20,
                        help="poll interval in seconds (default 20)")
    parser.add_argument("--quiet-rounds", type=int, default=3,
                        help="how many consecutive polls the expected set must stay unchanged before the requests count as complete"
                             "(default 3; with --interval 20 that is a ~60s quiet window;"
                             "see the \"Integrity\" section at the top of the file)")
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
    machine = units[leader].get("machine")
    if machine is None:
        die("cannot determine the machine of {}".format(leader))
    machine_vmids = [int(x) for x in args.machine_vmids.split(",") if x.strip()]
    if not (0 <= int(machine) < len(machine_vmids)):
        die("machine {} is outside the {} entries of --machine-vmids".format(machine, len(machine_vmids)))
    mysql_vmid = machine_vmids[int(machine)]
    print("RECONCILE-INFO leader={} machine={} CT={}".format(leader, machine, mysql_vmid))

    requests = expected_requests(runner, leader)
    if not requests:
        die("leader {} has no (user, host) in its db-router relation data,"
            "confirm the bundle is deployed and mysql-router is related".format(leader))
    expected = {(e["user"], e["host"]) for e in requests}
    print("RECONCILE-INFO expected {} grants".format(len(expected)))

    ensure_root_access(runner, leader, mysql_vmid, args.dump_db)

    deadline = time.time() + args.wait
    stable = 0
    prev = None
    while True:
        requests = expected_requests(runner, leader)
        expected = {(e["user"], e["host"]) for e in requests}
        existing = existing_grants(runner, mysql_vmid)
        missing = sorted(expected - existing)
        if not missing:
            stable = stable + 1 if expected == prev else 0
            if stable >= args.quiet_rounds:
                print("RECONCILE-OK all {} grants are present (the charm built them itself;"
                      "the request set has been quiet for {}s)".format(
                          len(expected), args.quiet_rounds * args.interval))
                return 0
        else:
            stable = 0
        prev = expected
        if time.time() >= deadline:
            break
        time.sleep(args.interval)

    print("RECONCILE-INFO after waiting {}s: {} expected, {} missing{}".format(
        args.wait, len(expected), len(missing),
        ("(" + ", ".join("{}@{}".format(u, h) for u, h in missing) + ")")
        if missing else ""))

    requests = expected_requests(runner, leader)
    expected = {(e["user"], e["host"]) for e in requests}
    existing = existing_grants(runner, mysql_vmid)
    missing = sorted(expected - existing)

    created, skipped = [], []
    for user, host in missing:
        entry = next((e for e in requests
                      if e["user"] == user and e["host"] == host), None)
        password = (published_password(runner, entry["router"], entry["prefix"])
                    if entry else None)
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
