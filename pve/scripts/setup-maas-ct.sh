#!/usr/bin/env bash

set -euo pipefail

VMID="${VMID:-1000}"
HOSTNAME="${HOSTNAME:-maas-controller}"
TEMPLATE="${TEMPLATE:-local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"

CORES="${CORES:-8}"
MEMORY="${MEMORY:-16384}"
SWAP="${SWAP:-8192}"
ROOTFS_SIZE="${ROOTFS_SIZE:-32}"
DATA_SIZE="${DATA_SIZE:-64}"

PUB_BRIDGE="${PUB_BRIDGE:-pub11}"
PUB_IP="${PUB_IP:-192.168.11.3}"
PUB_CIDR="${PUB_CIDR:-192.168.11.0/24}"
PUB_GW="${PUB_GW:-192.168.11.1}"
DYNAMIC_START="${DYNAMIC_START:-192.168.11.230}"
DYNAMIC_END="${DYNAMIC_END:-192.168.11.254}"
RESERVED_START="${RESERVED_START:-192.168.11.2}"
RESERVED_END="${RESERVED_END:-192.168.11.99}"
DHCP_START="${DHCP_START:-$DYNAMIC_START}"
DHCP_END="${DHCP_END:-$DYNAMIC_END}"

ZONES="${ZONES:-AZ1 AZ2 AZ3}"

APT_MIRROR="${APT_MIRROR:-cn.archive.ubuntu.com}"

HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-$HTTP_PROXY}"
NO_PROXY="${NO_PROXY:-}"

LP_SSH_KEY_USERS="${LP_SSH_KEY_USERS:-zhouqt}"

SPACES=(
  "pub11:192.168.11.0/24:public"
  "pub12:192.168.12.0/24:oam"
  "int13:192.168.13.0/24:internal"
  "int14:192.168.14.0/24:storage"
)

OTHER_NETS=(
  "pub12:192.168.12.3/24"
  "int13:192.168.13.3/24"
  "int14:192.168.14.3/24"
)

MAAS_URL="${MAAS_URL:-http://${PUB_IP}:5240/MAAS}"
API_BASE="${MAAS_URL}/api/2.0"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
MAAS_CHANNEL="${MAAS_CHANNEL:-3.6/stable}"
BOOT_SOURCE_ID="${BOOT_SOURCE_ID:-1}"
RELEASES="${RELEASES:-focal jammy}"

SSH_PUBKEY="${SSH_PUBKEY:-}"
CT_ROOT_PASSWORD="${CT_ROOT_PASSWORD:-}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

