#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

echo "== inventory =="
ansible-inventory --graph || fail=1

echo "== playbook syntax =="
while IFS= read -r pb; do
    if ! ansible-playbook "$pb" --syntax-check >/dev/null; then
        echo "FAIL $pb"
        fail=1
    fi
done < <(find playbooks -name '*.yml' -not -path 'playbooks/openstack/envs/*' | sort)

echo "== openstack env overrides =="
for env in playbooks/openstack/envs/env*.yml; do
    if ! ansible-playbook playbooks/openstack/site.yml -e "@$env" --syntax-check >/dev/null; then
        echo "FAIL openstack/site.yml with $env"
        fail=1
    fi
done

echo "== shell scripts =="
while IFS= read -r sh; do
    bash -n "$sh" || { echo "FAIL $sh"; fail=1; }
done < <(find scripts -name '*.sh' | sort)

echo "== python =="
python3 -m py_compile scripts/*/*.py || fail=1

echo "== unit tests =="
python3 -m unittest discover -s tests -q || fail=1

if [ "$fail" -ne 0 ]; then
    echo "SYNTAX-CHECK failed"
    exit 1
fi
echo "SYNTAX-CHECK ok"