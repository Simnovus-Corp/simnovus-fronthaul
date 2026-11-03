#!/bin/bash
# simnovus-s72tx-pin.sh - give the UE simulator's O-RAN 7.2 fronthaul TX thread(s) their own core(s).
#
# The UE simulator sends uplink fronthaul packets from one thread per fronthaul port ("lteue:s72-tx"). Nothing in the
# configuration places that thread, so it can share a core with the DL/UL processing and the uplink goes late
# (TX underflows: the "U" column of `t cpu`). This tool pins each such thread to a core you choose, at real-time
# priority, every time the UE simulator starts.
#
#   curl -fsSL https://github.com/Simnovus-Corp/simnovus-fronthaul/releases/latest/download/simnovus-s72tx-pin.sh \
#     | sudo bash -s -- --install --cpus 11
#
# Run --help for all options.
set -euo pipefail
VERSION=0.2.0
BIN=/usr/local/sbin/simnovus-s72tx-pin-run
CONF=/etc/simnovus/s72tx-pin.conf
UNIT=/etc/systemd/system/simnovus-s72tx-pin.service

usage() { cat <<EOF
Simnovus UE simulator: fronthaul TX thread pinning, version $VERSION

  sudo bash simnovus-s72tx-pin.sh --install --cpus <c>[,<c>...] [--prio <p>]
        install a service that pins each fronthaul TX thread (one per fronthaul port) to the given cores,
        in port order, at SCHED_FIFO priority <p> (default 55), every time the UE simulator starts.
        Pick cores inside the UE simulator's core list (lteue CPU cores) but outside its DL and UL cores.
  sudo bash simnovus-s72tx-pin.sh --status     show the TX threads now running and where they are
  sudo bash simnovus-s72tx-pin.sh --remove     remove the service
  sudo bash simnovus-s72tx-pin.sh --once --cpus <c>[,...]   pin the running UE simulator once, install nothing

Example for a 14-vCPU VM with lteue cores 1-13, DL 4-8, UL 9-10:  --install --cpus 11
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
MODE="" CPUS="" PRIO=55
while [ $# -gt 0 ]; do
    case "$1" in
        --install) MODE=install; shift ;;
        --remove)  MODE=remove; shift ;;
        --status)  MODE=status; shift ;;
        --once)    MODE=once; shift ;;
        --cpus)    [ $# -ge 2 ] || die "--cpus needs a value"; CPUS="$2"; shift 2 ;;
        --prio)    [ $# -ge 2 ] || die "--prio needs a value"; PRIO="$2"; shift 2 ;;
        --version) echo "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
done
[ -n "$MODE" ] || { usage; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"

# The pinning loop. Written to $BIN on --install; also used directly by --once.
read -r -d '' RUNNER <<'RUN_EOF' || true
#!/bin/bash
# simnovus-s72tx-pin-run: pin the UE simulator's fronthaul TX threads ("lteue:s72-tx") to fixed cores at SCHED_FIFO.
# Settings: S72TX_CPUS="11 12" (one per fronthaul port, in port order), S72TX_PRIO=55, S72TX_ONCE=1 to run once.
CPUS=(${S72TX_CPUS:?S72TX_CPUS not set}); PRIO=${S72TX_PRIO:-55}; done_pid=""
uepid() { pgrep -x lteue-avx2 | head -1 || true; }
pin() {   # $1 = pid; prints one line per thread; returns 0 if at least one thread was pinned
    local p=$1 k=0 t tid c
    for t in /proc/$p/task/*; do
        grep -q '^lteue:s72-tx' "$t/comm" 2>/dev/null || continue
        tid=${t##*/}; c=${CPUS[$k]:-${CPUS[0]}}; k=$((k + 1))
        if taskset -pc "$c" "$tid" >/dev/null 2>&1 && chrt -f -p "$PRIO" "$tid" 2>/dev/null; then
            echo "UE simulator pid $p: fronthaul TX thread $tid -> CPU $c, SCHED_FIFO $PRIO"
        else
            echo "UE simulator pid $p: could not pin TX thread $tid to CPU $c (is CPU $c in the VM?)"
        fi
    done
    [ $k -ge 1 ]
}
if [ "${S72TX_ONCE:-0}" = 1 ]; then
    p=$(uepid); [ -n "$p" ] || { echo "UE simulator is not running"; exit 1; }
    pin "$p" || { echo "no fronthaul TX thread found (is the test using O-RAN 7.2?)"; exit 1; }
    exit 0
