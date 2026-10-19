#!/usr/bin/env bash
set -euo pipefail

TARGET=/usr/local/sbin/pve-trim-guests.sh
UNIT=/etc/systemd/system/pve-trim-guests.service
TIMER=/etc/systemd/system/pve-trim-guests.timer
SCHEDULE="${TRIM_SCHEDULE:-Sun *-*-* 04:17:00}"
DELAY="${TRIM_DELAY:-30m}"

die()  { printf 'error:%s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

need_root() { [ "$(id -u)" -eq 0 ] || die "root is required (run as root on the PVE host)"; }
need_pve()  { command -v pct >/dev/null 2>&1 || die "pct not found -- this does not look like a PVE host"; }

emit_target() {
cat <<'PVE_TRIM_GUESTS_SCRIPT_EOF'
#!/usr/bin/env bash
set -uo pipefail

TIMEOUT="${TRIM_TIMEOUT:-300}"
INCLUDE_STOPPED="${TRIM_INCLUDE_STOPPED:-0}"
DRY_RUN="${TRIM_DRY_RUN:-0}"
QUIET="${TRIM_QUIET:-1}"

LVM_WARNINGS=""

GUEST_NICE=(nice -n 19)
command -v ionice >/dev/null 2>&1 && GUEST_NICE+=(ionice -c3)

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

pool_data_bytes() {
    local total=0 n
    while IFS= read -r n; do
        [ -n "$n" ] && total=$(( total + n * 65536 ))
    done < <(dmsetup status 2>/dev/null | awk '$4 == "thin-pool" { split($7, a, "/"); print a[1] }')
    printf '%s' "$total"
}

gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b / 1073741824 }'; }

trim_ct() {
    local vmid="$1" name="$2" out rc trimmed errs other

    if [ "$DRY_RUN" = 1 ]; then
        log "ct/$vmid ($name): DRY-RUN -- would run: pct fstrim $vmid"
        return 0
    fi

    out=$(timeout "$TIMEOUT" "${GUEST_NICE[@]}" pct fstrim "$vmid" 2>&1)
    rc=$?

    if [ "$rc" -eq 124 ]; then
        log "ct/$vmid ($name): TIMEOUT -- not finished after ${TIMEOUT}s, giving up on this one"
        return 0
    fi

    trimmed=$(printf '%s\n' "$out" | grep 'trimmed' | grep -v '0 B (0 bytes)' \
              | sed -e "s#^/var/lib/lxc/$vmid/rootfs#<rootfs>#" -e "s#^<rootfs>/:#<rootfs>:#")
    errs=$(printf '%s\n' "$out" | grep -iE 'fstrim:.*(failed|error|permitted|not supported)' || true)

    lvm_warn=$(printf '%s\n' "$out" | grep -oE 'WARNING: Thin volume [^;]*' \
               | sed -E 's/maps [0-9]+/maps N/' | sort -u || true)
    [ -n "$lvm_warn" ] && LVM_WARNINGS="${LVM_WARNINGS}${lvm_warn}"$'\n'

    other=$(printf '%s\n' "$out" | grep -viE 'trimmed|fstrim:|WARNING: Thin volume' || true)

    if [ -n "$trimmed" ]; then
        while IFS= read -r line; do log "ct/$vmid ($name): $line"; done <<< "$trimmed"
    elif [ "$QUIET" != 1 ]; then
        log "ct/$vmid ($name): OK -- nothing new to reclaim"
    fi

    [ -n "$errs" ]  && log "ct/$vmid ($name): FAIL — $(printf '%s' "$errs"  | tr '\n' '; ' | cut -c1-300)"
    [ -n "$other" ] && log "ct/$vmid ($name): WARN — $(printf '%s' "$other" | tr '\n' '; ' | cut -c1-300)"
    return 0
}

trim_qm() {
    local vmid="$1" name="$2" out rc ndiscard

    ndiscard=$(qm config "$vmid" 2>/dev/null \
               | grep -E '^(scsi|virtio|sata|ide)[0-9]+:' | grep -c 'discard=on' || true)
    if [ "${ndiscard:-0}" -eq 0 ]; then
        log "vm/$vmid ($name): SKIP -- the disk lacks discard=on, so trim never reaches the storage layer" \
            "(run qm set $vmid --scsi0 ...,discard=on first, then restart that VM)"
        return 0
    fi

    if ! timeout 15 qm agent "$vmid" ping >/dev/null 2>&1; then
        log "vm/$vmid ($name): SKIP -- no usable qemu-guest-agent"
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        log "vm/$vmid ($name): DRY-RUN -- would run: qm guest cmd $vmid fstrim"
        return 0
    fi

    out=$(timeout "$TIMEOUT" qm guest cmd "$vmid" fstrim 2>&1)
    rc=$?
    if [ "$rc" -eq 124 ]; then
        log "vm/$vmid ($name): TIMEOUT -- not finished after ${TIMEOUT}s, giving up on this one"
    elif [ "$rc" -ne 0 ]; then
        log "vm/$vmid ($name): FAIL (rc=$rc) — $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    else
        log "vm/$vmid ($name): OK — $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    fi
}

main() {
    command -v pct >/dev/null 2>&1 || { log "FATAL: pct not found, this script only runs on a PVE host"; exit 1; }

    local before after n_ct=0 n_vm=0
    before=$(pool_data_bytes); before="${before:-0}"

    log "===== start -- thin pool allocated data: $(gib "$before") GiB ====="

    while read -r vmid status name lock; do
        [ -n "${vmid:-}" ] || continue
        if [ "$lock" != "-" ]; then
            log "ct/$vmid ($name): SKIP -- locked ($lock)"
            continue
        fi
        trim_ct "$vmid" "$name"
        n_ct=$(( n_ct + 1 ))
    done < <(pct list | awk -v inc="$INCLUDE_STOPPED" \
                'NR>1 && (inc=="1" || $2=="running") { if (NF>=4) print $1, $2, $4, $3; else print $1, $2, $3, "-" }')

    if command -v qm >/dev/null 2>&1; then
        while read -r vmid name; do
            [ -n "${vmid:-}" ] || continue
            trim_qm "$vmid" "$name"
            n_vm=$(( n_vm + 1 ))
        done < <(qm list | awk 'NR>1 && $3=="running" { print $1, $2 }')
    fi

    after=$(pool_data_bytes); after="${after:-0}"
    local delta=$(( before - after )) delta_txt
    if [ "${delta#-}" -lt 8388608 ]; then
        delta_txt="pool usage essentially unchanged"
    elif [ "$delta" -gt 0 ]; then
        delta_txt="reclaimed $(gib "$delta") GiB this round"
    else
        delta_txt="pool grew by $(gib "$(( -delta ))") GiB (other writes outpaced this round's reclaim)"
    fi

    log "===== end -- thin pool allocated data: $(gib "$before") GiB -> $(gib "$after") GiB" \
        "(${delta_txt}); processed ${n_ct} containers and ${n_vm} KVM VMs ====="

    if printf '%s' "$LVM_WARNINGS" | grep -q '[^[:space:]]'; then
        log "note: the mappings of the thin volumes below disagree with their virtual size (unrelated to this trim, it is pre-existing pool state,"
        log "      printed every time pct fstrim activates a volume). The usual cause is that the volume was lvreduce'd/shrunk;"
        log "      pool blocks past the end of the volume are never reclaimed by fstrim; the only fix is to back up and rebuild the volume:"
        printf '%s\n' "$LVM_WARNINGS" | sort -u | grep . | while IFS= read -r line; do
            log "    $line"
        done
    fi
}

main "$@"
PVE_TRIM_GUESTS_SCRIPT_EOF
}

