#!/bin/bash
set -euo pipefail

block_file="${1:?usage: hosts-sync.sh <block-file>}"
hosts=/etc/hosts

[ -r "$block_file" ] || { echo "ERROR: cannot read $block_file" >&2; exit 1; }

sed -i '/# --- yoga static name resolution/,/# --- end yoga static name resolution/d' "$hosts"

sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' "$hosts" || true

cat "$block_file" >> "$hosts"

echo "installed $(grep -c 'yoga static name resolution' "$hosts" || true) marker(s) into $hosts"
