#!/bin/bash
# simnovus-fronthaul.sh - O-RAN 7.2 fronthaul interfaces for the Simnovus UE simulator.
#
# On the host (hypervisor or bare-metal UE simulator):
#   curl -fsSL https://github.com/Simnovus-Corp/simnovus-fronthaul/releases/latest/download/simnovus-fronthaul.sh \
#     | sudo bash -s -- --if <fronthaul port> --vlan <VLAN> [--vm <VM name>]
# Inside the VM (no input needed):
#   curl -fsSL https://github.com/Simnovus-Corp/simnovus-fronthaul/releases/latest/download/simnovus-fronthaul.sh | sudo bash
#
# Run with --help for all options.
set -euo pipefail
VERSION=0.1.1
MAC_PREFIX=02:53:4e            # locally administered; "SN"
CONF_DIR=/etc/simnovus
APPLY=/usr/local/sbin/simnovus-fronthaul-apply
UNIT_DIR=/etc/systemd/system
FH_MTU=9000

usage() { cat <<'EOF'
Simnovus fronthaul setup (O-RAN 7.2), version @VERSION@

On the host: creates one SR-IOV VF per cell on the fronthaul port, with a fixed MAC and the
fronthaul VLAN (the NIC adds and removes the VLAN tag), keeps them across reboots, and can give
them to a VM. Inside the VM: sets up the VF interfaces it received. Prints what to enter in the
test case and on the O-DU.

Host:
  sudo bash simnovus-fronthaul.sh --if <port> --vlan <id[,id...]> [options]
    --if <port>        the host's fronthaul port (physical NIC port cabled to the O-DU), e.g. ens1f0
    --vlan <ids>       fronthaul VLAN per cell, e.g. 2 or 2,3 (one VLAN for all cells is fine)
    --cells <n>        number of cells (VFs); default: number of VLANs given
    --vm <name>        give the VFs to this VM (libvirt); takes effect at the VM's next start
    --mac <macs>       VF MACs, comma separated; default: generated from the port's MAC (stable)
    --first-vf <k>     use VFs k, k+1, ... on the port (default 0)
    --pf-mtu <n>       MTU for the port (default 9000; 0 = leave it)

Inside the VM (or bare metal, to tune existing VF interfaces):
  sudo bash simnovus-fronthaul.sh                finds the VFs set up by this tool on the host
  sudo bash simnovus-fronthaul.sh --if <nic>     or name them (comma separated)

Both:
  --check              report only, change nothing
  --remove             undo (boot service and settings; VFs only if this tool created them)
  --version, --help
EOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
note() { echo "  ..    $*"; }

IFS_ARG= VLANS= CELLS= VM= MACS= FIRST=0 CHECK=0 REMOVE=0 PFMTU=$FH_MTU
while [ $# -gt 0 ]; do
    case "$1" in
        --if|--pf)   [ $# -ge 2 ] || die "$1 needs a value"; IFS_ARG="$2"; shift 2 ;;
        --vlan)      [ $# -ge 2 ] || die "$1 needs a value"; VLANS="$2"; shift 2 ;;
        --cells)     [ $# -ge 2 ] || die "$1 needs a value"; CELLS="$2"; shift 2 ;;
        --vm)        [ $# -ge 2 ] || die "$1 needs a value"; VM="$2"; shift 2 ;;
        --mac)       [ $# -ge 2 ] || die "$1 needs a value"; MACS="$2"; shift 2 ;;
        --first-vf)  [ $# -ge 2 ] || die "$1 needs a value"; FIRST="$2"; shift 2 ;;
        --pf-mtu)    [ $# -ge 2 ] || die "$1 needs a value"; PFMTU="$2"; shift 2 ;;
        --check)     CHECK=1; shift ;;
        --remove)    REMOVE=1; shift ;;
        --version)   echo "$VERSION"; exit 0 ;;
        -h|--help)   usage | sed "s/@VERSION@/$VERSION/"; exit 0 ;;
        *)           die "unknown option $1 (see --help)" ;;
    esac