emit_unit() {
cat <<'PVE_TRIM_GUESTS_UNIT_EOF'
[Unit]
Description=Trim unused blocks on all PVE guest filesystems
Documentation=man:fstrim(8)
After=pve-guests.service
ConditionPathExists=/usr/local/sbin/pve-trim-guests.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-trim-guests.sh
Nice=19
IOSchedulingClass=idle
TimeoutStartSec=4h
PVE_TRIM_GUESTS_UNIT_EOF
}

emit_timer() {
cat <<PVE_TRIM_GUESTS_TIMER_EOF
[Unit]
Description=Periodic TRIM of all PVE guest filesystems

[Timer]
OnCalendar=${SCHEDULE}
RandomizedDelaySec=${DELAY}
AccuracySec=1m
Persistent=true
Unit=pve-trim-guests.service

[Install]
WantedBy=timers.target
PVE_TRIM_GUESTS_TIMER_EOF
}

do_install() {
    info "writing $TARGET"
    emit_target > "$TARGET"
    chmod 0755 "$TARGET"

    info "writing $UNIT"
    emit_unit > "$UNIT"

    info "writing $TIMER"
    emit_timer > "$TIMER"
    chmod 0644 "$UNIT" "$TIMER"

    systemctl daemon-reload
    info "enabling and starting pve-trim-guests.timer"
    systemctl enable --now pve-trim-guests.timer

    if ! systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
        echo
        echo "note: the host's own fstrim.timer is not enabled --"
        echo "      this script only covers guests; the host's own mounts (/, /boot/efi, bind-mounted LVs, ...) rely on it."
        echo "      consider also enabling:  systemctl enable --now fstrim.timer"
    fi

    echo
    info "done. next trigger time:"
    systemctl list-timers pve-trim-guests.timer --no-pager | sed -n '1,3p'
    echo
    echo "run one round by hand:  $TARGET"
    echo "logs:      journalctl -u pve-trim-guests.service -n 100 --no-pager"
}

do_run_now() {
    info "running one round now (foreground)"
    "$TARGET"
}

do_uninstall() {
    info "stopping and disabling the timer"
    systemctl disable --now pve-trim-guests.timer 2>/dev/null || true
    rm -f "$UNIT" "$TIMER" "$TARGET"
    systemctl daemon-reload
    systemctl reset-failed pve-trim-guests.service 2>/dev/null || true
    info "uninstalled (existing journal logs are not reclaimed)"
}

do_dry_run() {
    echo "########## will write $TARGET ##########"
    emit_target
    echo
    echo "########## will write $UNIT ##########"
    emit_unit
    echo
    echo "########## will write $TIMER ##########"
    emit_timer
    echo
    echo "(dry-run: nothing above was written)"
}

case "${1:-}" in
    "")            need_root; need_pve; do_install ;;
    --run-now)     need_root; need_pve; do_install; echo; do_run_now ;;
    --dry-run)     do_dry_run ;;
    --uninstall)   need_root; do_uninstall ;;
    -h|--help)     sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)             die "unknown argument: $1 (try --help)" ;;
esac