ct() { pct exec "$VMID" -- "$@"; }
ct_bash() { pct exec "$VMID" -- bash -lc "$1"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (pct requires it)"
command -v pct >/dev/null || die "pct not found, this script must run on the PVE host"

CONF="/etc/pve/lxc/${VMID}.conf"

log "1/11 creating container ${VMID} (${HOSTNAME})"

if pct status "$VMID" >/dev/null 2>&1; then
  info "container ${VMID} already exists, skipping creation"
else
  [ -e "$CONF" ] && die "${CONF} exists but ${VMID} is not a known container, clean it up first"

  if ! pveam list local 2>/dev/null | grep -q "$(basename "${TEMPLATE}" .tar.zst)"; then
    info "downloading template ${TEMPLATE}"
    pveam update >/dev/null
    pveam download "$(basename "${TEMPLATE}" .tar.zst)" >/dev/null
  fi

  set -- pct create "$VMID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --arch amd64 \
    --ostype ubuntu \
    --unprivileged 0 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "pve-thin-pool:${ROOTFS_SIZE}" \
    --mp0 "pve-thin-pool:${DATA_SIZE},mp=/var/snap/maas/common/maas" \
    --net0 "name=eth0,bridge=${PUB_BRIDGE},ip=${PUB_IP}/24,gw=${PUB_GW},firewall=1" \
    --features nesting=1,fuse=1 \
    --onboot 1 \
    --start 0
  i=1
  for net in "${OTHER_NETS[@]}"; do
    set -- "$@" "--net${i}" "name=eth${i},bridge=${net%%:*},ip=${net#*:},type=veth"
    i=$((i + 1))
  done
  info "running: $*"
  "$@"
fi

log "2/11 LXC tuning (AppArmor / capabilities)"

python3 - "$CONF" <<'PYEOF'
import re, sys

path = sys.argv[1]
lines = open(path).read().splitlines()

want = [
    ("lxc.cap.drop", ""),
    ("lxc.cap.drop", "mac_override sys_time sys_module sys_rawio"),
]

lines = [l for l in lines if not re.match(r"^\s*lxc\.(apparmor\.profile|cap\.drop)\s*:", l)]
lines += ["%s: %s" % (k, v) for k, v in want]

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
print("    wrote %d lxc.* entries" % len(want))
PYEOF

grep -E '^lxc\.' "$CONF" | sed 's/^/    /' || true

log "3/11 starting the container"

pct start "$VMID" 2>/dev/null || true
info "waiting for systemd..."
for _ in $(seq 1 60); do
  if ct_bash 'systemctl is-system-running --wait >/dev/null 2>&1 || systemctl is-system-running | grep -qE "running|degraded"'; then
    break
  fi
  sleep 2
done
ct_bash 'systemctl is-active systemd-networkd' | grep -q active \
  || die "systemd-networkd is not up -- check that features: nesting=1 took effect"
info "networkd active"

log "4/11 switching apt to a local mirror (${APT_MIRROR:-unchanged})"

if [ -n "$HTTP_PROXY" ]; then
  ct_bash "install -d -m 0755 /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/90pve-proxy <<'PROXYEOF'
Acquire::http::Proxy \"${HTTP_PROXY}\";
Acquire::https::Proxy \"${HTTPS_PROXY}\";
PROXYEOF
cat > /etc/profile.d/90pve-proxy.sh <<'PROFILEEOF'
export http_proxy='${HTTP_PROXY}' https_proxy='${HTTPS_PROXY}'
export HTTP_PROXY='${HTTP_PROXY}' HTTPS_PROXY='${HTTPS_PROXY}'
export no_proxy='${NO_PROXY}' NO_PROXY='${NO_PROXY}'
PROFILEEOF
chmod 0644 /etc/apt/apt.conf.d/90pve-proxy /etc/profile.d/90pve-proxy.sh"
fi

if [ -n "$APT_MIRROR" ]; then
  ct_bash "cp -a /etc/apt/sources.list /etc/apt/sources.list.orig 2>/dev/null || true
sed -i \\
  -e 's|http://archive.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g' \\
  -e 's|http://security.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g' \\
  -e 's|http://ports.ubuntu.com/ubuntu-ports|http://cn.ports.ubuntu.com.cn/ubuntu-ports|g' \\
  /etc/apt/sources.list
grep -vE '^[[:space:]]*(#|\$)' /etc/apt/sources.list || true"
  info "sources.list switched to ${APT_MIRROR} (original kept as sources.list.orig)"
else
  info "skipping (APT_MIRROR is empty)"
fi

log "5/11 installing snapd and the MAAS snap"

ct_bash 'command -v snapd >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq snapd; }' >/dev/null
if [ -n "$HTTP_PROXY" ]; then
  ct snap set system "proxy.http=$HTTP_PROXY" "proxy.https=$HTTPS_PROXY"
fi
info "snapd: $(ct_bash 'snap version' | awk '$1=="snapd"{print $2}')"

ct_bash 'mkdir -p /run/udev
[ -S /run/udev/control ] || { setsid /lib/systemd/systemd-udevd --daemon >/var/log/udevd-manual.log 2>&1 & sleep 2; }
[ -S /run/udev/control ] || ls -l /run/udev/control' | sed 's/^/    /'

if ct_bash 'snap list snapd 2>/dev/null | awk "NR==2 {print \\$2}" | grep -q "^2.76.3"'; then
  ct_bash 'snap refresh --hold=forever snapd >/dev/null 2>&1 || true'
fi

ct_bash "snap install maas --channel=${MAAS_CHANNEL} && snap install maas-test-db --channel=3.7/stable" \
  | grep -E 'installed|up to date|error' | sed 's/^/    /' || true

if [ -n "$HTTP_PROXY" ]; then
  ct_bash "for service in regiond rackd; do
    dropin=/etc/systemd/system/snap.maas.\${service}.service.d/90-pve-proxy.conf
    install -d -m 0755 \"\$(dirname \"\$dropin\")\"
    cat >\"\$dropin\" <<'PROXY_UNIT'
[Service]
Environment=HTTP_PROXY=${HTTP_PROXY}
Environment=HTTPS_PROXY=${HTTPS_PROXY}
Environment=NO_PROXY=${NO_PROXY}
Environment=http_proxy=${HTTP_PROXY}
Environment=https_proxy=${HTTPS_PROXY}
Environment=no_proxy=${NO_PROXY}
PROXY_UNIT
  done
  systemctl daemon-reload"
fi

if [ "${REFRESH_SNAPD:-0}" = 1 ]; then
  ct_bash 'snap refresh snapd' | grep -E 'refreshed|up to date|error' | sed 's/^/    /' || true
else
  info "skipping snapd refresh (REFRESH_SNAPD!=1; avoids the PVE LXC snapfuse/snap-confine issues)"
fi
info "snap list: $(ct_bash 'snap list snapd' | tail -1)"
ct_bash 'snap list maas | tail -1' | sed 's/^/    /'
ct_bash '/snap/bin/maas --help >/dev/null 2>&1' || die "the maas CLI is not usable; check the snapd/snap-confine versions"

ns=$(ls /sys/kernel/security/apparmor/policy/namespaces/ 2>/dev/null | grep -c "^lxc-${VMID}_" || true)
if [ "${ns:-0}" -eq 0 ]; then
  info "warning: no lxc-${VMID}_* AppArmor namespace on the host; check whether the conf still carries lxc.apparmor.profile"
else
  info "AppArmor namespace: $(ls /sys/kernel/security/apparmor/policy/namespaces/ | grep "^lxc-${VMID}_" | tr '\n' ' ')"
fi

log "6/11 maas init region+rack"

if [ -n "${CT_ROOT_PASSWORD:-}" ]; then
  ct_bash "printf '%s\\n' 'root:${CT_ROOT_PASSWORD}' | chpasswd" >/dev/null
  info "container root password set"
fi

ct_bash 'mountpoint -q /var/snap/maas/common/maas' \
  || die "the big disk is not mounted on the snap data area, check --mp0"
info "$(ct_bash 'findmnt -no SOURCE /var/snap/maas/common/maas')"
info "$(ct_bash 'df -h /var/snap/maas/common/maas | tail -1')"

if ct_bash 'test -f /var/snap/maas/common/maas/maas_id' 2>/dev/null; then
  info "MAAS already initialised (maas_id present), skipping init"
else
  info "running init (Temporal migrations, takes a few minutes)..."
  ct_bash "/snap/bin/maas init region+rack --database-uri maas-test-db:/// --maas-url ${MAAS_URL}" \
    | tail -3 | sed 's/^/    /'
fi

info "waiting for services..."
SERVICES_OK=0
for _ in $(seq 1 90); do
  ST="$(ct_bash '/snap/bin/maas status 2>/dev/null' || true)"
  PENDING="$(printf '%s\n' "$ST" | awk 'NR>1 && $2=="enabled" && $3!="active"' | wc -l)"
  TOTAL="$(printf '%s\n' "$ST" | awk 'NR>1 && $2=="enabled"' | wc -l)"
  if [ "$TOTAL" -gt 0 ] && [ "$PENDING" -eq 0 ]; then
    SERVICES_OK=1
    break
  fi
  sleep 10
done
[ "$SERVICES_OK" -eq 1 ] || die "some services are not up, see the maas status above"
ct_bash '/snap/bin/maas status' | sed 's/^/    /'

info "waiting for the API (the apiserver behind nginx actually becomes ready)..."
API_OK=0
for _ in $(seq 1 60); do
  if ct_bash "python3 -c \"
import json, urllib.request
try:
    json.load(urllib.request.urlopen('${API_BASE}/version/', timeout=10))
except Exception:
    raise SystemExit(1)
\"" 2>/dev/null; then
    API_OK=1
    break
  fi
  sleep 5
done
[ "$API_OK" -eq 1 ] || die "API stayed unreachable (check the apiserver log)"
info "API ready: $(ct_bash "python3 -c \"
import json, urllib.request
print(json.load(urllib.request.urlopen('${API_BASE}/version/', timeout=10))['version'])
\"")"

