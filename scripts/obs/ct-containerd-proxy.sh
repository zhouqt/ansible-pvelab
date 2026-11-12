#!/bin/bash
set -euo pipefail

pct_bin=pct
vmid=
dropin=
apply=0

usage() {
    cat <<'EOF'
Usage:
  ct-containerd-proxy.sh --vmid <id> --dropin <file> [--pct <pct-binary>]
                         [--apply]

Without --apply the script only reports whether the drop-in would change.
Output (stdout, one line):
  NOOP                 the container already has this exact drop-in
  WOULD-CHANGE:<file>  differs, dry run
  CHANGED:containerd   installed, containerd restarted and active again
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vmid) vmid="${2:?--vmid needs a value}"; shift 2 ;;
        --dropin) dropin="${2:?--dropin needs a value}"; shift 2 ;;
        --pct) pct_bin="${2:?--pct needs a value}"; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$vmid" ] || { echo "--vmid is required" >&2; exit 2; }
[ -n "$dropin" ] || { echo "--dropin is required" >&2; exit 2; }
[ -r "$dropin" ] || { echo "drop-in is not readable: $dropin" >&2; exit 2; }

target=/etc/systemd/system/snap.k8s.containerd.service.d/10-proxy.conf
staged=/root/.ct-containerd-proxy.conf

"$pct_bin" push "$vmid" "$dropin" "$staged" --perms 0644

if "$pct_bin" exec "$vmid" -- bash -c "cmp -s $staged $target"; then
    echo "NOOP"
    exit 0
fi

if [ "$apply" -eq 0 ]; then
    echo "WOULD-CHANGE:$dropin"
    exit 0
fi

"$pct_bin" exec "$vmid" -- bash -c \
    "install -D -m 0644 $staged $target && systemctl daemon-reload && systemctl restart snap.k8s.containerd"

for _ in $(seq 1 30); do
    if "$pct_bin" exec "$vmid" -- systemctl is-active --quiet snap.k8s.containerd; then
        echo "CHANGED:containerd"
        exit 0
    fi
    sleep 2
done

echo "containerd did not come back after the proxy drop-in" >&2
exit 1