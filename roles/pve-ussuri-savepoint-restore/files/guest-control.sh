#!/bin/bash
set -uo pipefail

is_running() {
  local vmid=$1 kind=$2 out
  if [ "$kind" = "kvm" ]; then out=$(qm status "$vmid" 2>/dev/null); else out=$(pct status "$vmid" 2>/dev/null); fi
  printf '%s' "$out" | grep -q 'status: running'
}

stop_one() {
  local spec=$1
  local vmid=${spec%%:*} kind=${spec##*:}
  if ! is_running "$vmid" "$kind"; then echo "GUEST-SKIP $vmid already-stopped"; return 0; fi
  if [ "$kind" = "kvm" ]; then
    qm shutdown "$vmid" --timeout 60 >/dev/null 2>&1 || true
  else
    pct shutdown "$vmid" --timeout 60 >/dev/null 2>&1 || true
  fi
  if is_running "$vmid" "$kind"; then
    if [ "$kind" = "kvm" ]; then qm stop "$vmid" >/dev/null 2>&1 || true; else pct stop "$vmid" >/dev/null 2>&1 || true; fi
  fi
  if is_running "$vmid" "$kind"; then echo "GUEST-STOP-FAIL $vmid"; return 1; fi
  echo "GUEST-STOPPED $vmid"
}

start_one() {
  local spec=$1
  local vmid=${spec%%:*} kind=${spec##*:}
  if is_running "$vmid" "$kind"; then echo "GUEST-SKIP $vmid already-running"; return 0; fi
  if [ "$kind" = "kvm" ]; then qm start "$vmid" >/dev/null 2>&1; else pct start "$vmid" >/dev/null 2>&1; fi
  if ! is_running "$vmid" "$kind"; then echo "GUEST-START-FAIL $vmid"; return 1; fi
  echo "GUEST-STARTED $vmid"
}

case "${1:-}" in
  __stop_one)  shift; stop_one "$@"  ; exit $? ;;
  __start_one) shift; start_one "$@" ; exit $? ;;
esac

ACTION="${1:-}"
PAR="${2:-6}"
shift 2 2>/dev/null || shift $#

case "$ACTION" in
  stop|start)
    [ "$#" -gt 0 ] || { echo "guest-control: no guest list given" >&2; exit 2; }
    printf '%s\n' "$@" | xargs -r -P "$PAR" -n 1 bash "$0" "__${ACTION}_one"
    ;;
  *)
    echo "usage: $0 stop|start <parallel> <vmid:kind> ..." >&2
    exit 2
    ;;
esac