log "7/11 administrator account and API key"

if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
  GENERATED_PASSWORD=1
fi

if ct_bash "/snap/bin/maas createadmin --username ${ADMIN_USER} --password '${ADMIN_PASSWORD}' --email ${ADMIN_EMAIL}" \
     | sed 's/^/    /'; then
  CREATED_ADMIN=1
else
  CREATED_ADMIN=0
  info "administrator already exists, skipping (a non-zero exit from createadmin means it exists)"
  GENERATED_PASSWORD=""
fi

if ct_bash 'test -f /root/.maas-api-key' 2>/dev/null; then
  info "/root/.maas-api-key already exists, reusing it"
else
  ct_bash "/snap/bin/maas apikey --username ${ADMIN_USER} --generate | tr -d '\n' > /root/.maas-api-key && chmod 600 /root/.maas-api-key"
  info "generated /root/.maas-api-key"
fi

APIKEY="$(ct_bash 'cat /root/.maas-api-key')"
[ -n "$APIKEY" ] || die "cannot obtain an API key"

ct_bash "/snap/bin/maas login local '${MAAS_URL}' '${APIKEY}' >/dev/null" || true
info "CLI profile local is ready"

log "8/11 deploying the API helper (OAuth 1.0 PLAINTEXT) + importing SSH keys"

