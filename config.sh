#!/bin/bash
#
# config.sh - Configure a network interface for low-latency rant testing
#
# Auto-discovers MAC, PCI address, IRQ, and PTP clock from the interface.
# Sets up namespace, ethtool tuning, IRQ affinity, sysctl, and PTP sync.
#
# Run this script on each host (client and server) before starting rant.
# For dual-port cards, configure BOTH ports before testing.
#
# Usage:
#   config.sh <interface> --ip <local_ip> --remote-ip <remote_ip> \
#             --cpu <app_cpu> --irq-cpu <irq_cpu> [options]
#
# Required:
#   <interface>              Network interface name
#   --ip <addr>              Local IP address to assign (with /24)
#   --remote-ip <addr>       Remote peer IP address
#   --cpu <n>                CPU core for the rant application
#   --irq-cpu <n>            CPU core for NIC IRQ handling
#
# Optional:
#   --remote-mac <mac>       Remote MAC address for static ARP entry
#   --busy-poll <val>        Busy poll sysctl value (default: 50)
#   --ptp-source <dev>       PTP source device, e.g. /dev/ptp6 (auto-detected)
#   --ptp-sync-to <dev>      PTP device to sync to (for second port on same card)
#   --no-namespace           Skip namespace setup
#   --no-ptp                 Skip PTP sync setup
#   --irq-prio <n>           NIC IRQ thread FIFO priority (default: 50)
#   --ksoftirqd-prio <n>     ksoftirqd FIFO priority (default: 11)
#   --freq <ghz>             Lock CPU frequency in GHz (e.g. 3.4)
#   -h, --help               Show this help
#
# Example (server side, dual-port ConnectX-7):
#   sudo ./config.sh ens7f1np1 --ip 192.168.1.11 --remote-ip 192.168.1.10 \
#     --remote-mac aa:bb:cc:dd:ee:ff --cpu 50 --irq-cpu 52
#
# Example (client side):
#   sudo ./config.sh ens7f0np0 --ip 192.168.1.10 --remote-ip 192.168.1.11 \
#     --remote-mac 11:22:33:44:55:66 --cpu 49 --irq-cpu 51

set -e

usage() {
    sed -n '2,/^$/s/^# \?//p' "$0"
    exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Parse arguments ---
ifname=""
ip_addr=""
remote_ip=""
remote_mac=""
cpu=""
irq_cpu=""
busy_poll=50
ptp_source=""
ptp_sync_to=""
skip_namespace=0
skip_ptp=0
irq_prio=50
ksoftirqd_prio=11
lock_freq=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage ;;
        --ip)             ip_addr="$2"; shift 2 ;;
        --remote-ip)      remote_ip="$2"; shift 2 ;;
        --remote-mac)     remote_mac="$2"; shift 2 ;;
        --cpu)            cpu="$2"; shift 2 ;;
        --irq-cpu)        irq_cpu="$2"; shift 2 ;;
        --busy-poll)      busy_poll="$2"; shift 2 ;;
        --ptp-source)     ptp_source="$2"; shift 2 ;;
        --ptp-sync-to)    ptp_sync_to="$2"; shift 2 ;;
        --no-namespace)   skip_namespace=1; shift ;;
        --no-ptp)         skip_ptp=1; shift ;;
        --irq-prio)       irq_prio="$2"; shift 2 ;;
        --ksoftirqd-prio) ksoftirqd_prio="$2"; shift 2 ;;
        --freq)           lock_freq="$2"; shift 2 ;;
        -*)               die "Unknown option: $1" ;;
        *)
            if [[ -z "$ifname" ]]; then
                ifname="$1"; shift
            else
                die "Unexpected argument: $1"
            fi
            ;;
    esac
done

# --- Validate required arguments ---
[[ -n "$ifname" ]]    || die "Interface name required"
[[ -n "$ip_addr" ]]   || die "--ip required"
[[ -n "$remote_ip" ]] || die "--remote-ip required"
[[ -n "$cpu" ]]       || die "--cpu required"
[[ -n "$irq_cpu" ]]   || die "--irq-cpu required"
[[ "$cpu" != "$irq_cpu" ]] || die "App CPU and IRQ CPU must be different"