fi
while true; do
    p=$(uepid)
    if [ -n "$p" ] && [ "$p" != "$done_pid" ]; then
        # the TX threads appear a few seconds after start; retry until they do
        pin "$p" && done_pid=$p
    fi
    [ -z "$p" ] && done_pid=""
    sleep 2
done
RUN_EOF

check_cpus() {
    [ -n "$CPUS" ] || die "give the cores: --cpus <c>[,<c>...]"
    case "$PRIO" in ''|*[!0-9]*) die "--prio must be a number" ;; esac
    [ "$PRIO" -ge 1 ] && [ "$PRIO" -le 98 ] || die "--prio must be 1-98"
    local n=$(nproc --all) c
    for c in $(echo "$CPUS" | tr ',' ' '); do
        case "$c" in ''|*[!0-9]*) die "core '$c' is not a number" ;; esac
        [ "$c" -lt "$n" ] || die "core $c does not exist (this machine has CPUs 0-$((n - 1)))"
        [ "$c" -ne 0 ] || echo "WARN: core 0 usually carries the OS and interrupts; a dedicated core is better"
    done
}

status() {
    local p t tid
    systemctl is-active -q simnovus-s72tx-pin 2>/dev/null && echo "service: active ($(grep -h '^S72TX' "$CONF" 2>/dev/null | tr '\n' ' '))" \
        || echo "service: not installed or not running"
    p=$(pgrep -x lteue-avx2 | head -1 || true)
    [ -n "$p" ] || { echo "UE simulator: not running"; return 0; }
    echo "UE simulator pid $p, allowed CPUs $(taskset -pc "$p" | awk -F': ' '{print $2}')"
    for t in /proc/$p/task/*; do
        grep -q '^lteue:s72-tx' "$t/comm" 2>/dev/null || continue
        tid=${t##*/}
        echo "  fronthaul TX thread $tid: CPUs $(taskset -pc "$tid" | awk -F': ' '{print $2}'), $(chrt -p "$tid" | awk -F': ' '{print $2}' | paste -sd' '), last ran on CPU $(awk '{print $39}' "$t/stat")"
    done
}

case "$MODE" in
    status) status ;;
    once)
        check_cpus
        S72TX_CPUS="$(echo "$CPUS" | tr ',' ' ')" S72TX_PRIO="$PRIO" S72TX_ONCE=1 bash -c "$RUNNER" ;;
    install)
        check_cpus
        command -v taskset >/dev/null && command -v chrt >/dev/null || die "needs taskset and chrt (util-linux)"
        mkdir -p "$(dirname "$BIN")" "$(dirname "$CONF")"
        printf '%s\n' "$RUNNER" > "$BIN"; chmod 755 "$BIN"
        printf 'S72TX_CPUS="%s"\nS72TX_PRIO=%s\n' "$(echo "$CPUS" | tr ',' ' ')" "$PRIO" > "$CONF"
        cat > "$UNIT" <<EOF
[Unit]
Description=Simnovus: pin the UE simulator's O-RAN 7.2 fronthaul TX threads (cores from $CONF)
After=lte.service

[Service]
EnvironmentFile=$CONF
ExecStart=$BIN
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now simnovus-s72tx-pin.service >/dev/null 2>&1
        systemctl restart simnovus-s72tx-pin.service
        echo "Installed: each fronthaul TX thread goes to CPU(s) $(echo "$CPUS" | tr ',' ' ') at SCHED_FIFO $PRIO whenever the UE simulator starts."
        echo "Check during a test: sudo bash simnovus-s72tx-pin.sh --status   (or: journalctl -u simnovus-s72tx-pin)"
        ;;
    remove)
        systemctl disable --now simnovus-s72tx-pin.service >/dev/null 2>&1 || true
        rm -f "$UNIT" "$BIN" "$CONF"; rmdir "$(dirname "$CONF")" 2>/dev/null || true
        systemctl daemon-reload
        echo "Removed. Threads pinned by a running UE simulator keep their setting until it restarts."
        ;;
esac