ct_bash 'cat > /usr/local/bin/maas-api <<"PYEOF"
#!/usr/bin/env python3
"""MAAS 3.6 API client (OAuth 1.0 PLAINTEXT, not Bearer).

usage: maas-api <METHOD> <path> [k=v ...]
"""
import os, sys, time, urllib.parse, urllib.request, urllib.error

BASE = os.environ.get("MAAS_API_BASE", "http://127.0.0.1:5240/MAAS/api/2.0/")
BASE = BASE if BASE.endswith("/") else BASE + "/"
KEY = open("/root/.maas-api-key").read().strip()

def auth_header(key):
    ck, token, secret = key.split(":")
    return (
        '"'"'OAuth oauth_nonce="{n}", oauth_timestamp="{t}", oauth_version="1.0", '"'"'
        '"'"'oauth_signature_method="PLAINTEXT", oauth_consumer_key="{ck}", '"'"'
        '"'"'oauth_token="{tk}", oauth_signature="&{s}"'"'"'
    ).format(n=int(time.time() * 1e9), t=int(time.time()), ck=ck, tk=token, s=secret)

method, path = sys.argv[1].upper(), sys.argv[2].lstrip("/")
params = dict(a.split("=", 1) for a in sys.argv[3:])
path, _, path_qs = path.partition("?")
qs = "&".join(p for p in (path_qs, urllib.parse.urlencode(params)) if p)
url = urllib.parse.urljoin(BASE, path) + (("?" + qs) if qs else "")
data = qs.encode() if (qs and method != "GET") else None
req = urllib.request.Request(url, data=data, method=method)
req.add_header("Authorization", auth_header(KEY))
req.add_header("Content-Type", "application/x-www-form-urlencoded")
try:
    print(urllib.request.urlopen(req, timeout=120).read().decode())