done
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
isnum "$FIRST"  || die "--first-vf must be a number"
isnum "$PFMTU"  || die "--pf-mtu must be a number"
[ -z "$CELLS" ] || isnum "$CELLS" || die "--cells must be a number"

# ---------------------------------------------------------------- the boot-time helper
# One helper does the work now and at every boot, so both behave the same.
write_apply() {
    mkdir -p "$(dirname "$APPLY")"
    cat > "$APPLY" <<'APPLY_EOF'
#!/bin/bash
# simnovus-fronthaul-apply <conf> - written by simnovus-fronthaul.sh; run at boot by simnovus-fronthaul@.service
set -u
CONF="$1"; [ -r "$CONF" ] || { echo "no $CONF"; exit 1; }
. "$CONF"
rc=0
tune() {   # $1 = interface: MTU, bigger rings, no interrupt coalescing (less fronthaul jitter)
    local n="$1" i
    for i in $(seq 1 40); do [ -e "/sys/class/net/$n" ] && break; sleep 0.5; done
    [ -e "/sys/class/net/$n" ] || { echo "$n: not found"; rc=1; return; }
    ip link set "$n" mtu "$FH_MTU" up || rc=1
    if command -v ethtool >/dev/null; then
        ethtool -G "$n" rx 4096 tx 4096 >/dev/null 2>&1 || true
        ethtool -C "$n" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 >/dev/null 2>&1 || true
    fi
    # a ring change resets the VF; give the link a few seconds to come back
    for i in $(seq 1 20); do [ "$(cat /sys/class/net/$n/operstate)" = up ] && break; sleep 0.5; done
    st=$(cat /sys/class/net/$n/operstate); [ "$st" = up ] && st="link up" || st="NO LINK (check the cable or the host port)"
    echo "$n: mtu $(cat /sys/class/net/$n/mtu), $st"
}
if [ "$MODE" = host ]; then
    for i in $(seq 1 60); do [ -e "/sys/class/net/$PF/device/sriov_numvfs" ] && break; sleep 1; done
    NV=/sys/class/net/$PF/device/sriov_numvfs
    [ -e "$NV" ] || { echo "$PF: no SR-IOV"; exit 1; }
    if [ "$PFMTU" -gt 0 ] && [ "$(cat /sys/class/net/$PF/mtu)" -lt "$PFMTU" ]; then ip link set "$PF" mtu "$PFMTU"; fi
    ip link set "$PF" up
    cur=$(cat "$NV")
    if [ "$cur" -lt "$NUMVFS" ]; then
        if [ "$cur" -eq 0 ]; then echo "$NUMVFS" > "$NV"; sleep 2
        else echo "$PF has $cur VFs, $NUMVFS needed; not touching VFs that may be in use"; exit 1; fi
    fi
    for v in $VFS; do   # idx,mac,vlan
        IFS=, read -r idx mac vlan <<< "$v"
        ip link set "$PF" vf "$idx" mac "$mac" vlan "$vlan" spoofchk off trust on || rc=1
        echo "$PF vf $idx: mac $mac vlan $vlan"
        if [ "$TARGET" = host ]; then
            for i in $(seq 1 20); do ls "/sys/class/net/$PF/device/virtfn$idx/net" >/dev/null 2>&1 && break; sleep 0.5; done
            n=$(ls "/sys/class/net/$PF/device/virtfn$idx/net" 2>/dev/null | head -1)
            [ -n "$n" ] && tune "$n" || { echo "vf $idx: no host interface"; rc=1; }
        fi
    done
else
    for n in $NICS; do tune "$n"; done
fi
exit $rc
APPLY_EOF
    chmod 755 "$APPLY"
}

