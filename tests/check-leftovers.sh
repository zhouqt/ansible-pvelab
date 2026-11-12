#!/bin/bash
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0

check() {
    local label="$1" pattern="$2" exclude="${3:-}"
    local hits
    hits=$(grep -RIn --exclude-dir=.git --exclude-dir=__pycache__ \
        --exclude=check-leftovers.sh --exclude=migration-rename-map.md \
        -E -- "$pattern" . 2>/dev/null || true)
    if [ -n "$exclude" ] && [ -n "$hits" ]; then
        hits=$(printf '%s\n' "$hits" | grep -vE -- "$exclude" || true)
    fi
    if [ -n "$hits" ]; then
        echo "== $label"
        echo "$hits"
        fail=1
    fi
}

check "old variables" '\bpve_yoga_|\bpve_ussuri_|\bpve_obs_hub_|\bpve_lma_'

RUNTIME='admin-openrc-pve-|vault-ca-pve-|pve-(yoga|ussuri|caracal)-env[0-9]|pve-yoga-images|pve-ussuri-images|jammy-yoga-env3-osd|focal-ussuri-env6-osd|ansible-pve-ct-system-uuid'
check "old role names" 'pve-yoga-|pve-ussuri-|sunbeam-pve|pve-obs-hub|pve-ct-system-uuid' "$RUNTIME"

check "tags" '--tags (pve|openstack)|--skip-tags'

check "old paths" 'group_vars/all\.yml|(^|[^-])inventory\.yml|env/(yoga|ussuri)-'

check "playbook_dir" 'playbook_dir.*(pve/scripts|bundles|credentials)'

check "old docs" 'pve-yoga-|focal-ussuri-(k8s-plan|redeploy|savepoint|snapshot)|docs/pve-|docs/sunbeam-pve-' "$RUNTIME|feature/focal-ussuri-"

if [ "$fail" -ne 0 ]; then
    echo "LEFTOVER-CHECK failed"
    exit 1
fi
echo "LEFTOVER-CHECK ok"