except urllib.error.HTTPError as e:
    print("HTTP %d: %s" % (e.code, e.read().decode()[:2000]), file=sys.stderr)
    sys.exit(1)
PYEOF
chmod +x /usr/local/bin/maas-api' >/dev/null
info "wrote /usr/local/bin/maas-api"

api() {
  local _a _args=""
  for _a in "$@"; do _args+=" $(printf '%q' "$_a")"; done
  ct_bash "MAAS_API_BASE=${API_BASE}/ /usr/local/bin/maas-api${_args}"
}
info "API self-check: $(api GET version/)"

if [ -n "$SSH_PUBKEY" ]; then
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if api POST account/prefs/sshkeys/ "key=${key}" >/dev/null 2>&1; then
      info "imported SSH key: ${key%% *}"
    else
      info "import failed (it may already exist): ${key%% *}"
    fi
  done <<<"$(printf '%s\n' "$SSH_PUBKEY")"
fi

if [ -n "$LP_SSH_KEY_USERS" ]; then
  for lpuser in $LP_SSH_KEY_USERS; do
    if out="$(api POST 'account/prefs/sshkeys/?op=import' "keysource=lp:${lpuser}" 2>&1)"; then
      n="$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d = sys.stdin.read().strip()
    print(len(json.loads(d)) if d else 0)
except Exception:
    print(0)
')"
      info "Launchpad ${lpuser}: import returned ${n} keys (existing ones are skipped)"
    else
      info "importing ${lpuser} from Launchpad failed: $(printf '%s' "$out" | head -c 200)"
    fi
  done
  info "current key count: $(api GET account/prefs/sshkeys/ \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
fi

log "9/11 IP ranges, AZ, space layout and DHCP+PXE"

api() {
  local _a _args=""
  for _a in "$@"; do _args+=" $(printf '%q' "$_a")"; done
  ct_bash "MAAS_API_BASE=${API_BASE}/ /usr/local/bin/maas-api${_args}"
}

EXPECTED_CIDRS="${PUB_CIDR}"
for entry in "${SPACES[@]}"; do
  [ -n "$entry" ] || continue
  c="${entry#*:}"; EXPECTED_CIDRS="${EXPECTED_CIDRS} ${c%:*}"
done
EXPECTED_CIDRS="$(printf '%s\n' $EXPECTED_CIDRS | sort -u | tr '\n' ' ')"

info "waiting for rackd to discover the fabric/subnets (expected: ${EXPECTED_CIDRS})..."
NETS_OK=0
for _ in $(seq 1 60); do
  have="$(api GET subnets/ | python3 -c "
import json,sys
want = set('${EXPECTED_CIDRS}'.split())
have = {s['cidr'] for s in json.load(sys.stdin)}
print(' '.join(sorted(want & have)))
" 2>/dev/null || true)"
  if [ "$(wc -w <<<"$have")" -eq "$(wc -w <<<"$EXPECTED_CIDRS")" ]; then
    NETS_OK=1
    break
  fi
  sleep 10
done
if [ "$NETS_OK" -eq 1 ]; then
  info "all subnets discovered"
else
  info "not everything discovered within 10 minutes; discovered so far: ${have:-none}"
  info "(anything missing is probably just not up yet; keep going and look again if it errors)"
fi

SUBNET_ID="$(api GET subnets/ | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['cidr'] == '${PUB_CIDR}':
        print(s['id']); break
")"
[ -n "$SUBNET_ID" ] || die "no subnet ${PUB_CIDR} in MAAS -- is the NIC configured wrong?"
info "subnet ${PUB_CIDR} id=${SUBNET_ID}"

read -r VLAND_ID FABRIC_ID VID <<<"$(api GET "subnets/${SUBNET_ID}/" | python3 -c "
import json,sys
v = json.load(sys.stdin)['vlan']
print(v['id'], v['fabric_id'], v['vid'])
")"
info "→ vlan id=${VLAND_ID} fabric=${FABRIC_ID} vid=${VID}"

