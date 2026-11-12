#!/bin/bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
OPENRC_FILE="${OPENSTACK_RC_FILE:-${REPO_ROOT}/credentials/admin-openrc-pve-openstack.sh}"

if [ ! -r "$OPENRC_FILE" ]; then
    printf 'ERROR: OpenStack credentials file is missing or unreadable: %s\n' "$OPENRC_FILE" >&2
    exit 1
fi

source "$OPENRC_FILE" || exit 1

if [ $# -gt 0 ]; then
    exec "$@"
else
    echo "Usage: $0 <command>"
    echo "Example: $0 openstack flavor list"
fi