# Verify interface exists (before namespace move)
ip link show "$ifname" &>/dev/null || \
    ip netns exec "ns_${ifname}" ip link show "$ifname" &>/dev/null || \
    die "Interface $ifname not found"

set -x

# --- Auto-discover hardware properties ---

# PCI address
pci=$(ethtool -i "$ifname" 2>/dev/null | awk '/bus-info:/{print $2}' | sed 's/^0000://')
[[ -n "$pci" ]] || pci=$(ip netns exec "ns_${ifname}" ethtool -i "$ifname" 2>/dev/null | awk '/bus-info:/{print $2}' | sed 's/^0000://')
[[ -n "$pci" ]] || die "Could not detect PCI address for $ifname"

# Driver name (for driver-specific settings)
driver=$(ethtool -i "$ifname" 2>/dev/null | awk '/driver:/{print $2}')
[[ -n "$driver" ]] || driver=$(ip netns exec "ns_${ifname}" ethtool -i "$ifname" 2>/dev/null | awk '/driver:/{print $2}')

# IRQ name pattern
irq_pattern="@pci:0000:${pci}"

# PTP clock auto-detect
if [[ -z "$ptp_source" ]]; then
    ptp_dev=$(ls -d /sys/bus/pci/devices/0000:${pci}/ptp/ptp* 2>/dev/null | head -1)
    if [[ -n "$ptp_dev" ]]; then
        ptp_source="/dev/$(basename "$ptp_dev")"
    fi
fi

# MAC address
mac=$(ip link show "$ifname" 2>/dev/null | awk '/link\/ether/{print $2}')
[[ -n "$mac" ]] || mac=$(ip netns exec "ns_${ifname}" ip link show "$ifname" 2>/dev/null | awk '/link\/ether/{print $2}')

{ set +x; } 2>/dev/null
echo ""
echo "=== Detected hardware ==="
echo "  Interface:  $ifname"
echo "  MAC:        $mac"
echo "  PCI:        0000:$pci"
echo "  Driver:     $driver"
echo "  PTP:        ${ptp_source:-not found}"
echo "  IRQ match:  *${irq_pattern}*"
echo "  App CPU:    $cpu"
echo "  IRQ CPU:    $irq_cpu"
echo ""

# --- Lock CPU frequency ---
if [[ -n "$lock_freq" ]]; then
    freq_khz=$(echo "$lock_freq * 1000000" | bc | cut -d. -f1)
    if command -v cpupower &>/dev/null; then
        { set +x; } 2>/dev/null
        echo "=== Locking CPU frequency to ${lock_freq} GHz ==="
        set -x
        cpupower frequency-set -d "${freq_khz}kHz" -u "${freq_khz}kHz" -g performance 2>/dev/null || true
        # Disable turbo
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
        # Disable idle states
        for idle_dir in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]*; do
            echo 1 > "$idle_dir/disable" 2>/dev/null || true
        done
        { set +x; } 2>/dev/null
        current_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "unknown")
        echo "  Frequency: $(( current_freq / 1000 )) MHz"
        set -x
    else
        { set +x; } 2>/dev/null
        echo "WARNING: cpupower not found, skipping frequency lock"
        echo "  Install: yum install kernel-tools  or  apt install linux-tools-common"
        set -x
    fi
fi

# --- SELinux AVC cache fix ---
# Default AVC cache (512 entries) causes ~200-300us spikes when full.
if [[ -f /sys/fs/selinux/avc/cache_threshold ]]; then
    current_avc=$(cat /sys/fs/selinux/avc/cache_threshold)
    if [[ "$current_avc" -lt 8192 ]]; then
        echo 8192 > /sys/fs/selinux/avc/cache_threshold
        { set +x; } 2>/dev/null
        echo "=== SELinux AVC cache fix ==="
        echo "  cache_threshold: $current_avc -> 8192"
        set -x
    fi
fi

# --- Sysctl tuning ---
sysctl -w net.core.busy_poll=$busy_poll
sysctl -w net.core.busy_read=$busy_poll
sysctl -w net.core.gro_normal_batch=1
sysctl -w net.core.netdev_budget=300
sysctl -w net.core.netdev_budget_usecs=2000
sysctl -w net.ipv4.tcp_low_latency=1
sysctl -w net.ipv4.tcp_autocorking=0
sysctl -w net.core.default_qdisc=noqueue

# --- Namespace setup ---
ns_cmd="ip netns exec ns_${ifname}"