IPRANGE_ID="$(api GET ipranges/ | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    if r.get('type') == 'dynamic' and (r.get('subnet') or {}).get('id') == ${SUBNET_ID}:
        print(r['id']); break
")"
if [ -n "$IPRANGE_ID" ]; then
  api PUT "ipranges/${IPRANGE_ID}/" "start_ip=${DHCP_START}" "end_ip=${DHCP_END}" >/dev/null
  info "corrected iprange ${IPRANGE_ID} -> ${DHCP_START}-${DHCP_END}"
else
  api POST ipranges/ type=dynamic "subnet=${SUBNET_ID}" \
      "start_ip=${DHCP_START}" "end_ip=${DHCP_END}" >/dev/null
  info "created dynamic iprange ${DHCP_START}-${DHCP_END}"
fi

if [ -n "$RESERVED_START" ] && [ -n "$RESERVED_END" ]; then
  RID="$(api GET ipranges/ | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    if (r.get('type') == 'reserved'
            and (r.get('subnet') or {}).get('id') == ${SUBNET_ID}
            and r.get('start_ip') == '${RESERVED_START}'
            and r.get('end_ip') == '${RESERVED_END}'):
        print(r['id']); break
")"
  if [ -n "$RID" ]; then
    info "static reserved range ${RESERVED_START}-${RESERVED_END} already exists (id=${RID})"
  else
    api POST ipranges/ type=reserved "subnet=${SUBNET_ID}" \
        "start_ip=${RESERVED_START}" "end_ip=${RESERVED_END}" >/dev/null
    info "created static reserved range ${RESERVED_START}-${RESERVED_END}"
  fi
fi

if [ -n "$ZONES" ]; then
  EXISTING="$(api GET zones/ | python3 -c "
import json,sys
print(' '.join(z['name'] for z in json.load(sys.stdin)))
")"
  for z in $ZONES; do
    if printf '%s' " ${EXISTING} " | grep -q " ${z} "; then
      info "AZ ${z} already exists, skipping"
      continue
    fi
    api POST zones/ "name=${z}" >/dev/null
    info "created AZ ${z}"
  done
fi

for entry in "${SPACES[@]}"; do
  [ -n "$entry" ] || continue
  bridge="${entry%%:*}"
  rest="${entry#*:}"
  cidr="${rest%:*}"
  spname="${rest##*:}"

  sid="$(api GET subnets/ | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['cidr'] == '${cidr}':
        print(s['id']); break
")"
  if [ -z "$sid" ]; then
    info "skipping space ${spname}: no ${cidr} in MAAS (is bridge ${bridge} not connected?)"
    continue
  fi
  vlan_id="$(api GET "subnets/${sid}/" | python3 -c "
import json,sys
v = json.load(sys.stdin).get('vlan') or {}
print(v.get('id', ''))
")"
  if [ -z "$vlan_id" ]; then
    info "skipping space ${spname}: ${cidr} has no vlan"
    continue
  fi

  sp_id="$(api GET spaces/ | python3 -c "
import json,sys
for z in json.load(sys.stdin):
    if z['name'] == '${spname}' and z['id'] > 0:
        print(z['id']); break
")"
  if [ -z "$sp_id" ]; then
    sp_id="$(api POST spaces/ "name=${spname}" | python3 -c \
      'import json,sys; print(json.load(sys.stdin)["id"])')"
    info "created space ${spname} (id=${sp_id})"
  fi

  cur="$(api GET "vlans/${vlan_id}/" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("space") or "")')"
  if [ "$cur" = "$spname" ]; then
    info "space ${spname} already contains ${cidr} (vlan ${vlan_id})"
    continue
  fi
  api PUT "vlans/${vlan_id}/" "space=${sp_id}" >/dev/null
  info "${bridge} ${cidr} → space ${spname}(vlan ${vlan_id})"
