#!/bin/bash
set -euo pipefail

vmid=
hostname=
ip=
gateway=
template=
storage=
tags=
bridge0=
bridge1=
bridge2=
bridge3=
oam_ip=
internal_ip=
storage_ip=
openstack=0
uplink=0
uplink_interface=
uplink_bridge=
cores=2
memory=4096
swap=0
rootfs_size=16
apply=0

usage() {
    cat <<'EOF'
Usage:
  create-workload-ct.sh --vmid <id> --hostname <name> --ip <addr>
      --gateway <gw> --template <volume> --storage <storage> --tags <tags>
      --bridge0 <br>
      [--openstack --bridge1 <br> --bridge2 <br> --bridge3 <br>
       --oam-ip <addr> --internal-ip <addr> --storage-ip <addr>]
      [--uplink --uplink-interface <if> --uplink-bridge <br>]
      [--cores <n>] [--memory <MiB>] [--rootfs-size <GiB>] [--apply]

Dry run by default; --apply is required to create the container.
EOF
}

need() {
    [ -n "$2" ] || { echo "$1 is required" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vmid) vmid="${2:?--vmid needs a value}"; shift 2 ;;
        --hostname) hostname="${2:?--hostname needs a value}"; shift 2 ;;
        --ip) ip="${2:?--ip needs a value}"; shift 2 ;;
        --gateway) gateway="${2:?--gateway needs a value}"; shift 2 ;;
        --template) template="${2:?--template needs a value}"; shift 2 ;;
        --storage) storage="${2:?--storage needs a value}"; shift 2 ;;
        --tags) tags="${2:?--tags needs a value}"; shift 2 ;;
        --bridge0) bridge0="${2:?--bridge0 needs a value}"; shift 2 ;;
        --bridge1) bridge1="${2:?--bridge1 needs a value}"; shift 2 ;;
        --bridge2) bridge2="${2:?--bridge2 needs a value}"; shift 2 ;;
        --bridge3) bridge3="${2:?--bridge3 needs a value}"; shift 2 ;;
        --oam-ip) oam_ip="${2:?--oam-ip needs a value}"; shift 2 ;;
        --internal-ip) internal_ip="${2:?--internal-ip needs a value}"; shift 2 ;;
        --storage-ip) storage_ip="${2:?--storage-ip needs a value}"; shift 2 ;;
        --openstack) openstack=1; shift ;;
        --uplink) uplink=1; shift ;;
        --uplink-interface) uplink_interface="${2:?--uplink-interface needs a value}"; shift 2 ;;
        --uplink-bridge) uplink_bridge="${2:?--uplink-bridge needs a value}"; shift 2 ;;
        --cores) cores="${2:?--cores needs a value}"; shift 2 ;;
        --memory) memory="${2:?--memory needs a value}"; shift 2 ;;
        --rootfs-size) rootfs_size="${2:?--rootfs-size needs a value}"; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

need --vmid "$vmid"
need --hostname "$hostname"
need --ip "$ip"
need --gateway "$gateway"
need --template "$template"
need --storage "$storage"
need --tags "$tags"
need --bridge0 "$bridge0"
if [ "$openstack" -eq 1 ]; then
    need --bridge1 "$bridge1"
    need --bridge2 "$bridge2"
    need --bridge3 "$bridge3"
    need --oam-ip "$oam_ip"
    need --internal-ip "$internal_ip"
    need --storage-ip "$storage_ip"
fi
if [ "$uplink" -eq 1 ]; then
    [ "$openstack" -eq 1 ] || { echo "--uplink requires --openstack" >&2; exit 2; }
    need --uplink-interface "$uplink_interface"
    need --uplink-bridge "$uplink_bridge"
fi

if pct config "$vmid" >/dev/null 2>&1; then
    echo "EXISTS:$vmid"
    exit 0
fi

if [ "$apply" -eq 0 ]; then
    echo "WOULD-CREATE:$vmid"
    exit 0
fi

networks=(--net0 "name=eth0,bridge=$bridge0,ip=${ip}/24,gw=${gateway}")
if [ "$openstack" -eq 1 ]; then
    networks+=(
        --net1 "name=eth1,bridge=$bridge1,ip=$oam_ip/24"
        --net2 "name=eth2,bridge=$bridge2,ip=$internal_ip/24"
        --net3 "name=eth3,bridge=$bridge3,ip=$storage_ip/24"
    )
    if [ "$uplink" -eq 1 ]; then
        networks+=(--net4 "name=$uplink_interface,bridge=$uplink_bridge,ip=manual")
    fi
fi

log="/var/tmp/ctcreate-${vmid}.log"
if ! pct create "$vmid" "$template" \
    --hostname "$hostname" --ostype ubuntu --cores "$cores" --memory "$memory" \
    --swap "$swap" --rootfs "$storage:$rootfs_size" --unprivileged 0 \
    --features nesting=1,fuse=1 \
    "${networks[@]}" \
    --nameserver 8.8.8.8 "$tags" --onboot 1 --startup 'order=3' --start 0 \
    >"$log" 2>&1; then
    echo "create failed; last lines of $log:" >&2
    tail -20 "$log" >&2
    exit 1
fi

echo "CREATED:$vmid"