write_unit() {
    cat > "$UNIT_DIR/simnovus-fronthaul@.service" <<'EOF'
[Unit]
Description=Simnovus O-RAN 7.2 fronthaul (%i)
After=network-pre.target systemd-udev-settle.service
Before=network.target libvirtd.service virtqemud.service simnovus-ptp4l@%i.service ptp4l.service ptp4l@%i.service lte.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/simnovus-fronthaul-apply /etc/simnovus/fronthaul-%i.conf

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# Keep NetworkManager away from the fronthaul interfaces (it would reset MTU or try DHCP on them).
nm_unmanage() {   # $1 = name for the file, rest = interfaces
    local tag="$1"; shift
    [ -d /etc/NetworkManager ] || return 0
    mkdir -p /etc/NetworkManager/conf.d
    local list="" n
    for n in "$@"; do list="${list:+$list;}interface-name:$n"; done
    printf '[keyfile]\nunmanaged-devices=%s\n' "$list" > "/etc/NetworkManager/conf.d/90-simnovus-fronthaul-$tag.conf"
    systemctl is-active -q NetworkManager && systemctl reload NetworkManager || true
}

remove_instance() {   # $1 = instance name
    local inst="$1" conf="$CONF_DIR/fronthaul-$1.conf"
    [ -e "$conf" ] || die "nothing to remove for $inst (no $conf)"
    # shellcheck disable=SC1090
    . "$conf"
    systemctl disable "simnovus-fronthaul@$inst.service" >/dev/null 2>&1 || true
    rm -f "/etc/NetworkManager/conf.d/90-simnovus-fronthaul-$inst.conf"
    systemctl is-active -q NetworkManager && systemctl reload NetworkManager || true
    if [ "${MODE:-}" = host ] && [ "${CREATED:-0}" = 1 ]; then
        echo 0 > "/sys/class/net/$PF/device/sriov_numvfs" && ok "removed the VFs on $PF"
    elif [ "${MODE:-}" = host ]; then
        note "the VFs on $PF existed before this tool; left in place (MAC/VLAN settings stay until reboot)"
    fi
    if [ -n "${VM:-}" ]; then
        note "the VM '$VM' still lists the VFs as host devices; remove them in virt-manager or with 'virsh detach-device'"
    fi
    rm -f "$conf"
    if ! ls "$CONF_DIR"/fronthaul-*.conf >/dev/null 2>&1; then
        rm -f "$APPLY" "$UNIT_DIR/simnovus-fronthaul@.service"
        rmdir "$CONF_DIR" 2>/dev/null || true
    fi
    systemctl daemon-reload
    ok "removed fronthaul setup $inst"
}

echo "Simnovus fronthaul setup $VERSION"

# ---------------------------------------------------------------- guest / interface mode
VIRT=$(systemd-detect-virt 2>/dev/null || true)
if [ -z "$VLANS" ]; then
    if [ $REMOVE = 1 ]; then
        # host undo is "--if <port> --remove"; inside the VM it's just "--remove"
        if [ -n "$IFS_ARG" ] && [ -e "$CONF_DIR/fronthaul-$IFS_ARG.conf" ]; then remove_instance "$IFS_ARG"
        else remove_instance guest; fi
        exit 0
    fi
    if [ -n "$IFS_ARG" ]; then
        NICS=$(echo "$IFS_ARG" | tr ',' ' ')
        for n in $NICS; do [ -e "/sys/class/net/$n" ] || die "no interface $n"; done
    else
        NICS=""
        for d in /sys/class/net/*; do
            n=$(basename "$d")
            case "$(cat "$d/address" 2>/dev/null)" in $MAC_PREFIX:*) NICS="$NICS $n" ;; esac
        done
        NICS=$(echo $NICS)
        if [ -z "$NICS" ]; then
            [ "$VIRT" = none ] && die "on the host, give --if <fronthaul port> --vlan <VLAN> (see --help)"
            die "no fronthaul VF found in this VM (MAC $MAC_PREFIX:...). Check the VF is attached to the VM, or name it: --if <nic>"
        fi
    fi
    DEF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    for n in $NICS; do [ "$n" != "$DEF" ] || die "$n carries the default route (management), not fronthaul"; done
    echo "Fronthaul interfaces: $NICS  (${VIRT:-unknown} environment)"
    for n in $NICS; do
        drv=$(basename "$(readlink "/sys/class/net/$n/device/driver" 2>/dev/null)" 2>/dev/null || true)
        note "$n: mac $(cat /sys/class/net/$n/address), driver ${drv:-?}, mtu $(cat /sys/class/net/$n/mtu)"
    done
    command -v ethtool >/dev/null || warn "ethtool not installed; ring/coalescing tuning will be skipped (apt-get install ethtool)"
    if [ $CHECK = 1 ]; then echo "Check only: nothing changed."; exit 0; fi
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/fronthaul-guest.conf" <<EOF
# written by simnovus-fronthaul.sh $VERSION on $(date -u +%FT%TZ)
MODE=guest
FH_MTU=$FH_MTU
NICS="$NICS"
EOF
    write_apply; write_unit
    nm_unmanage guest $NICS
    systemctl enable "simnovus-fronthaul@guest.service" >/dev/null 2>&1
    systemctl restart "simnovus-fronthaul@guest.service" || die "setup failed: journalctl -u simnovus-fronthaul@guest"
    journalctl -u simnovus-fronthaul@guest.service -n 20 --no-pager -o cat 2>/dev/null | grep -E ': mtu ' | tail -n "$(echo $NICS | wc -w)" | sed 's/^/  OK    /' || true
    echo
    echo "Done. In the test case: Radio Type O-RAN 7.2, and per cell:"
    i=1; for n in $NICS; do echo "    cell $i: Bind Interface $n"; i=$((i + 1)); done
    echo "No VLAN interface is needed: the host's NIC adds and removes the VLAN tag."
    exit 0
fi

# ---------------------------------------------------------------- host mode
PF="$IFS_ARG"
[ -n "$PF" ] || die "give the fronthaul port: --if <port>"
if [ $REMOVE = 1 ]; then remove_instance "$PF"; exit 0; fi
[ -e "/sys/class/net/$PF" ] || die "no interface $PF. Ports on this host: $(ls /sys/class/net | grep -vE '^(lo|virbr|vnet|docker|veth|br-)' | tr '\n' ' ')"
DEF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ "$PF" != "$DEF" ] || die "$PF carries the default route (management). Give the fronthaul port"
[ -e "/sys/class/net/$PF/device/physfn" ] && die "$PF is itself a VF; give the physical port"
NV="/sys/class/net/$PF/device/sriov_numvfs"
[ -e "$NV" ] || die "$PF has no SR-IOV. Enable SR-IOV in the BIOS (and NIC firmware), or use an SR-IOV capable NIC"
TOTAL=$(cat "/sys/class/net/$PF/device/sriov_totalvfs")
[ "$TOTAL" -gt 0 ] || die "$PF reports 0 possible VFs. Enable SR-IOV in the BIOS"
DRV=$(basename "$(readlink "/sys/class/net/$PF/device/driver")")
PFMAC=$(cat "/sys/class/net/$PF/address")

VLIST=$(echo "$VLANS" | tr ',' ' ')
for v in $VLIST; do isnum "$v" && [ "$v" -ge 1 ] && [ "$v" -le 4094 ] || die "VLAN must be 1-4094 (got $v)"; done
NVL=$(echo $VLIST | wc -w)
[ -n "$CELLS" ] || CELLS=$NVL
[ "$CELLS" -ge 1 ] || die "--cells must be at least 1"
[ "$NVL" = 1 ] || [ "$NVL" = "$CELLS" ] || die "give one VLAN, or one per cell ($CELLS)"
if [ -n "$MACS" ]; then
    MLIST=$(echo "$MACS" | tr ',' ' ' | tr 'A-F' 'a-f')
    [ "$(echo $MLIST | wc -w)" = "$CELLS" ] || die "give one MAC per cell ($CELLS)"
    for m in $MLIST; do echo "$m" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || die "bad MAC $m"; done
fi
NEED=$((FIRST + CELLS))
[ "$NEED" -le "$TOTAL" ] || die "$PF supports $TOTAL VFs; VFs $FIRST..$((NEED-1)) asked"
CUR=$(cat "$NV")
CREATED=0
if [ "$CUR" = 0 ]; then NUMVFS=$NEED; CREATED=1
elif [ "$CUR" -ge "$NEED" ]; then NUMVFS=$CUR
else die "$PF already has $CUR VFs (maybe in use), $NEED needed. This tool won't recreate them. Use --first-vf within 0..$((CUR-1)), or free the port"
fi
[ -e "$CONF_DIR/fronthaul-$PF.conf" ] && CREATED=$(. "$CONF_DIR/fronthaul-$PF.conf"; echo "${CREATED:-0}")

if [ -n "$VM" ]; then
    command -v virsh >/dev/null || die "--vm needs libvirt (virsh)"
    virsh dominfo "$VM" >/dev/null 2>&1 || die "no VM named '$VM' (virsh list --all)"
    [ -n "$(ls /sys/kernel/iommu_groups 2>/dev/null)" ] || die "IOMMU is off. Turn on VT-d in the BIOS and add 'intel_iommu=on iommu=pt' to GRUB_CMDLINE_LINUX in /etc/default/grub, run update-grub, reboot"
    TARGET=vm
else
    TARGET=host
fi

echo "Port $PF ($DRV, $PFMAC): SR-IOV up to $TOTAL VFs, $CUR now"
VFS="" PLAN=""
i=0
for k in $(seq "$FIRST" $((NEED - 1))); do
    if [ "$NVL" = 1 ]; then vlan=$VLIST; else vlan=$(echo $VLIST | cut -d' ' -f$((i + 1))); fi
    if [ -n "$MACS" ]; then mac=$(echo $MLIST | cut -d' ' -f$((i + 1)))
    else mac=$(printf '%s:%s:%s:%02x' $MAC_PREFIX "$(echo "$PFMAC" | cut -d: -f5)" "$(echo "$PFMAC" | cut -d: -f6)" "$k"); fi
    VFS="$VFS $k,$mac,$vlan"
    pci=""
    if [ "$k" -lt "$CUR" ]; then
        pci=$(basename "$(readlink "/sys/class/net/$PF/device/virtfn$k")")
        vdrv=$(basename "$(readlink "/sys/bus/pci/devices/$pci/driver" 2>/dev/null)" 2>/dev/null || true)
        if [ "$TARGET" = host ] && [ -z "$(ls "/sys/bus/pci/devices/$pci/net" 2>/dev/null)" ]; then
            die "VF $k ($pci) is held by ${vdrv:-no driver} (a VM or container?). Pick free VFs with --first-vf"
        fi
        if command -v virsh >/dev/null; then
            b=$(echo "$pci" | cut -d: -f2); s=$(echo "$pci" | cut -d: -f3 | cut -d. -f1); f=${pci##*.}
            for d in $(virsh list --all --name 2>/dev/null); do
                [ "$d" = "$VM" ] && continue
                virsh dumpxml --inactive "$d" 2>/dev/null | grep -qiE "bus=.0x$b. slot=.0x$s. function=.0x$f." || continue
                if [ "$(virsh domstate "$d" 2>/dev/null)" = running ]; then
                    die "VF $k ($pci) is in use by the running VM '$d'. Pick free VFs with --first-vf"
                fi
                warn "VF $k ($pci) is also listed in VM '$d' (shut off): only one of the two VMs can run at a time"
            done
        fi
    fi
    PLAN="$PLAN
    cell $((i + 1)): VF $k ${pci:+($pci) }MAC $mac VLAN $vlan"
    i=$((i + 1))
done
VFS=$(echo $VFS)
echo "Plan:$PLAN"
[ "$CREATED" = 1 ] && [ "$CUR" = 0 ] && note "will create $NUMVFS VF(s) on $PF"
[ "$PFMTU" -gt 0 ] && [ "$(cat /sys/class/net/$PF/mtu)" -lt "$PFMTU" ] && note "will set $PF MTU to $PFMTU"
ptp_on_pf() {   # ptp4l names its port on the command line (-i) or as [port] in its config file (-f)
    local pid args f
    for pid in $(pgrep -x ptp4l 2>/dev/null); do
        args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        echo " $args " | grep -qE -- "-i $PF |--interface[= ]$PF " && return 0
        f=$(echo " $args " | sed -nE 's/.* -f ([^ ]+) .*/\1/p')
        [ -n "$f" ] && grep -qE "^\[$PF\]" "$f" 2>/dev/null && return 0
    done
    return 1
}
if ptp_on_pf; then
    if [ "$CUR" = 0 ] || { [ "$PFMTU" -gt 0 ] && [ "$(cat /sys/class/net/$PF/mtu)" -lt "$PFMTU" ]; }; then
        warn "ptp4l runs on $PF: creating VFs or changing the MTU can reset the link, so PTP re-locks (about a minute)"
    fi