done

api GET spaces/ | python3 -c "
import json,sys
for z in sorted(json.load(sys.stdin), key=lambda x: x['id']):
    print('    space %-10s id=%-3s vlans=%-14s subnets=%s' % (
        z['name'], z['id'],
        [v['id'] for v in z['vlans']],
        [s['cidr'] for s in z['subnets']]))
"

RACK_SYSID="$(api GET nodes/ | python3 -c "
import json,sys
n = json.load(sys.stdin)
print(n[0]['system_id'] if n else '')
")"
[ -n "$RACK_SYSID" ] || die "cannot obtain the rack controller system_id"
info "rack controller system_id=${RACK_SYSID}"

api PUT "vlans/${VLAND_ID}/" dhcp_on=1 "primary_rack=${RACK_SYSID}" >/dev/null
info "DHCP enabled on fabric-${FABRIC_ID}"

for net in "${OTHER_NETS[@]}"; do
  ip="${net#*:}"
  cidr="$(printf '%s\n' "${ip%.*}.0/${ip##*/}")"
  sid="$(api GET subnets/ | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['cidr'] == '${cidr}':
        print(s['id']); break
")"
  [ -n "$sid" ] || { info "skipping ${cidr} (not in MAAS)"; continue; }
  vid="$(api GET "subnets/${sid}/" | python3 -c "
import json,sys
v = json.load(sys.stdin).get('vlan')
print(v['id'] if v else '')
")"
  [ -n "$vid" ] || continue
  api PUT "vlans/${vid}/" dhcp_on=false >/dev/null
  info "DHCP disabled on ${cidr}"
done

ct_bash 'grep -c "^[[:space:]]*subnet " /var/snap/maas/common/maas/dhcpd.conf' \
  | sed 's/^/    subnet blocks in dhcpd.conf: /' || true
ct_bash 'grep -E "next-server|filename" /var/snap/maas/common/maas/dhcpd.conf | sort -u | head -4' \
  | sed 's/^/    /' || true

log "10/11 syncing Ubuntu images (${RELEASES:-default})"

ADDED=0
for rel in $RELEASES; do
  if api GET "boot-sources/${BOOT_SOURCE_ID}/selections/" \
      | python3 -c "
import json,sys
sys.exit(0 if any(s['release'] == '${rel}' for s in json.load(sys.stdin)) else 1)
"; then
    info "${rel} is already in the selection, skipping"
    continue
  fi
  info "adding selection ubuntu/${rel}"
  api POST "boot-sources/${BOOT_SOURCE_ID}/selections/" \
      os=ubuntu "release=${rel}" arches=amd64 'subarches=*' 'labels=*' >/dev/null
  ADDED=1
done

if [ "$ADDED" -eq 1 ]; then
  info "triggering the import (restart regiond -- the import service lives in regiond, not rackd)"
  ct_bash "PEBBLE=/var/snap/maas/common/pebble /snap/maas/current/bin/pebble restart regiond" | sed 's/^/    /'
  info "waiting for the API to recover from the 502 caused by the regiond restart..."
  API_BACK=0
  for _ in $(seq 1 30); do
    if api GET version/ >/dev/null 2>&1; then API_BACK=1; break; fi
    sleep 5
  done
  [ "$API_BACK" -eq 1 ] && info "API recovered" || info "!! API still unreachable, the next few steps may fail"
else
  info "selection unchanged, not restarting regiond (avoids interrupting downloads in flight)"
fi

info "waiting for the import to start (usually about 2 minutes)..."
for _ in $(seq 1 12); do
  if ct_bash 'grep -q "Started importing" /var/log/syslog 2>/dev/null'; then
    info "import started"
    break
  fi
  sleep 10
done
ct_bash 'grep -cE "Scheduling image download" /var/log/syslog 2>/dev/null' \
  | sed 's/^/    scheduled image downloads: /' || true

log "11/11 marking the guided setup as completed"

info "waiting for at least one image to finish syncing (the wizard's images step needs it)..."
IMG_OK=0
for _ in $(seq 1 60); do
  if api GET boot-resources/ 2>/dev/null | python3 -c "
import json,sys
sys.exit(0 if len(json.load(sys.stdin)) > 0 else 1)
"; then
    IMG_OK=1
    break
  fi
  sleep 10
done
if [ "$IMG_OK" -eq 1 ]; then
  info "existing images: $(api GET boot-resources/ 2>/dev/null | python3 -c '
import json,sys
print(len(json.load(sys.stdin)), "items")')"
else
  info "!! no image synced within 10 minutes; the images step will still show in the Web UI (it does not affect the other two steps)"
fi

api POST 'maas/?op=set_config' name=completed_intro value=true >/dev/null
info "maasserver_config.completed_intro = $(api GET 'maas/?op=get_config&name=completed_intro')"

PSQL="$(command -v psql || true)"
[ -n "$PSQL" ] || PSQL="$(ct_bash 'ls /snap/bin/maas-test-db.psql 2>/dev/null' || true)"
if [ -n "$PSQL" ]; then
  DB_NAME="$(ct_bash "${PSQL} -d postgres -tAc \"select datname from pg_database where datname not in ('postgres','template0','template1')\" 2>/dev/null" \
    | tr -d ' \r' | head -1)"
  if [ -n "$DB_NAME" ]; then
    ct_bash "${PSQL} -d ${DB_NAME} -tAc \"update maasserver_userprofile set completed_intro = true where user_id in (select id from auth_user where is_superuser)\"" >/dev/null
    ct_bash "${PSQL} -d ${DB_NAME} -tAc \"select u.username || ' -> ' || p.completed_intro from maasserver_userprofile p join auth_user u on u.id = p.user_id order by u.id\"" \
      | sed 's/^/    /'
  else
    info "!! MAAS database not found, skipping userprofile.completed_intro (fix it by hand)"
  fi
