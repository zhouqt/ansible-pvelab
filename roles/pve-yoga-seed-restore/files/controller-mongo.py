#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import time

AGENT_CONF = "/var/lib/juju/agents/machine-0/agent.conf"
MONGO = "/snap/bin/juju-db.mongo"
SNAP_COMMON = "/var/snap/juju-db/common"
CA_PEM = "/var/lib/juju/ca.crt"
SERVER_PEM = "/var/lib/juju/server.pem"

CLIENT_PEM = SNAP_COMMON + "/seed-restore-client.pem"
CLIENT_CA = SNAP_COMMON + "/seed-restore-client-ca.crt"

PROBE_JS = """
var out = {};
out.users = db.getSiblingDB("juju").users.find(
    {_id: "admin"}, {passwordhash: 1, passwordsalt: 1}).toArray();
out.models = db.getSiblingDB("juju").models.find(
    {}, {name: 1, owner: 1, type: 1, life: 1}).toArray();
out.machines = db.getSiblingDB("juju").machines.count();
print(JSON.stringify(out));
"""

SET_ADMIN_JS = """
var r = db.getSiblingDB("juju").users.updateOne(
    {_id: "admin"}, {$set: {passwordhash: "%(hash)s", passwordsalt: "%(salt)s"}});
print(JSON.stringify({matched: r.matchedCount, modified: r.modifiedCount}));
"""

def read_agent_conf():

    import yaml

    with open(AGENT_CONF) as fh:
        return yaml.safe_load(fh)

def prepare_certs():
    for src, dst in ((SERVER_PEM, CLIENT_PEM), (CA_PEM, CLIENT_CA)):
        shutil.copyfile(src, dst)
        os.chmod(dst, stat.S_IRUSR | stat.S_IWUSR)

def mongo_eval(expr, password):
    cmd = [
        MONGO, "--quiet",
        "--host", "127.0.0.1", "--port", "37017",
        "--tls", "--tlsAllowInvalidHostnames",
        "--tlsCertificateKeyFile", CLIENT_PEM,
        "--tlsCAFile", CLIENT_CA,
        "-u", "machine-0", "-p", password,
        "--authenticationDatabase", "admin",
        "--eval", expr,
    ]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120)

def connect_with_retry(password, timeout):

    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            res = mongo_eval("print('PING-OK')", password)
        except subprocess.TimeoutExpired:
            last = "mongo client timed out"
            time.sleep(5)
            continue
        if res.returncode == 0 and "PING-OK" in res.stdout:
            return
        lines = (res.stderr or res.stdout).strip().splitlines()
        last = lines[-1] if lines else ""
        time.sleep(5)
    raise SystemExit(
        "MONGO-UNREACHABLE: mongod on 127.0.0.1:37017 did not answer within "
        "%ss (last error: %s)" % (timeout, last)
    )

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--action", required=True, choices=["probe", "set-admin"])
    ap.add_argument("--hash", default="")
    ap.add_argument("--salt", default="")
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()

    agent = read_agent_conf()
    prepare_certs()
    connect_with_retry(agent["statepassword"], args.timeout)

    if args.action == "set-admin":
        expr = SET_ADMIN_JS % {"hash": args.hash, "salt": args.salt}
        res = mongo_eval(expr, agent["statepassword"])
        if res.returncode != 0:
            raise SystemExit("SET-ADMIN-FAIL: " + (res.stderr or res.stdout))
        print("SET-ADMIN-OK " + res.stdout.strip())
        return

    res = mongo_eval(PROBE_JS, agent["statepassword"])
    if res.returncode != 0:
        raise SystemExit("PROBE-FAIL: " + (res.stderr or res.stdout))
    raw = res.stdout.strip().splitlines()[-1]
    state = json.loads(raw)

    controller = (agent.get("controller") or "").split("-", 1)
    out = {
        "uuid": controller[1] if len(controller) == 2 else "",
        "ca_cert": agent.get("cacert", ""),
        "api_addresses": list(agent.get("apiaddresses") or []),
        "agent_version": agent.get("upgradedToVersion", ""),
        "machine_count": state.get("machines", 0),

        "models": [
            {"name": "%s/%s" % (m.get("owner", "admin"), m.get("name", "")),
             "uuid": m["_id"], "type": m.get("type", "iaas")}
            for m in state.get("models", [])
            if m.get("life", 0) in (0, None) and m.get("name")
        ],
        "admin": {
            "passwordhash": (state.get("users") or [{}])[0].get("passwordhash", ""),
            "passwordsalt": (state.get("users") or [{}])[0].get("passwordsalt", ""),
        },
    }
    print(json.dumps(out))

if __name__ == "__main__":
    main()