if [[ "$skip_namespace" -eq 0 ]]; then
    $ns_cmd ip link set "$ifname" netns 1 2>/dev/null || true
    ip netns del "ns_${ifname}" 2>/dev/null || true
    ip netns add "ns_${ifname}"
    ip link set "$ifname" netns "ns_${ifname}"
else
    if ! ip netns list | grep -q "^ns_${ifname}"; then
        ns_cmd=""
    fi
fi

# --- Ethtool tuning ---

# Queue and offload settings
current_combined=$($ns_cmd ethtool -l "$ifname" 2>/dev/null | awk '/^Combined:/{val=$2} END{print val}')
if [[ "$current_combined" != "1" ]]; then
    $ns_cmd ethtool -L "$ifname" combined 1
else
    { set +x; } 2>/dev/null
    echo "  ethtool -L: already combined 1, skipping (avoids dual-port affinity reset)"
    set -x
fi
$ns_cmd ethtool -K "$ifname" rx-checksumming off tx-checksumming off 2>/dev/null || true
$ns_cmd ethtool -K "$ifname" lro off gro off 2>/dev/null || true
$ns_cmd ethtool -K "$ifname" tso off gso off 2>/dev/null || true
$ns_cmd ethtool -C "$ifname" rx-frames 1 tx-frames 1
$ns_cmd ethtool -C "$ifname" adaptive-tx off adaptive-rx off rx-usecs 0 tx-usecs 0
$ns_cmd ethtool -G "$ifname" rx 64 tx 128
$ns_cmd ethtool -g "$ifname"
$ns_cmd ethtool -A "$ifname" rx off tx off 2>/dev/null || true

# Driver-specific private flags
case "$driver" in
    mlx5_core|mlx5e)
        $ns_cmd ethtool -C "$ifname" cqe-mode-rx off 2>/dev/null || true
        $ns_cmd ethtool -K "$ifname" ntuple off 2>/dev/null || true
        $ns_cmd ethtool -K "$ifname" rxhash off 2>/dev/null || true
        $ns_cmd ethtool --set-priv-flags "$ifname" rx_cqe_moder off 2>/dev/null || true
        $ns_cmd ethtool --set-priv-flags "$ifname" tx_port_ts off 2>/dev/null || true
        $ns_cmd ethtool --set-priv-flags "$ifname" skb_tx_mpwqe off 2>/dev/null || true
        $ns_cmd ethtool --set-priv-flags "$ifname" rx_striding_rq off 2>/dev/null || true
        ;;
    ice)
        $ns_cmd ethtool --set-priv-flags "$ifname" LinkPolling off 2>/dev/null || true
        $ns_cmd ethtool --set-priv-flags "$ifname" flow-director-atr off 2>/dev/null || true
        $ns_cmd ethtool --set-priv-flags "$ifname" disable-fw-lldp on 2>/dev/null || true
        ;;
esac

# NAPI defer and GRO flush
$ns_cmd bash -c "echo 0 > /sys/class/net/$ifname/napi_defer_hard_irqs" 2>/dev/null || true
$ns_cmd bash -c "echo 0 > /sys/class/net/$ifname/gro_flush_timeout" 2>/dev/null || true

# --- Interface and IP setup ---
$ns_cmd ip link set lo up
$ns_cmd ip link set "$ifname" up
$ns_cmd ip addr add "${ip_addr}/24" dev "$ifname" 2>/dev/null || true

# Qdisc
$ns_cmd tc qdisc replace dev "$ifname" root noqueue

# Promiscuous mode
$ns_cmd ip link set "$ifname" promisc on

# IPv6: disable and flush
$ns_cmd sysctl -w "net.ipv6.conf.$ifname.disable_ipv6=1" 2>/dev/null || true
$ns_cmd ip -6 addr flush dev "$ifname" 2>/dev/null || true

# Multicast: disable
$ns_cmd ip link set "$ifname" multicast off

# ARP: suppress broadcasts
$ns_cmd sysctl -w net.ipv4.conf.all.arp_ignore=1
$ns_cmd sysctl -w net.ipv4.conf.all.arp_announce=2