else
  info "!! psql not found, skipping userprofile.completed_intro (fix it by hand)"
fi

info "check: the Web UI should now go straight to the machine list and no longer redirect to /intro or /intro/user"

log "done"

if [ -n "${GENERATED_PASSWORD:-}" ]; then
  cat <<EOF

  admin password (randomly generated, shown only once):
      user      ${ADMIN_USER}
      password  ${ADMIN_PASSWORD}
      email     ${ADMIN_EMAIL}
EOF
fi

cat <<EOF

  container CT ${VMID} (${HOSTNAME})  ->  ssh root@${PUB_IP}
  Web UI    ${MAAS_URL}
  API       ${API_BASE}/
  API key   /root/.maas-api-key inside the container (chmod 600)
  mount     /var/snap/maas/common/maas  ->  $(ct_bash 'df -h /var/snap/maas/common/maas' | tail -1)
  apt source    ${APT_MIRROR:-unchanged}
  dynamic   ${DYNAMIC_START} - ${DYNAMIC_END} (handed out to machines)
  static    ${RESERVED_START} - ${RESERVED_END} (reserved; MAAS already built .1-.99 inside the subnet)
  AZ        ${ZONES:-none created}
  Space     $(for e in "${SPACES[@]}"; do printf "%s " "${e##*:}"; done)
  SSH keys  $(api GET account/prefs/sshkeys/ 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?') total
            (including Launchpad: ${LP_SSH_KEY_USERS:-none}${SSH_PUBKEY:+,plus the key passed via SSH_PUBKEY})
  onboarding  marked completed, the Web UI goes straight to the machine list

  check:
      pct exec ${VMID} -- /snap/bin/maas status
      pct exec ${VMID} -- grep -A3 'subnet ${PUB_CIDR%/*}' /var/snap/maas/common/maas/dhcpd.conf
      pct exec ${VMID} -- /usr/local/bin/maas-api GET zones/
      pct exec ${VMID} -- /usr/local/bin/maas-api GET ipranges/
EOF
