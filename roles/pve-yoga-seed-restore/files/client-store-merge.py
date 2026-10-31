#!/usr/bin/env python3

import argparse
import json
import os
import stat
import sys
import tempfile

import yaml

def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise SystemExit("CLIENT-STORE-FAIL: %s is not a YAML mapping" % path)
    data.setdefault("controllers", {})
    if not isinstance(data["controllers"], dict):
        raise SystemExit("CLIENT-STORE-FAIL: %s has a malformed controllers block" % path)
    return data

def save(path, data, owner):

    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as fh:
            yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False,
                           allow_unicode=True, width=4096, indent=4)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
        if owner:
            import pwd
            pw = pwd.getpwnam(owner)
            os.chown(tmp, pw.pw_uid, pw.pw_gid)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("payload")
    ap.add_argument("data_dir")
    ap.add_argument("--owner", default="")
    args = ap.parse_args()

    with open(args.payload) as fh:
        p = json.load(fh)["controller"]

    name = p["name"]
    if not p.get("uuid") or not p.get("api_endpoints") or not p.get("ca_cert"):
        raise SystemExit("CLIENT-STORE-FAIL: payload is missing uuid/api-endpoints/ca-cert")

    controllers_path = os.path.join(args.data_dir, "controllers.yaml")
    controllers = load(controllers_path)
    controllers["controllers"][name] = {
        "uuid": p["uuid"],
        "api-endpoints": list(p["api_endpoints"]),
        "ca-cert": p["ca_cert"],
        "cloud": "manual",
        "type": "manual",
        "agent-version": p.get("agent_version") or "",
        "controller-machine-count": 1,
        "active-controller-machine-count": 1,
        "machine-count": int(p.get("machine_count") or 0),
    }
    save(controllers_path, controllers, args.owner)

    accounts_path = os.path.join(args.data_dir, "accounts.yaml")
    accounts = load(accounts_path)
    accounts["controllers"][name] = {
        "user": p.get("user") or "admin",
        "password": p["password"],
        "last-known-access": "superuser",
    }
    save(accounts_path, accounts, args.owner)

    models_path = os.path.join(args.data_dir, "models.yaml")
    models = load(models_path)
    entry = {
        "models": {
            m["name"]: {"uuid": m["uuid"], "type": m.get("type") or "iaas", "branch": ""}
            for m in p["models"]
        },
        "current-model": p.get("current_model") or "",
    }
    if not entry["models"]:
        raise SystemExit("CLIENT-STORE-FAIL: the controller reported no alive models")
    if entry["current-model"] not in entry["models"]:
        raise SystemExit(
            "CLIENT-STORE-FAIL: current model %r is not in %s"
            % (entry["current-model"], sorted(entry["models"]))
        )
    models["controllers"][name] = entry
    save(models_path, models, args.owner)

    print("CLIENT-STORE-OK %s models=%d machines=%d"
          % (name, len(entry["models"]), int(p.get("machine_count") or 0)))

if __name__ == "__main__":
    main()