# ICMP redirects: disable
$ns_cmd sysctl -w "net.ipv4.conf.$ifname.accept_redirects=0"
$ns_cmd sysctl -w "net.ipv4.conf.$ifname.send_redirects=0"
$ns_cmd sysctl -w "net.ipv6.conf.$ifname.accept_redirects=0" 2>/dev/null || true

# Source routing: disable
$ns_cmd sysctl -w "net.ipv4.conf.$ifname.accept_source_route=0"
$ns_cmd sysctl -w "net.ipv6.conf.$ifname.accept_source_route=0" 2>/dev/null || true

# Router advertisements: disable
$ns_cmd sysctl -w "net.ipv6.conf.$ifname.accept_ra=0" 2>/dev/null || true

# Reverse path filtering: disable
$ns_cmd sysctl -w "net.ipv4.conf.$ifname.rp_filter=0"

# Static ARP
$ns_cmd ip neigh flush all
if [[ -n "$remote_mac" ]]; then
    $ns_cmd ip neigh replace "$remote_ip" lladdr "$remote_mac" nud permanent dev "$ifname"
fi
$ns_cmd ip neigh show all

# --- CPU isolation and IRQ affinity ---
if command -v tuna &>/dev/null; then
    tuna isolate -c "$cpu,$irq_cpu"
else
    { set +x; } 2>/dev/null
    echo "WARNING: tuna not found, skipping CPU isolation"
    echo "  Install: yum install tuna  or manually isolate CPUs $cpu,$irq_cpu"
    set -x
fi

# Find NIC IRQ threads
comp_thread=$(pgrep -f "mlx5_comp0${irq_pattern}" 2>/dev/null | head -1)
async_thread=$(pgrep -f "mlx5_async0${irq_pattern}" 2>/dev/null | head -1)

# If not mlx5, try generic IRQ thread discovery
if [[ -z "$comp_thread" ]]; then
    comp_thread=$(pgrep -f "${driver}.*${irq_pattern}" 2>/dev/null | head -1)
fi