fi
[ "$TARGET" = vm ] && note "the VF(s) go to VM '$VM' (at its next start)"
if [ $CHECK = 1 ]; then echo "Check only: nothing changed."; exit 0; fi

mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/fronthaul-$PF.conf" <<EOF
# written by simnovus-fronthaul.sh $VERSION on $(date -u +%FT%TZ)
MODE=host
PF=$PF
PFMTU=$PFMTU
FH_MTU=$FH_MTU
NUMVFS=$NUMVFS
CREATED=$CREATED
TARGET=$TARGET
VM="$VM"
VFS="$VFS"
EOF
write_apply; write_unit
systemctl enable "simnovus-fronthaul@$PF.service" >/dev/null 2>&1
echo "Applying (also at every boot, before PTP and the VMs start):"
systemctl restart "simnovus-fronthaul@$PF.service" || die "setup failed: journalctl -u simnovus-fronthaul@$PF"
journalctl -u "simnovus-fronthaul@$PF.service" -n 20 --no-pager -o cat 2>/dev/null | grep -E "^($PF vf|[a-z0-9]+: mtu)" | sed 's/^/  /' || true

HOSTNICS=""
for v in $VFS; do
    IFS=, read -r k mac vlan <<< "$v"
    pci=$(basename "$(readlink "/sys/class/net/$PF/device/virtfn$k")")
    if [ "$TARGET" = vm ]; then
        b=$(echo "$pci" | cut -d: -f2); s=$(echo "$pci" | cut -d: -f3 | cut -d. -f1); f=${pci##*.}; dom=$(echo "$pci" | cut -d: -f1)
        if virsh dumpxml --inactive "$VM" | grep -qiE "bus=.0x$b. slot=.0x$s. function=.0x$f."; then
            ok "VF $k ($pci) already given to '$VM'"
        else
            x=$(mktemp)
            printf "<hostdev mode='subsystem' type='pci' managed='yes'><source><address domain='0x%s' bus='0x%s' slot='0x%s' function='0x%s'/></source></hostdev>\n" "$dom" "$b" "$s" "$f" > "$x"
            virsh attach-device "$VM" "$x" --config >/dev/null && ok "VF $k ($pci) given to '$VM'" || warn "could not give VF $k to '$VM'"
            rm -f "$x"
        fi
    else
        HOSTNICS="$HOSTNICS $(ls "/sys/class/net/$PF/device/virtfn$k/net" 2>/dev/null | head -1)"
    fi
done
[ -n "$HOSTNICS" ] && nm_unmanage "$PF" $HOSTNICS

echo
echo "Done. Give these to the O-DU (RU side of each cell):"
i=1; for v in $VFS; do IFS=, read -r k mac vlan <<< "$v"; echo "    cell $i: RU MAC $mac, VLAN $vlan"; i=$((i + 1)); done
if [ "$TARGET" = vm ]; then
    if [ "$(virsh domstate "$VM" 2>/dev/null)" = running ]; then echo "Restart the VM '$VM' (shut down, then start) to give it the VF(s)."; fi
    echo "Then inside the VM run this tool again with no options; it finds and sets up the fronthaul interfaces."
else
    echo "In the test case: Radio Type O-RAN 7.2, Bind Interface =$(echo $HOSTNICS | sed 's/^/ /')  (no VLAN interface: the NIC tags the VLAN)."
fi
