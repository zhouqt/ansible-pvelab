#!/bin/bash
set -euo pipefail

vmid=
name=
cores=
memory=
disk=
storage=
image=
image_url=
image_dir=/var/tmp
bridge0=
bridge1=
bridge2=
bridge3=
bridge4=
ciuser=
sshkeys=
ip0=
gw0=
ip1=
ip2=
ip3=
nameserver=
startup_order=
apply=0

usage() {
    cat <<'EOF'
Usage:
  create-kvm-workload.sh --vmid <id> --name <hostname> --cores <n>
      --memory <MiB> --disk <GiB> --storage <storage>
      --image <file> --image-url <url> [--image-dir <dir>]
      --bridge0 <br> --bridge1 <br> --bridge2 <br> --bridge3 <br>
      --bridge4 <br> --ciuser <user> --sshkeys <pubkey-file>
      --ip0 <cidr> --gw0 <gw> --ip1 <cidr> --ip2 <cidr> --ip3 <cidr>
      --nameserver <ip> --startup-order <n> [--apply]

Dry run by default; --apply is required to create the VM.
EOF
}

need() {
    [ -n "$2" ] || { echo "$1 is required" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vmid) vmid="${2:?--vmid needs a value}"; shift 2 ;;
        --name) name="${2:?--name needs a value}"; shift 2 ;;
        --cores) cores="${2:?--cores needs a value}"; shift 2 ;;
        --memory) memory="${2:?--memory needs a value}"; shift 2 ;;
        --disk) disk="${2:?--disk needs a value}"; shift 2 ;;
        --storage) storage="${2:?--storage needs a value}"; shift 2 ;;
        --image) image="${2:?--image needs a value}"; shift 2 ;;
        --image-url) image_url="${2:?--image-url needs a value}"; shift 2 ;;
        --image-dir) image_dir="${2:?--image-dir needs a value}"; shift 2 ;;
        --bridge0) bridge0="${2:?--bridge0 needs a value}"; shift 2 ;;
        --bridge1) bridge1="${2:?--bridge1 needs a value}"; shift 2 ;;
        --bridge2) bridge2="${2:?--bridge2 needs a value}"; shift 2 ;;
        --bridge3) bridge3="${2:?--bridge3 needs a value}"; shift 2 ;;
        --bridge4) bridge4="${2:?--bridge4 needs a value}"; shift 2 ;;
        --ciuser) ciuser="${2:?--ciuser needs a value}"; shift 2 ;;
        --sshkeys) sshkeys="${2:?--sshkeys needs a value}"; shift 2 ;;
        --ip0) ip0="${2:?--ip0 needs a value}"; shift 2 ;;
        --gw0) gw0="${2:?--gw0 needs a value}"; shift 2 ;;
        --ip1) ip1="${2:?--ip1 needs a value}"; shift 2 ;;
        --ip2) ip2="${2:?--ip2 needs a value}"; shift 2 ;;
        --ip3) ip3="${2:?--ip3 needs a value}"; shift 2 ;;
        --nameserver) nameserver="${2:?--nameserver needs a value}"; shift 2 ;;
        --startup-order) startup_order="${2:?--startup-order needs a value}"; shift 2 ;;
        --apply) apply=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

need --vmid "$vmid"
need --name "$name"
need --cores "$cores"
need --memory "$memory"
need --disk "$disk"
need --storage "$storage"
need --image "$image"
need --image-url "$image_url"
need --bridge0 "$bridge0"
need --bridge1 "$bridge1"
need --bridge2 "$bridge2"
need --bridge3 "$bridge3"
need --bridge4 "$bridge4"
need --ciuser "$ciuser"
need --sshkeys "$sshkeys"
need --ip0 "$ip0"
need --gw0 "$gw0"
need --ip1 "$ip1"
need --ip2 "$ip2"
need --ip3 "$ip3"
need --nameserver "$nameserver"
need --startup-order "$startup_order"
[ -r "$sshkeys" ] || { echo "public key is not readable: $sshkeys" >&2; exit 2; }

if pct status "$vmid" >/dev/null 2>&1; then
    echo "CONFLICT-CT:$vmid (an LXC container already uses this id)" >&2
    exit 2
fi

if qm status "$vmid" >/dev/null 2>&1; then
    echo "EXISTS:$vmid"
    exit 0
fi

if [ "$apply" -eq 0 ]; then
    echo "WOULD-CREATE:$vmid"
    exit 0
fi

mkdir -p "$image_dir"
cd "$image_dir"
if [ ! -s "$image" ]; then
    curl -fsSLo "$image" "$image_url" || {
        echo "cannot download cloud image: $image_url" >&2
        exit 3
    }
fi

qm create "$vmid" \
    --name "$name" \
    --ostype l26 --cores "$cores" \
    --memory "$memory" --balloon 0 \
    --cpu host --sockets 1 \
    --net0 "virtio,bridge=$bridge0,firewall=0" \
    --net1 "virtio,bridge=$bridge1,firewall=0" \
    --net2 "virtio,bridge=$bridge2,firewall=0" \
    --net3 "virtio,bridge=$bridge3,firewall=0" \
    --net4 "virtio,bridge=$bridge4,firewall=0" \
    --onboot 1 --startup "order=$startup_order" --agent 1 --serial0 socket --vga std

qm importdisk "$vmid" "$image" "$storage"
qm set "$vmid" --scsihw virtio-scsi-pci \
    --scsi0 "$storage:vm-$vmid-disk-0,iothread=1,discard=on"
qm resize "$vmid" scsi0 "${disk}G"
qm set "$vmid" --ide2 "$storage:cloudinit" --boot order=scsi0
qm set "$vmid" \
    --ciuser "$ciuser" --sshkeys "$sshkeys" \
    --ipconfig0 "ip=$ip0,gw=$gw0" \
    --ipconfig1 "ip=$ip1" \
    --ipconfig2 "ip=$ip2" \
    --ipconfig3 "ip=$ip3" \
    --nameserver "$nameserver"

echo "CREATED:$vmid"