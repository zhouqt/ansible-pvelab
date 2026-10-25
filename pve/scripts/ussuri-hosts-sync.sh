#!/bin/bash
set -euo pipefail

block_file="${1:?usage: ussuri-hosts-sync.sh <block-file>}"
hosts=/etc/hosts

[ -r "$block_file" ] || { echo "ERROR: cannot read $block_file" >&2; exit 1; }

sed -i '/# --- ussuri static name resolution/,/# --- end ussuri static name resolution/d' "$hosts"

sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' "$hosts" || true

cat "$block_file" >> "$hosts"

echo "installed $(grep -c 'ussuri static name resolution' "$hosts" || true) marker(s) into $hosts"