# Helper: pin IRQ thread to a CPU
pin_irq_thread() {
    local pid=$1 target_cpu=$2
    if taskset -p -c "$target_cpu" "$pid" 2>/dev/null; then
        local cur=$(ps -o psr= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$cur" == "$target_cpu" ]]; then
            return 0
        fi
    fi
    # Fallback: /proc/irq smp_affinity_list
    local comm
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    local irq_num=${comm#irq/}
    irq_num=${irq_num%%-*}
    if [[ "$irq_num" =~ ^[0-9]+$ ]] && [[ -f /proc/irq/$irq_num/smp_affinity_list ]]; then
        echo "$target_cpu" > /proc/irq/$irq_num/smp_affinity_list 2>/dev/null
        return $?
    fi
    return 1
}

if [[ -n "$comp_thread" ]]; then
    pin_irq_thread "$comp_thread" "$irq_cpu"
    chrt -f -p "$irq_prio" "$comp_thread"
    { set +x; } 2>/dev/null
    echo ""
    echo "=== NIC data-path IRQ thread ==="
    echo "  PID:      $comp_thread"
    echo "  CPU:      $(ps -o psr= -p "$comp_thread" 2>/dev/null | tr -d ' ') (target: $irq_cpu)"
    echo "  Priority: $(chrt -p $comp_thread)"
    set -x
else
    { set +x; } 2>/dev/null
    echo "WARNING: NIC data-path IRQ thread not found for *${irq_pattern}*"
    echo "  Manual IRQ pinning may be required"
    set -x
fi

if [[ -n "$async_thread" ]]; then
    pin_irq_thread "$async_thread" "$irq_cpu"
    chrt -f -p "$ksoftirqd_prio" "$async_thread"
    { set +x; } 2>/dev/null
    echo "=== NIC async IRQ thread ==="
    echo "  PID:      $async_thread"
    echo "  Priority: $(chrt -p $async_thread)"
    set -x
fi

# Demote competing IRQ threads on app and IRQ CPUs
{ set +x; } 2>/dev/null
echo ""
echo "=== Demoting competing IRQ threads on CPUs $cpu and $irq_cpu ==="
for target_cpu in $cpu $irq_cpu; do
    for pid in $(ps -eLo pid,psr,comm 2>/dev/null | awk -v cpu="$target_cpu" '$2==cpu && $3~/^irq\// {print $1}'); do
        comm=$(cat /proc/$pid/comm 2>/dev/null)
        if [[ "$pid" != "$comp_thread" && "$pid" != "$async_thread" ]]; then
            if taskset -p -c 0 "$pid" 2>/dev/null; then
                new_cpu=$(ps -o psr= -p "$pid" 2>/dev/null | tr -d ' ')
                if [[ "$new_cpu" == "$target_cpu" ]]; then
                    # Managed IRQ: can't move, demote to SCHED_OTHER
                    chrt -o -p 0 "$pid" 2>/dev/null && \
                        echo "  Demoted $comm (PID $pid) to SCHED_OTHER on CPU $target_cpu (managed IRQ)"
                else
                    echo "  Moved $comm (PID $pid) from CPU $target_cpu to CPU $new_cpu"
                fi
            fi
        fi
    done
done
set -x

# Dual-port fix: save/restore sibling port IRQ state
pci_bus="${pci%.*}"
state_dir="/tmp/config_sh_irq_state"
mkdir -p "$state_dir"

{ set +x; } 2>/dev/null
echo "$irq_cpu $irq_prio $comp_thread" > "$state_dir/${pci}_comp0"
if [[ -n "$async_thread" ]]; then
    echo "$irq_cpu $ksoftirqd_prio $async_thread" > "$state_dir/${pci}_async0"
fi

for state_file in "$state_dir/${pci_bus}."*_comp0; do
    [[ -f "$state_file" ]] || continue
    [[ "$state_file" == "$state_dir/${pci}_comp0" ]] && continue
    read -r sib_cpu sib_prio sib_pid < "$state_file"
    if [[ -n "$sib_pid" ]] && kill -0 "$sib_pid" 2>/dev/null; then
        current_cpu=$(ps -o psr= -p "$sib_pid" 2>/dev/null | tr -d ' ')
        if [[ "$current_cpu" != "$sib_cpu" ]]; then
            sib_comm=$(cat /proc/$sib_pid/comm 2>/dev/null)
            echo "  Dual-port fix: $sib_comm (PID $sib_pid) drifted to CPU $current_cpu, re-pinning to CPU $sib_cpu"
            taskset -p -c "$sib_cpu" "$sib_pid" 2>/dev/null
        fi
        chrt -f -p "$sib_prio" "$sib_pid" 2>/dev/null
    fi
done
for state_file in "$state_dir/${pci_bus}."*_async0; do
    [[ -f "$state_file" ]] || continue
    [[ "$state_file" == "$state_dir/${pci}_async0" ]] && continue
    read -r sib_cpu sib_prio sib_pid < "$state_file"
    if [[ -n "$sib_pid" ]] && kill -0 "$sib_pid" 2>/dev/null; then
        current_cpu=$(ps -o psr= -p "$sib_pid" 2>/dev/null | tr -d ' ')
        if [[ "$current_cpu" != "$sib_cpu" ]]; then
            sib_comm=$(cat /proc/$sib_pid/comm 2>/dev/null)
            echo "  Dual-port fix: $sib_comm (PID $sib_pid) drifted to CPU $current_cpu, re-pinning to CPU $sib_cpu"
            taskset -p -c "$sib_cpu" "$sib_pid" 2>/dev/null
        fi
        chrt -f -p "$sib_prio" "$sib_pid" 2>/dev/null
    fi
done
set -x

# ksoftirqd priority
ksoftirqd_pid=$(pgrep -x "ksoftirqd/$irq_cpu" 2>/dev/null)
if [[ -n "$ksoftirqd_pid" ]]; then
    chrt -f -p "$ksoftirqd_prio" "$ksoftirqd_pid"
    { set +x; } 2>/dev/null
    echo ""
    echo "=== ksoftirqd/$irq_cpu ==="
    echo "  Priority: $(chrt -p $ksoftirqd_pid)"
    echo ""
    set -x
fi

# --- Enable softirq inline on app and IRQ CPUs ---
{ set +x; } 2>/dev/null
echo ""
echo "=== Enabling softirq_inline on CPUs $cpu and $irq_cpu ==="
for target_cpu in $cpu $irq_cpu; do
    if [[ -f /sys/devices/system/cpu/cpu$target_cpu/softirq_inline ]]; then
        current=$(cat /sys/devices/system/cpu/cpu$target_cpu/softirq_inline)
        if [[ "$current" != "1" ]]; then
            echo 1 > /sys/devices/system/cpu/cpu$target_cpu/softirq_inline
            echo "  CPU $target_cpu: softirq_inline enabled (was $current)"
        else
            echo "  CPU $target_cpu: softirq_inline already enabled"
        fi
    else
        echo "  CPU $target_cpu: softirq_inline not available"
    fi
done
echo ""
set -x

# --- PCIe power management disable ---
setpci -s "$pci" 0xd0.b=0x00 2>/dev/null || true

# --- PTP clock setup ---
if [[ "$skip_ptp" -eq 0 && -n "$ptp_source" ]]; then
    pkill -f "phc2sys" 2>/dev/null || true
    sleep 0.5

    phc_ctl "$ptp_source" set $(date +%s.%N) 2>/dev/null || true

    { set +x; } 2>/dev/null
    echo ""
    echo "=== PTP clock ==="
    echo "  PHC device: $ptp_source"

    if [[ -z "$ptp_sync_to" ]]; then
        echo "  Mode:       phc2sys syncing system clock to $ptp_source"
        phc2sys -s "$ptp_source" -O 0 -S 0.0 -P 1.0 -I 0.1 -R 16 -l 6 >/dev/null 2>&1 &
        sleep 2
        echo "  phc2sys pid: $(pgrep -f "phc2sys.*$ptp_source.*-R" 2>/dev/null)"
    else
        echo "  Mode:       phc2sys syncing $ptp_source to $ptp_sync_to"
        phc2sys -s "$ptp_sync_to" -c "$ptp_source" -O 0 -S 0.0 -l 6 >/dev/null 2>&1 &
        sleep 2
        echo "  phc2sys pid: $(pgrep -f "phc2sys.*$ptp_sync_to.*-c" 2>/dev/null)"
    fi
    echo ""
    set -x
fi

# --- Final verification ---
{ set +x; } 2>/dev/null
echo ""
echo "=== Final verification ==="

# IRQ affinity
if [[ -n "$comp_thread" ]]; then
    actual_cpu=$(ps -o psr= -p "$comp_thread" 2>/dev/null | tr -d ' ')
    if [[ "$actual_cpu" != "$irq_cpu" ]]; then
        echo "  WARNING: NIC IRQ thread drifted to CPU $actual_cpu, re-pinning to CPU $irq_cpu"
        pin_irq_thread "$comp_thread" "$irq_cpu"
        chrt -f -p "$irq_prio" "$comp_thread" >/dev/null 2>&1
        actual_cpu=$(ps -o psr= -p "$comp_thread" 2>/dev/null | tr -d ' ')
    fi
    echo "  NIC IRQ (PID $comp_thread): CPU $actual_cpu (target: $irq_cpu)"
fi

# NIC coalescing
RX_FRAMES=$($ns_cmd ethtool -c "$ifname" 2>/dev/null | grep "^rx-frames:" | awk '{print $2}')
RX_USECS=$($ns_cmd ethtool -c "$ifname" 2>/dev/null | grep "^rx-usecs:" | awk '{print $2}')
if [[ "$RX_FRAMES" == "1" ]]; then
    echo "  rx-frames: 1 (correct)"
else
    echo "  WARNING: rx-frames: $RX_FRAMES (expected 1)"
    $ns_cmd ethtool -C "$ifname" adaptive-rx off adaptive-tx off 2>/dev/null || true
    $ns_cmd ethtool -C "$ifname" rx-frames 1 tx-frames 1 2>/dev/null || true
    RX_FRAMES=$($ns_cmd ethtool -c "$ifname" 2>/dev/null | grep "^rx-frames:" | awk '{print $2}')
    echo "  After fix: rx-frames: $RX_FRAMES"
fi
if [[ "$RX_USECS" == "0" ]]; then
    echo "  rx-usecs: 0 (correct)"
else
    echo "  WARNING: rx-usecs: $RX_USECS (expected 0)"
fi

echo ""
echo "=== SUCCESS ==="
echo "  Interface $ifname configured in namespace ns_${ifname}"
echo "  IP: ${ip_addr}/24, Remote: ${remote_ip}"
echo "  App CPU: $cpu, IRQ CPU: $irq_cpu"
echo "  rx-frames: $RX_FRAMES, rx-usecs: $RX_USECS"
echo ""
