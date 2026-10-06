#!/bin/bash

# Backhaul Tunnel Manager (Iran <-> Kharej) — v9  (data-usage control)
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding (wss/wssmux).
#
# v9 changes vs v8 — everything here is about wasted / uncontrolled data usage:
#   - No more reconnect storms: client retry_interval 1 -> 3, aggressive_pool off, systemd
#     RestartSec 1 -> 5 (StartLimitIntervalSec moved to [Unit] where systemd actually reads it),
#     watchdog limited to 3 restarts / 10 min per tunnel and it no longer restarts services
#     that you stopped on purpose.
#   - Kernel profile fixed: 128 MB buffers -> 32 MB, tcp_retries2 6 -> 8 (fewer false resets),
#     and the sysctl keys that do not exist on Linux (net.ipv4.tcp_user_timeout,
#     net.ipv4.tcp_low_latency) are gone. With "set -e" those made the v8 optimizer abort
#     half-way, before anything was written to disk.
#   - NEW "Data usage & limits" menu: monthly traffic counters per tunnel + for the whole
#     server, an idle-traffic test, and an optional monthly quota guard that stops the
#     tunnels when the limit is reached.
#   - NEW "Apply data-saver fixes" menu entry: patches tunnels that are already installed
#     (no need to re-create them).
#   - Status page shows systemd auto-restart counts (a big number = reconnect loop).
#   (v8 features — IPv4/IPv6 tunnel link, several Iran servers per Kharej — are unchanged.)
#
# Run this SEPARATELY on each server (every Iran server + the Kharej server).
# Order: set up the Iran server(s) first, note their IP / tunnel port, then run the Kharej setup.

set -e

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
STATE_FILE="$INSTALL_DIR/state.env"
FIXED_TOKEN="${BACKHAUL_TOKEN:-123}"
WATCHDOG_SCRIPT="$INSTALL_DIR/watchdog.sh"
WATCHDOG_LOG="$INSTALL_DIR/watchdog.log"
WATCHDOG_STATE_DIR="$INSTALL_DIR/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=60
USAGE_SCRIPT="$INSTALL_DIR/usage.sh"
USAGE_DIR="$INSTALL_DIR/usage"
QUOTA_FILE="$INSTALL_DIR/quota.conf"
QUOTA_LOCK="$USAGE_DIR/quota-exceeded"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)."
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# ============================================================
# Helpers
# ============================================================

detect_public_ip() {
    curl -fsSL -4 --max-time 6 https://ifconfig.me 2>/dev/null \
        || curl -fsSL -4 --max-time 6 https://api.ipify.org 2>/dev/null \
        || echo ""
}

detect_public_ip6() {
    curl -fsSL -6 --max-time 6 https://ifconfig.me 2>/dev/null \
        || curl -fsSL -6 --max-time 6 https://api6.ipify.org 2>/dev/null \
        || echo ""
}

detect_default_iface() {
    local iface
    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
    [ -z "$iface" ] && iface=$(ip -o -6 route show default 2>/dev/null | awk '{print $5}' | head -n1)
    [ -z "$iface" ] && iface=$(ip link show | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

ensure_backhaul_local() {
    mkdir -p "$INSTALL_DIR"
    if [ -x "$INSTALL_DIR/backhaul" ]; then
        return
    fi
    echo "Fetching latest official Backhaul release from GitHub..."
    local arch asset_arch url attempt
    arch=$(uname -m)
    case "$arch" in
        x86_64) asset_arch="amd64" ;;
        aarch64) asset_arch="arm64" ;;
        *) echo "Unsupported architecture: $arch"; exit 1 ;;
    esac
    url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep "browser_download_url" | grep "linux_${asset_arch}" | grep -v ".sha256" \
        | head -n1 | cut -d '"' -f4)
    if [ -z "$url" ]; then
        echo "Could not resolve a release asset automatically."
        read -p "Paste the correct .tar.gz download URL: " url
    fi

    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    attempt=0
    until curl -fSL --retry 3 --retry-delay 2 -o "$INSTALL_DIR/backhaul.tar.gz" "$url"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
            echo "Download failed after multiple attempts."
            echo "Check disk space (df -h) and network access, then try again."
            exit 1
        fi
        echo "Retrying download..."
        sleep 2
    done

    if [ ! -s "$INSTALL_DIR/backhaul.tar.gz" ]; then
        echo "Downloaded file is empty — aborting."
        exit 1
    fi

    if ! tar -tzf "$INSTALL_DIR/backhaul.tar.gz" >/dev/null 2>&1; then
        echo "Downloaded file is not a valid archive — aborting. Try re-running."
        rm -f "$INSTALL_DIR/backhaul.tar.gz"
        exit 1
    fi

    tar -xzf "$INSTALL_DIR/backhaul.tar.gz" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    chmod +x "$INSTALL_DIR/backhaul"
    echo "Backhaul binary installed."
}

ensure_tls_cert_local() {
    # wss/wssmux require tls_cert/tls_key on the server side.
    if [ -f "$INSTALL_DIR/server.crt" ] && [ -f "$INSTALL_DIR/server.key" ]; then
        return
    fi
    echo "Generating self-signed TLS certificate for wss/wssmux..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" \
        -days 3650 -subj "/CN=backhaul" >/dev/null 2>&1
}

gen_port() {
    echo $(( (RANDOM % 40000) + 20000 ))
}

ask_yn() {
    # usage: ask_yn "Question?" [y|n]   -> returns 0 for yes, 1 for no
    local prompt="$1" def="${2:-n}" ans
    read -p "$prompt [$def]: " ans
    ans=${ans:-$def}
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

list_backhaul_units() {
    # all installed Backhaul unit files (also the ones that are currently stopped)
    systemctl list-unit-files --no-legend 'backhaul-*.service' 2>/dev/null | awk '{print $1}'
}

list_tunnel_units() {
    # tunnel services only (no MTU / watchdog / usage helper units)
    list_backhaul_units | grep -vE '^backhaul-(mtu|watchdog|usage)\.service$' || true
}

fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.2f %s", b, u[i] }'
}

sum_restarts() {
    # total systemd auto-restarts of all tunnel services (needs systemd >= 235)
    local u n total=0
    for u in $(list_tunnel_units); do
        n=$(systemctl show -p NRestarts --value "$u" 2>/dev/null || true)
        if [[ "$n" =~ ^[0-9]+$ ]]; then
            total=$((total + n))
        fi
    done
    echo "$total"
}

# ---------- IP / port validation + formatting (IPv4 and IPv6) ----------

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

valid_ipv6() {
    local ip="$1" colons
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    colons="${ip//[^:]/}"
    [ "${#colons}" -ge 2 ] || return 1
    return 0
}

clean_ip_input() {
    # strip spaces and [ ] brackets the user may have typed around an IPv6 address
    local ip="$1"
    ip="${ip//[[:space:]]/}"
    ip="${ip//\[/}"
    ip="${ip//\]/}"
    echo "$ip"
}

format_hostport() {
    # IPv6 literals must be wrapped in [] when followed by :port
    local host="$1" port="$2"
    if [[ "$host" == *:* ]]; then
        echo "[${host}]:${port}"
    else
        echo "${host}:${port}"
    fi
}

make_tag() {
    # filesystem/systemd-safe tag from an IP address
    echo "$1" | tr ':.' '__'
}

has_global_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6"
}

check_reachable() {
    # quick TCP probe (works for IPv4 and IPv6 literals)
    local host="$1" port="$2"
    timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

IP_MODE=4
ask_ip_version() {
    # sets global IP_MODE to 4 or 6
    local prompt="$1" c
    echo ""
    echo "$prompt"
    echo "  1) IPv4"
    echo "  2) IPv6"
    read -p "Enter choice [1-2] (default 1): " c
    case "$c" in
        2) IP_MODE=6 ;;
        *) IP_MODE=4 ;;
    esac
}

prepare_ipv6() {
    # Make sure IPv6 is enabled in the kernel and listeners are dual-stack.
    # Returns 1 if the user wants to go back (no global IPv6 on this host).
    local conf="/etc/sysctl.d/98-backhaul-ipv6.conf"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
    cat > "$conf" << EOF
-net.ipv6.conf.all.disable_ipv6=0
-net.ipv6.conf.default.disable_ipv6=0
-net.ipv6.bindv6only=0
EOF
    if has_global_ipv6; then
        return 0
    fi
    echo "Warning: no global (public) IPv6 address was detected on this server."
    echo "         An IPv6 tunnel will not work until the server gets an IPv6 address."
    if ask_yn "Continue with IPv6 anyway?" n; then
        return 0
    fi
    return 1
}

# ============================================================
# MTU pinning (persisted across reboots via a oneshot systemd unit)
# ============================================================

ensure_mtu() {
    echo ""
    echo "=== Setting MTU to 1400 ==="
    local iface
    iface=$(detect_default_iface)
    echo "Interface: $iface"

    ip link set dev "$iface" mtu 1400 2>/dev/null || echo "Could not set MTU live (will still persist for next boot)."

    cat > /etc/systemd/system/backhaul-mtu.service << EOF
[Unit]
Description=Pin MTU 1400 on ${iface} for Backhaul tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${iface} mtu 1400
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now backhaul-mtu.service >/dev/null 2>&1
    echo "MTU 1400 applied and will persist after reboot (backhaul-mtu.service)."
}

# ============================================================
# DNS pinning
# ============================================================

ensure_dns() {
    echo ""
    echo "=== Setting DNS to 1.1.1.1 / 1.0.0.1 / 8.8.8.8 ==="
    # Drop the immutable flag from a previous run, otherwise rewriting the file fails.
    chattr -i /etc/resolv.conf 2>/dev/null || true
    if [ -L /etc/resolv.conf ]; then
        # Usually managed by systemd-resolved — replace the symlink with a static file
        # so it isn't reset. This detaches this host from systemd-resolved's stub DNS.
        rm -f /etc/resolv.conf
    fi
    cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
EOF
    # Best-effort: prevent NetworkManager/dhcp client from overwriting it back.
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "DNS set. (If this server uses systemd-resolved/NetworkManager, this file is now static/locked with chattr +i.)"
}

# ============================================================
# File descriptor / ulimit tuning
# ============================================================

ensure_ulimits() {
    echo ""
    echo "=== Raising file descriptor limits ==="
    if ! grep -q "^fs.file-max" /etc/sysctl.d/99-backhaul-tunnel.conf 2>/dev/null; then
        echo "fs.file-max=2097152" >> /etc/sysctl.d/99-backhaul-tunnel.conf
    fi
    sysctl -w fs.file-max=2097152 > /dev/null 2>&1 || true

    if ! grep -q "backhaul-tunnel limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << EOF

# backhaul-tunnel limits
root soft nofile 1048576
root hard nofile 1048576
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
    ulimit -n 1048576 2>/dev/null || true
    echo "File descriptor limits raised (takes full effect for new sessions/services)."
}

# ============================================================
# Kernel network profile (shared by the optimizer and "apply fixes")
# ============================================================

tune_sysctl() {
    local conf="/etc/sysctl.d/99-backhaul-tunnel.conf" bbr_ok=0 line

    # BBR only if the kernel really offers it (try to load the module first).
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        bbr_ok=1
        echo "BBR congestion control available — enabling it."
        echo "tcp_bbr" > /etc/modules-load.d/backhaul-bbr.conf 2>/dev/null || true
    else
        echo "BBR module not available on this kernel — staying on the default (usually CUBIC)."
    fi

    # Changes vs v8 (all aimed at NOT wasting data):
    #  - buffers 128 MB -> 32 MB: still plenty for ~1 Gbit x 200 ms, but huge buffers on a lossy,
    #    long-RTT link only add queueing delay, timeouts and spurious retransmissions.
    #  - tcp_retries2 6 -> 8: a healthy-but-lossy tunnel connection is no longer killed after ~25 s
    #    of loss (every kill = reconnect + TLS handshakes + users re-downloading).
    #  - removed net.ipv4.tcp_user_timeout and net.ipv4.tcp_low_latency: neither exists as a sysctl
    #    on modern Linux; they only produced errors (and aborted the v8 script under "set -e").
    #  - NOT set on purpose: tcp_tw_recycle (removed from kernel), tcp_tw_reuse (breaks behind NAT),
    #    net.ipv6.conf.all.forwarding (would stop IPv6 router advertisements and can kill IPv6).
    cat > "$conf" << EOF
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.ip_local_port_range=1024 65535
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_retries2=8
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.ip_forward=1
fs.file-max=2097152
EOF
    if [ "$bbr_ok" = "1" ]; then
        printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> "$conf"
    fi
    echo "Saved to $conf (persists across reboots)."

    # Apply live, one key at a time — a key that is missing on this kernel must never abort the script.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        sysctl -w "$line" > /dev/null 2>&1 || echo "  (skipped, not supported on this kernel: ${line%%=*})"
    done < "$conf"
    echo "Kernel profile applied."
    return 0
}

# ============================================================
# System Optimizer (kernel profile + MTU + DNS + ulimits)
# ============================================================

optimize_system() {
    echo ""
    echo "=== System Optimization ==="
    local INTERFACE
    INTERFACE=$(detect_default_iface)
    echo "Interface: $INTERFACE"

    tune_sysctl
    ensure_ulimits
    ensure_mtu
    ensure_dns

    echo ""
    echo "Optimization complete."
}

# ============================================================
# Watchdog (health check + auto-restart, with restart-storm protection)
# ============================================================

setup_watchdog() {
    echo ""
    echo "=== Installing Watchdog ==="
    mkdir -p "$WATCHDOG_STATE_DIR"

    cat > "$WATCHDOG_SCRIPT" << 'WDEOF'
#!/bin/bash
# Backhaul watchdog — runs every 10s via backhaul-watchdog.timer
# Restarts a tunnel only if:
#   1) systemd reports it as "failed", OR
#   2) it is running but has had zero established tunnel connections for IDLE_THRESHOLD
#      seconds (link looks dead/hung).
# Safety rails — the watchdog must never be the cause of wasted data:
#   - "inactive" units (stopped on purpose from the menu / by the quota guard) are left alone
#   - at most MAX_RESTARTS restarts per unit per WINDOW seconds (restart-storm protection)
#   - nothing is touched while the quota lock exists
#
# Works with IPv4 and IPv6 tunnels, and with several tunnel services on one machine:
# each service is judged only by the connections that belong to its own process.

INSTALL_DIR="/root/backhaul-core"
STATE_DIR="$INSTALL_DIR/watchdog-state"
LOG_FILE="$INSTALL_DIR/watchdog.log"
QUOTA_LOCK="$INSTALL_DIR/usage/quota-exceeded"
IDLE_THRESHOLD=60
MAX_RESTARTS=3
WINDOW=600

mkdir -p "$STATE_DIR"

# The quota guard stopped the tunnels on purpose: do nothing.
[ -f "$QUOTA_LOCK" ] && exit 0

restart_allowed() {
    local f="${STATE_DIR}/${1}.restarts" now cutoff n
    now=$(date +%s)
    cutoff=$((now - WINDOW))
    if [ -f "$f" ]; then
        awk -v c="$cutoff" '$1 >= c' "$f" > "${f}.tmp" 2>/dev/null
        mv -f "${f}.tmp" "$f"
    fi
    n=$(grep -c . "$f" 2>/dev/null || true)
    n=${n:-0}
    if [ "$n" -ge "$MAX_RESTARTS" ]; then
        return 1
    fi
    echo "$now" >> "$f"
    return 0
}

do_restart() {
    local unit="$1" reason="$2" now marker last
    now=$(date +%s)
    if restart_allowed "$unit"; then
        systemctl restart "$unit" 2>/dev/null
        echo "$now" > "${STATE_DIR}/${unit}.last_ok"
        echo "$(date '+%F %T') restarted $unit ($reason)" >> "$LOG_FILE"
    else
        # log the back-off at most once per window so the log stays small
        marker="${STATE_DIR}/${unit}.skip_logged"
        last=$(cat "$marker" 2>/dev/null || echo 0)
        if [ $(( now - last )) -ge "$WINDOW" ]; then
            echo "$(date '+%F %T') NOT restarting $unit ($reason): already restarted ${MAX_RESTARTS}x in the last $((WINDOW / 60)) min - backing off" >> "$LOG_FILE"
            echo "$now" > "$marker"
        fi
    fi
}

for unit in $(systemctl list-unit-files --no-legend 'backhaul-*.service' 2>/dev/null | awk '{print $1}'); do
    case "$unit" in
        backhaul-mtu.service|backhaul-watchdog.service|backhaul-usage.service) continue ;;
    esac

    state=$(systemctl is-active "$unit" 2>/dev/null)
    if [ "$state" = "failed" ]; then
        do_restart "$unit" "service was in failed state"
        continue
    fi
    # inactive = stopped on purpose, activating = systemd is already retrying -> leave it alone
    [ "$state" = "active" ] || continue

    unit_file="/etc/systemd/system/${unit}"
    toml=$(grep -oE '/root/backhaul-core/[a-zA-Z0-9_.-]+\.toml' "$unit_file" 2>/dev/null | head -n1)
    [ -z "$toml" ] || [ ! -f "$toml" ] && continue

    # Tunnel port = last number of bind_addr (server) or remote_addr (client).
    # Handles "0.0.0.0:443", "[::]:443", "1.2.3.4:443" and "[2001:db8::1]:443".
    port=$(grep -E '^(bind_addr|remote_addr)[[:space:]]*=' "$toml" | head -n1 | grep -oE '[0-9]+"$' | tr -d '"')
    [ -z "$port" ] && continue

    pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
    [ -z "$pid" ] || [ "$pid" = "0" ] && continue

    if grep -q '^\[server\]' "$toml" 2>/dev/null; then
        # Iran side: connections accepted on the tunnel port
        active_conns=$(ss -H -tn state established "( sport = :${port} )" 2>/dev/null | grep -c .)
    else
        # Kharej side: connections of THIS service's process to the tunnel port
        active_conns=$(ss -H -tnp state established "( dport = :${port} )" 2>/dev/null | grep -c "pid=${pid},")
    fi

    now=$(date +%s)
    state_file="${STATE_DIR}/${unit}.last_ok"
    [ -f "$state_file" ] || echo "$now" > "$state_file"

    if [ "${active_conns:-0}" -gt 0 ]; then
        echo "$now" > "$state_file"
    else
        last_ok=$(cat "$state_file" 2>/dev/null || echo "$now")
        idle=$(( now - last_ok ))
        if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
            do_restart "$unit" "idle ${idle}s, no established connections on port ${port}"
        fi
    fi
done
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > /etc/systemd/system/backhaul-watchdog.service << EOF
[Unit]
Description=Backhaul Watchdog (health check / auto-restart)

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF

    cat > /etc/systemd/system/backhaul-watchdog.timer << 'EOF'
[Unit]
Description=Run Backhaul Watchdog every 10 seconds

[Timer]
OnBootSec=20
OnUnitActiveSec=10
AccuracySec=1
Unit=backhaul-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-watchdog.timer >/dev/null 2>&1
    echo "Watchdog installed — checks every 10s, restarts a tunnel after ${WATCHDOG_IDLE_THRESHOLD}s with no active"
    echo "connections (max 3 restarts per 10 minutes per tunnel)."
    echo "Log: $WATCHDOG_LOG"
}

# ============================================================
# Usage monitor + quota guard
# ============================================================

setup_usage_monitor() {
    echo ""
    echo "=== Installing usage monitor ==="
    mkdir -p "$USAGE_DIR"

    cat > "$USAGE_SCRIPT" << 'UEOF'
#!/bin/bash
# Backhaul usage monitor — runs every 60s via backhaul-usage.timer
#  1) keeps MONTHLY traffic counters: one per tunnel service (systemd IP accounting) and one for
#     the whole network card (this is what your provider bills)
#  2) quota guard: if /root/backhaul-core/quota.conf sets a limit and the network card's usage for
#     the month reaches it, ALL tunnels are stopped (the watchdog leaves them alone while the lock
#     exists). The lock is released automatically on the 1st of the next month.

INSTALL_DIR="/root/backhaul-core"
USAGE_DIR="$INSTALL_DIR/usage"
QUOTA_FILE="$INSTALL_DIR/quota.conf"
QUOTA_LOCK="$USAGE_DIR/quota-exceeded"
LOG_FILE="$INSTALL_DIR/watchdog.log"
UINT64_MAX="18446744073709551615"

mkdir -p "$USAGE_DIR"
period=$(date +%Y-%m)

tunnel_units() {
    systemctl list-unit-files --no-legend 'backhaul-*.service' 2>/dev/null | awk '{print $1}' \
        | grep -vE '^backhaul-(mtu|watchdog|usage)\.service$'
}

accumulate() {
    # $1 = key, $2 = current received bytes, $3 = current sent bytes
    local key="$1" cin="$2" cout="$3" f="$USAGE_DIR/${1}.state"
    local p lin lout tin tout
    if [ -f "$f" ] && read -r p lin lout tin tout < "$f" && [ -n "$tout" ]; then
        :
    else
        p="$period"; lin="$cin"; lout="$cout"; tin=0; tout=0
    fi
    if [ "$p" != "$period" ]; then p="$period"; tin=0; tout=0; fi
    # kernel / systemd counters restart from 0 after a reboot or a service restart
    if [ "$cin" -ge "$lin" ]; then tin=$((tin + cin - lin)); else tin=$((tin + cin)); fi
    if [ "$cout" -ge "$lout" ]; then tout=$((tout + cout - lout)); else tout=$((tout + cout)); fi
    echo "$p $cin $cout $tin $tout" > "$f"
}

# ---- whole network card ----
iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
[ -z "$iface" ] && iface=$(ip -o -6 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [ -n "$iface" ] && [ -r "/sys/class/net/${iface}/statistics/rx_bytes" ]; then
    accumulate "nic" "$(cat "/sys/class/net/${iface}/statistics/rx_bytes")" "$(cat "/sys/class/net/${iface}/statistics/tx_bytes")"
fi

# ---- per tunnel service ----
for unit in $(tunnel_units); do
    systemctl is-active --quiet "$unit" || continue
    vals=$(systemctl show -p IPIngressBytes -p IPEgressBytes "$unit" 2>/dev/null)
    cin=$(echo "$vals" | sed -n 's/^IPIngressBytes=//p')
    cout=$(echo "$vals" | sed -n 's/^IPEgressBytes=//p')
    [[ "$cin" =~ ^[0-9]+$ ]] && [[ "$cout" =~ ^[0-9]+$ ]] || continue
    [ "$cin" = "$UINT64_MAX" ] || [ "$cout" = "$UINT64_MAX" ] && continue
    accumulate "$unit" "$cin" "$cout"
done

# ---- quota guard ----
if [ -f "$QUOTA_LOCK" ]; then
    if [ "$(cat "$QUOTA_LOCK" 2>/dev/null)" != "$period" ]; then
        rm -f "$QUOTA_LOCK"
        for unit in $(tunnel_units); do systemctl start "$unit" >/dev/null 2>&1; done
        echo "$(date '+%F %T') new month: quota lock released, tunnels started" >> "$LOG_FILE"
    fi
    exit 0
fi

[ -f "$QUOTA_FILE" ] || exit 0
QUOTA_GB=0
QUOTA_COUNT=total
. "$QUOTA_FILE"
[[ "$QUOTA_GB" =~ ^[0-9]+$ ]] && [ "$QUOTA_GB" -gt 0 ] || exit 0
[ -f "$USAGE_DIR/nic.state" ] || exit 0
read -r _ _ _ tin tout < "$USAGE_DIR/nic.state" || exit 0
if [ "$QUOTA_COUNT" = "out" ]; then used=$tout; else used=$((tin + tout)); fi
if [ "$used" -ge $((QUOTA_GB * 1073741824)) ]; then
    echo "$period" > "$QUOTA_LOCK"
    echo "$(date '+%F %T') QUOTA REACHED (${QUOTA_GB} GB/month, used $((used / 1048576)) MB): stopping all tunnels" >> "$LOG_FILE"
    for unit in $(tunnel_units); do systemctl stop "$unit" >/dev/null 2>&1; done
fi
exit 0
UEOF
    chmod +x "$USAGE_SCRIPT"

    cat > /etc/systemd/system/backhaul-usage.service << EOF
[Unit]
Description=Backhaul usage monitor (traffic counters / quota guard)

[Service]
Type=oneshot
ExecStart=${USAGE_SCRIPT}
EOF

    cat > /etc/systemd/system/backhaul-usage.timer << 'EOF'
[Unit]
Description=Run Backhaul usage monitor every 60 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=1
Unit=backhaul-usage.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-usage.timer >/dev/null 2>&1
    systemctl start backhaul-usage.service >/dev/null 2>&1 || true
    echo "Usage monitor installed — counters update every 60s (see menu: Data usage & limits)."
    echo "Note: per-tunnel counters need the tunnel services to run with IPAccounting=yes."
    echo "      Tunnels created by v8 get that via menu option 'Apply data-saver fixes'."
    return 0
}

show_usage() {
    local f key p lin lout tin tout label found=0 nic
    local QUOTA_GB=0 QUOTA_COUNT=total used limit pct

    echo ""
    echo "=== Data usage this month ($(date +%Y-%m)) ==="
    printf '%-50s %12s %12s %12s\n' "" "Received" "Sent" "Total"
    for f in "$USAGE_DIR"/nic.state "$USAGE_DIR"/backhaul-*.state; do
        [ -f "$f" ] || continue
        read -r p lin lout tin tout < "$f" || continue
        key=$(basename "$f" .state)
        if [ "$key" = "nic" ]; then
            label="WHOLE SERVER (what your provider sees)"
        else
            label="$key"
        fi
        printf '%-50s %12s %12s %12s\n' "${label:0:50}" "$(fmt_bytes "$tin")" "$(fmt_bytes "$tout")" "$(fmt_bytes $((tin + tout)))"
        found=1
    done
    if [ "$found" = "0" ]; then
        echo "No counters yet — install the usage monitor (menu option 6) and check again in a few minutes."
        return 0
    fi
    echo ""
    echo "How to read this: the WHOLE SERVER row is the real network usage. Tunnel rows count every socket of"
    echo "that service (tunnel side + user side; on the Kharej server also loopback traffic to local services),"
    echo "so they are larger than the bytes that really cross the network. If WHOLE SERVER is much bigger than"
    echo "what your users should consume, run the idle traffic test to find out whether the tunnel itself is wasting data."

    nic="$USAGE_DIR/nic.state"
    if [ -f "$QUOTA_FILE" ] && [ -f "$nic" ]; then
        . "$QUOTA_FILE"
        read -r p lin lout tin tout < "$nic" || true
        if [ "$QUOTA_COUNT" = "out" ]; then used=$tout; else used=$((tin + tout)); fi
        limit=$((QUOTA_GB * 1073741824))
        pct=0
        if [ "$limit" -gt 0 ]; then
            pct=$((used * 100 / limit))
        fi
        echo ""
        echo "Quota guard: ${QUOTA_GB} GB/month ($([ "$QUOTA_COUNT" = "out" ] && echo "outgoing only" || echo "upload + download")) — used $(fmt_bytes "$used") = ${pct}%"
    else
        echo ""
        echo "Quota guard: off"
    fi
    if [ -f "$QUOTA_LOCK" ]; then
        echo "STATE: limit reached — tunnels are STOPPED. Use 'Resume tunnels' or raise the quota."
    fi
    return 0
}

set_quota() {
    local gb basis mode
    echo ""
    echo "Monthly quota guard: when this server's network usage in the current month reaches the limit,"
    echo "ALL Backhaul tunnels on this server are stopped. They start again on the 1st of next month,"
    echo "or when you choose 'Resume tunnels' / raise the limit."
    read -p "Monthly limit in GB (0 = turn the guard off): " gb
    if ! [[ "$gb" =~ ^[0-9]+$ ]]; then
        echo "Enter a whole number."
        return 0
    fi
    if [ "$gb" -eq 0 ]; then
        rm -f "$QUOTA_FILE"
        echo "Quota guard disabled."
        if [ -f "$QUOTA_LOCK" ]; then
            resume_tunnels
        fi
        return 0
    fi
    echo "How does your provider count traffic?"
    echo "  1) upload + download"
    echo "  2) outgoing only"
    read -p "Enter choice [1-2] (default 1): " basis
    case "$basis" in
        2) mode="out" ;;
        *) mode="total" ;;
    esac
    cat > "$QUOTA_FILE" << EOF
QUOTA_GB=${gb}
QUOTA_COUNT=${mode}
EOF
    if [ ! -f "$USAGE_SCRIPT" ]; then
        setup_usage_monitor
    fi
    if [ -f "$QUOTA_LOCK" ]; then
        # a new limit was set: release the lock, the monitor stops the tunnels again if still over it
        resume_tunnels
    fi
    echo "Quota guard set: ${gb} GB/month (${mode}). Checked every 60 seconds."
    return 0
}

resume_tunnels() {
    local u
    rm -f "$QUOTA_LOCK"
    for u in $(list_tunnel_units); do
        systemctl start "$u" >/dev/null 2>&1 || true
    done
    echo "Tunnels started (the quota guard will stop them again if the limit is still exceeded)."
    return 0
}

reset_usage() {
    if ask_yn "Reset all usage counters to zero?" n; then
        rm -f "$USAGE_DIR"/*.state
        echo "Counters reset."
    fi
    return 0
}

idle_test() {
    local iface secs=30 r1 t1 r2 t2 n1 n2 din dout total rate perday
    iface=$(detect_default_iface)
    if [ ! -r "/sys/class/net/${iface}/statistics/rx_bytes" ]; then
        echo "Cannot read the counters of interface ${iface}."
        return 0
    fi
    echo ""
    echo "Idle traffic test on ${iface}."
    echo "For a meaningful result, stop/disconnect all real users and apps first, so that only the"
    echo "tunnel itself is running. A healthy idle tunnel moves only a few hundred bytes per second."
    read -p "Press Enter to measure for ${secs}s (Ctrl+C to cancel) " _
    r1=$(cat "/sys/class/net/${iface}/statistics/rx_bytes")
    t1=$(cat "/sys/class/net/${iface}/statistics/tx_bytes")
    n1=$(sum_restarts)
    echo "Measuring..."
    sleep "$secs"
    r2=$(cat "/sys/class/net/${iface}/statistics/rx_bytes")
    t2=$(cat "/sys/class/net/${iface}/statistics/tx_bytes")
    n2=$(sum_restarts)

    din=$((r2 - r1))
    dout=$((t2 - t1))
    total=$((din + dout))
    rate=$((total / secs))
    perday=$((rate * 86400))

    echo ""
    echo "Received : $(fmt_bytes "$din")    Sent: $(fmt_bytes "$dout")    (in ${secs}s)"
    echo "Rate     : $(fmt_bytes "$rate")/s  =  $(fmt_bytes "$perday") per day if it stayed like this"
    echo "Tunnel auto-restarts during the test: $((n2 - n1))"
    if [ "$rate" -gt 5120 ] || [ $((n2 - n1)) -gt 0 ]; then
        echo ""
        echo ">> That is more than an idle tunnel should need. Things to check:"
        echo "   - reconnect loop?   menu 2 (auto-restarts column) and: journalctl -u 'backhaul-*' -n 50"
        echo "   - other processes?  nethogs ${iface}   or   iftop -i ${iface}   (apt install nethogs iftop)"
        echo "   - scanners / probes on the public inbound ports of the Iran server:  ss -tn state established | wc -l"
        echo "   - IPv6 tunnel flapping? check that the IPv6 route/firewall is stable and the tunnel port is open"
    else
        echo ""
        echo ">> Idle overhead looks fine. If the monthly total is still high, the data is real traffic"
        echo "   (users, updates, torrents, scanners hitting your inbound ports) rather than tunnel overhead."
    fi
    return 0
}

usage_menu() {
    local c
    while true; do
        echo ""
        echo "=== Data usage & limits ==="
        echo "1) Show usage this month"
        echo "2) Idle traffic test (is the tunnel itself wasting data?)"
        echo "3) Set / change monthly quota guard"
        echo "4) Resume tunnels stopped by the quota guard"
        echo "5) Reset usage counters"
        echo "6) Install / repair usage monitor"
        echo "0) Back"
        read -p "Select: " c
        case "$c" in
            1) show_usage ;;
            2) idle_test ;;
            3) set_quota ;;
            4) resume_tunnels ;;
            5) reset_usage ;;
            6) setup_usage_monitor ;;
            0) return 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ============================================================
# Apply the data-saver fixes to tunnels that already exist
# ============================================================

apply_fixes() {
    local u toml unit_file n=0
    echo ""
    echo "=== Apply data-saver fixes to existing tunnels ==="
    echo "This will:"
    echo "  - client configs : aggressive_pool=false, retry_interval=3   (no constant re-dialing / TLS handshakes)"
    echo "  - systemd units  : RestartSec=5 (was 1), StartLimitIntervalSec=0 in [Unit], IPAccounting=yes"
    echo "  - kernel profile : 32 MB buffers, tcp_retries2=8, invalid sysctl keys removed"
    echo "  - watchdog       : restart-storm protection (re-installed if present)"
    echo "  - usage monitor  : monthly counters per tunnel + whole server"
    echo "Tokens, ports, IPs and transports are NOT touched."
    if ! ask_yn "Continue?" y; then
        echo "Cancelled."
        return 0
    fi

    for u in $(list_tunnel_units); do
        unit_file="/etc/systemd/system/${u}"
        toml=$(grep -oE '/root/backhaul-core/[a-zA-Z0-9_.-]+\.toml' "$unit_file" 2>/dev/null | head -n1 || true)
        if [ -n "$toml" ] && [ -f "$toml" ]; then
            sed -i -E 's/^aggressive_pool[[:space:]]*=.*/aggressive_pool = false/; s/^retry_interval[[:space:]]*=.*/retry_interval = 3/' "$toml"
        fi
        if [ -f "$unit_file" ]; then
            sed -i -E 's/^RestartSec=.*/RestartSec=5/' "$unit_file"
            # StartLimitIntervalSec is only valid in [Unit]; in [Service] systemd ignores it.
            sed -i '/^StartLimitIntervalSec=/d' "$unit_file"
            sed -i 's/^\[Unit\]/[Unit]\nStartLimitIntervalSec=0/' "$unit_file"
            if ! grep -q '^IPAccounting=' "$unit_file"; then
                sed -i 's/^\[Service\]/[Service]\nIPAccounting=yes/' "$unit_file"
            fi
        fi
        n=$((n + 1))
        echo "  patched: $u"
    done
    if [ "$n" -eq 0 ]; then
        echo "  (no tunnel services found on this server — only the system parts are applied)"
    fi

    systemctl daemon-reload
    tune_sysctl

    if [ -f "$WATCHDOG_SCRIPT" ]; then
        setup_watchdog
    elif ask_yn "Install the watchdog (auto-restart on dead/idle tunnel, with restart-storm protection)?" n; then
        setup_watchdog
    fi
    setup_usage_monitor

    if [ "$n" -gt 0 ] && ask_yn "Restart the ${n} tunnel(s) now so the new settings take effect? (connections drop for a few seconds)" y; then
        for u in $(list_tunnel_units); do
            systemctl restart "$u" >/dev/null 2>&1 || true
        done
        echo "Tunnels restarted."
    fi

    echo ""
    echo "Done. Next steps:"
    echo "  1) Do the same on the other server (Iran <-> Kharej): both sides run their own client/server config."
    echo "  2) Wait ~1 hour, then check menu 7 > Show usage; use 'Idle traffic test' to see the tunnel's own overhead."
    return 0
}

# ============================================================
# Status
# ============================================================

show_status() {
    local units tunnel_units u toml addr state warn found_warning nrest

    units=$(list_backhaul_units)
    tunnel_units=$(list_tunnel_units)

    if [ -n "$tunnel_units" ]; then
        echo ""
        echo "=== Tunnel summary (service / state / auto-restarts / address) ==="
        for u in $tunnel_units; do
            toml=$(grep -oE '/root/backhaul-core/[a-zA-Z0-9_.-]+\.toml' "/etc/systemd/system/${u}" 2>/dev/null | head -n1 || true)
            addr=""
            if [ -n "$toml" ]; then
                addr=$(grep -E '^(bind_addr|remote_addr)' "$toml" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)
            fi
            state=$(systemctl is-active "$u" 2>/dev/null || true)
            nrest=$(systemctl show -p NRestarts --value "$u" 2>/dev/null || true)
            printf '%-50s %-9s %-6s %s\n' "$u" "$state" "${nrest:--}" "$addr"
        done
        echo "(auto-restarts = how many times systemd had to restart the service since it was started."
        echo " A large or fast-growing number means a crash/reconnect loop, which wastes data.)"
    fi

    echo ""
    echo "=== Backhaul services ==="
    if [ -z "$units" ]; then
        echo "No Backhaul services found."
    else
        for u in $units; do
            echo "--- $u ---"
            systemctl status "$u" --no-pager -l | head -n 6 || true
            echo ""
        done
    fi

    echo "=== Recent warnings (token mismatch / connection issues) ==="
    found_warning=0
    for u in $tunnel_units; do
        warn=$(journalctl -u "$u" -n 20 --no-pager 2>/dev/null | grep -iE "invalid security token|error|failed|unreachable|refused" | tail -n 3 || true)
        if [ -n "$warn" ]; then
            found_warning=1
            echo "--- $u ---"
            echo "$warn"
        fi
    done
    if [ "$found_warning" = "0" ]; then
        echo "None found in the last 20 log lines of each service."
    else
        echo ""
        echo "If you see 'invalid security token', the token in the .toml files on the"
        echo "two servers does not match — check with: grep token ${INSTALL_DIR}/*.toml"
        echo "If you see 'network is unreachable' on an IPv6 tunnel, the server has no working IPv6 route"
        echo "(or the IPv6 firewall blocks the tunnel port)."
    fi

    if [ -f "$QUOTA_LOCK" ]; then
        echo ""
        echo "!! The monthly quota guard has stopped the tunnels (menu 7 > Resume tunnels)."
    fi

    if [ -f "$WATCHDOG_LOG" ]; then
        echo ""
        echo "=== Last 10 watchdog / quota events ==="
        tail -n 10 "$WATCHDOG_LOG"
    fi
    return 0
}

# ============================================================
# Manage inbound ports (Iran server side only)
# ============================================================

manage_ports() {
    local tomls TOML_FILE PCHOICE SERVICE_NAME NEWPORT OLDPORT p i found line_no end_line tmp
    local -a CUR_PORTS=() NEW_PORTS=()

    tomls=$(ls "$INSTALL_DIR"/iran*.toml 2>/dev/null || true)
    if [ -z "$tomls" ]; then
        echo "No Iran server config found on this machine. Run this on the Iran server."
        return
    fi

    echo "Found config(s):"
    select TOML_FILE in $tomls; do
        [ -n "$TOML_FILE" ] && break
        echo "Invalid selection."
    done

    mapfile -t CUR_PORTS < <(sed -n '/^ports = \[/,/^\]/p' "$TOML_FILE" | grep -oE '"[^"]+"' | tr -d '"')

    echo ""
    echo "Current ports:"
    for p in "${CUR_PORTS[@]}"; do
        echo "  - $p"
    done

    echo ""
    echo "1) Add a port"
    echo "2) Remove a port"
    read -p "Choice [1-2]: " PCHOICE

    SERVICE_NAME="backhaul-$(basename "$TOML_FILE" .toml).service"

    if [ "$PCHOICE" = "1" ]; then
        read -p "Port to add (e.g. 443, 443=8443, 1000-1010): " NEWPORT
        if [ -z "$NEWPORT" ]; then
            echo "Nothing entered."
            return
        fi
        CUR_PORTS+=("$NEWPORT")
        echo "Added port ${NEWPORT}."
    elif [ "$PCHOICE" = "2" ]; then
        read -p "Port entry to remove (exactly as listed above): " OLDPORT
        found=0
        for p in "${CUR_PORTS[@]}"; do
            if [ "$p" = "$OLDPORT" ]; then
                found=1
            else
                NEW_PORTS+=("$p")
            fi
        done
        if [ "$found" = "0" ]; then
            echo "Port entry '${OLDPORT}' not found."
            return
        fi
        if [ "${#NEW_PORTS[@]}" -eq 0 ]; then
            echo "Cannot remove the last port — Backhaul needs at least one. Use the service menu to delete the tunnel instead."
            return
        fi
        CUR_PORTS=("${NEW_PORTS[@]}")
        echo "Removed port ${OLDPORT}."
    else
        echo "Invalid choice."
        return
    fi

    # Rebuild only the ports = [ ... ] block; everything else in the file is preserved.
    line_no=$(grep -n '^ports = \[' "$TOML_FILE" | head -n1 | cut -d: -f1)
    if [ -z "$line_no" ]; then
        echo "Could not find the 'ports = [' block in $TOML_FILE — nothing changed."
        return
    fi
    end_line=$(awk -v s="$line_no" 'NR>s && /^\]/ {print NR; exit}' "$TOML_FILE")
    [ -z "$end_line" ] && end_line="$line_no"

    tmp="${TOML_FILE}.tmp"
    head -n $((line_no - 1)) "$TOML_FILE" > "$tmp"
    {
        echo "ports = ["
        for i in "${!CUR_PORTS[@]}"; do
            if [ $((i+1)) -eq ${#CUR_PORTS[@]} ]; then
                echo "    \"${CUR_PORTS[i]}\""
            else
                echo "    \"${CUR_PORTS[i]}\","
            fi
        done
        echo "]"
    } >> "$tmp"
    tail -n +$((end_line + 1)) "$TOML_FILE" >> "$tmp"
    mv "$tmp" "$TOML_FILE"

    systemctl restart "$SERVICE_NAME"
    echo "Restarted $SERVICE_NAME."
}

# ============================================================
# Service management (start/stop/restart/logs/enable/disable/edit)
# ============================================================

manage_services() {
    local units SERVICE_NAME TOML_FILE SCHOICE
    units=$(list_tunnel_units)
    if [ -z "$units" ]; then
        echo "No Backhaul tunnel services found on this server."
        return
    fi

    echo ""
    echo "Select a service to manage:"
    select SERVICE_NAME in $units; do
        [ -n "$SERVICE_NAME" ] && break
        echo "Invalid selection."
    done

    TOML_FILE=$(grep -oE '/root/backhaul-core/[a-zA-Z0-9_.-]+\.toml' "/etc/systemd/system/${SERVICE_NAME}" | head -n1)

    while true; do
        echo ""
        echo "=== $SERVICE_NAME ==="
        systemctl is-active --quiet "$SERVICE_NAME" && echo "Status: RUNNING" || echo "Status: STOPPED"
        systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && echo "Auto-start: enabled" || echo "Auto-start: disabled"
        echo ""
        echo "1) Start"
        echo "2) Stop"
        echo "3) Restart"
        echo "4) Full status"
        echo "5) Live logs (Ctrl+C to exit)"
        echo "6) Enable auto-start"
        echo "7) Disable auto-start"
        echo "8) View config"
        echo "9) Edit config"
        echo "10) Delete this service"
        echo "0) Back"
        read -p "Select: " SCHOICE
        case "$SCHOICE" in
            1) systemctl start "$SERVICE_NAME"; echo "Started." ;;
            2) systemctl stop "$SERVICE_NAME"; echo "Stopped (the watchdog leaves stopped services alone)." ;;
            3) systemctl restart "$SERVICE_NAME"; echo "Restarted." ;;
            4) systemctl status "$SERVICE_NAME" --no-pager -l ;;
            5) journalctl -u "$SERVICE_NAME" -f ;;
            6) systemctl enable "$SERVICE_NAME"; echo "Enabled." ;;
            7) systemctl disable "$SERVICE_NAME"; echo "Disabled." ;;
            8) if [ -n "$TOML_FILE" ]; then cat "$TOML_FILE"; else echo "Config path not found."; fi ;;
            9) if [ -n "$TOML_FILE" ]; then
                   ${EDITOR:-nano} "$TOML_FILE"
                   if ask_yn "Restart service to apply changes?" y; then
                       systemctl restart "$SERVICE_NAME"
                       echo "Restarted."
                   fi
               else
                   echo "Config path not found."
               fi ;;
            10) if ask_yn "Delete $SERVICE_NAME and its config?" n; then
                    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
                    rm -f "/etc/systemd/system/${SERVICE_NAME}"
                    [ -n "$TOML_FILE" ] && rm -f "$TOML_FILE"
                    systemctl daemon-reload
                    echo "Deleted."
                    return
                fi ;;
            0) return ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ============================================================
# Uninstall
# ============================================================

uninstall_all() {
    local units u
    if ! ask_yn "This will remove ALL Backhaul services (including watchdog/usage/MTU units) on THIS server. Continue?" n; then
        echo "Cancelled."
        return
    fi

    units=$(list_backhaul_units)
    for u in $units; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done
    systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1 || true
    systemctl disable --now backhaul-usage.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/backhaul-watchdog.timer /etc/systemd/system/backhaul-watchdog.service
    rm -f /etc/systemd/system/backhaul-usage.timer /etc/systemd/system/backhaul-usage.service

    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    echo "Uninstalled. (Note: MTU/DNS/sysctl/IPv6 system tuning was left in place — re-run and choose"
    echo "the optimizer options manually to revert those if needed.)"
}

# ============================================================
# Install: shared pieces
# ============================================================

write_service() {
    # $1 = unit name (without .service), $2 = description, $3 = toml path
    # RestartSec=5 (was 1): a crashing / unreachable tunnel must not re-dial and re-handshake every second.
    # StartLimitIntervalSec belongs in [Unit] (systemd ignores it in [Service]).
    cat > "/etc/systemd/system/$1.service" << EOF
[Unit]
Description=$2
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c $3
Restart=always
RestartSec=5
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-1000
IPAccounting=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_client_toml() {
    # $1 = toml path, $2 = remote_addr (already formatted, IPv6 in [])
    # aggressive_pool=false / retry_interval=3 are the official defaults: aggressive pool refilling
    # and 1-second retries mean constant new (TLS) connections whenever the link hiccups.
    cat > "$1" << EOF
[client]
remote_addr = "$2"
transport = "${TRANSPORT}"
token = "${TOKEN}"
connection_pool = 8
aggressive_pool = false
keepalive_period = 20
nodelay = true
retry_interval = 3
sniffer = false
web_port = 0
log_level = "warn"
EOF
}

# ============================================================
# Install: Iran server side
# ============================================================

setup_iran_server() {
    local bind_addr guess public_ip default_port port i
    local -a PORT_ARRAY=()

    # --- IP version of the tunnel listener ---
    while true; do
        echo ""
        echo "(IPv4 listens on 0.0.0.0:PORT. IPv6 listens on [::]:PORT, which normally accepts"
        echo " BOTH IPv6 and IPv4 Kharej clients, so IPv6 is the most flexible choice.)"
        ask_ip_version "Which IP version should the tunnel use on this Iran server?"
        if [ "$IP_MODE" = "6" ]; then
            if prepare_ipv6; then
                break
            fi
            echo "Pick again."
        else
            break
        fi
    done

    if [ "$IP_MODE" = "6" ]; then
        guess=$(detect_public_ip6)
    else
        guess=$(detect_public_ip)
    fi
    read -p "This Iran server's public IPv${IP_MODE} (shown to you for the Kharej setup) [${guess}]: " public_ip
    public_ip=${public_ip:-$guess}
    public_ip=$(clean_ip_input "$public_ip")

    # --- Tunnel port ---
    default_port=$(gen_port)
    while true; do
        read -p "Tunnel port [${default_port}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$default_port}
        if valid_port "$TUNNEL_PORT"; then
            break
        fi
        echo "Invalid port (1-65535)."
    done

    # --- Inbound (user-facing) ports ---
    while true; do
        read -p "Inbound ports on this Iran server (comma separated, e.g. 2050,2023): " INBOUND_PORTS
        if [ -n "${INBOUND_PORTS// /}" ]; then
            break
        fi
        echo "Enter at least one port."
    done

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        ensure_tls_cert_local
    fi

    if [ "$IP_MODE" = "6" ]; then
        bind_addr="[::]:${TUNNEL_PORT}"
    else
        bind_addr="0.0.0.0:${TUNNEL_PORT}"
    fi

    TOML_FILE="$INSTALL_DIR/iran${TUNNEL_PORT}.toml"
    {
        echo "[server]"
        echo "bind_addr = \"${bind_addr}\""
        echo "transport = \"${TRANSPORT}\""
        echo "token = \"${TOKEN}\""
        echo "keepalive_period = 20"
        echo "nodelay = true"
        echo "channel_size = 16384"
        echo "heartbeat = 15"
        echo "mux_con = 8"
        if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
            echo "tls_cert = \"${INSTALL_DIR}/server.crt\""
            echo "tls_key = \"${INSTALL_DIR}/server.key\""
        fi
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"warn\""
        echo ""
        echo "ports = ["
    } > "$TOML_FILE"
    IFS=',' read -ra PORT_ARRAY <<< "$INBOUND_PORTS"
    for i in "${!PORT_ARRAY[@]}"; do
        port=$(echo "${PORT_ARRAY[i]}" | xargs)
        if [ $((i+1)) -eq ${#PORT_ARRAY[@]} ]; then
            echo "    \"${port}\"" >> "$TOML_FILE"
        else
            echo "    \"${port}\"," >> "$TOML_FILE"
        fi
    done
    echo "]" >> "$TOML_FILE"

    write_service "backhaul-iran${TUNNEL_PORT}" "Backhaul Iran Server Port ${TUNNEL_PORT}" "$TOML_FILE"
    systemctl daemon-reload
    systemctl enable --now "backhaul-iran${TUNNEL_PORT}.service"
    echo "Local Backhaul (Iran server side) started, listening on ${bind_addr}."

    sleep 1
    if ss -H -ltn "( sport = :${TUNNEL_PORT} )" 2>/dev/null | grep -q .; then
        echo "Check: tunnel port ${TUNNEL_PORT} is listening."
    else
        echo "Warning: nothing is listening on tunnel port ${TUNNEL_PORT} yet — see: journalctl -u backhaul-iran${TUNNEL_PORT} -n 30"
    fi

    cat > "$STATE_FILE" << EOF
LOCAL_ROLE=Iran
TRANSPORT=${TRANSPORT}
IP_VERSION=${IP_MODE}
BIND_ADDR=${bind_addr}
TUNNEL_PORT=${TUNNEL_PORT}
PUBLIC_IP=${public_ip}
EOF

    echo ""
    echo ">>> When you run this script on the Kharej server, add THIS Iran server with:"
    echo "      IP version  : IPv${IP_MODE}"
    echo "      Address     : ${public_ip}"
    echo "      Tunnel port : ${TUNNEL_PORT}"
    echo "      Transport   : ${TRANSPORT}   (choose the same transport on the Kharej server)"
    echo ">>> Make sure the firewall allows TCP ${TUNNEL_PORT}$([ "$IP_MODE" = "6" ] && echo " for IPv6 as well (ip6tables / ufw with IPV6=yes)")."
    echo ">>> Using several Iran servers? Run this script on each of them, then list them all on the Kharej server."
}

# ============================================================
# Install: Kharej client side (one or many Iran servers)
# ============================================================

setup_kharej_clients() {
    local count i k ip port prev_port="" dup addr tag name toml
    local -a IPS=() PORTS=() SVCS=() TARGETS=()

    echo ""
    echo "This Kharej server can be tunnelled to several Iran servers at the same time"
    echo "(one Backhaul client service is created per Iran server)."
    while true; do
        read -p "How many Iran servers should this Kharej server connect to? [1]: " count
        count=${count:-1}
        if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge 1 ] && [ "$count" -le 20 ]; then
            break
        fi
        echo "Enter a number between 1 and 20."
    done

    for ((i=1; i<=count; i++)); do
        echo ""
        echo "==== Iran server #${i} of ${count} ===="
        while true; do
            ask_ip_version "Connect to Iran server #${i} over:"
            if [ "$IP_MODE" = "6" ] && ! prepare_ipv6; then
                echo "Pick again."
                continue
            fi

            # address (must match the chosen IP version)
            while true; do
                read -p "Iran server #${i} public IPv${IP_MODE} address: " ip
                ip=$(clean_ip_input "$ip")
                if [ "$IP_MODE" = "6" ]; then
                    if valid_ipv6 "$ip"; then break; fi
                    echo "Not a valid IPv6 address (example: 2001:db8::10)."
                else
                    if valid_ipv4 "$ip"; then break; fi
                    echo "Not a valid IPv4 address (example: 203.0.113.10)."
                fi
            done

            # tunnel port of THAT Iran server (default: the previous server's port)
            while true; do
                read -p "Tunnel port of Iran server #${i} [${prev_port}]: " port
                port=${port:-$prev_port}
                if valid_port "$port"; then break; fi
                echo "Invalid port (1-65535) — use the tunnel port shown when you set up that Iran server."
            done

            dup=0
            for k in "${!IPS[@]}"; do
                if [ "${IPS[k]}" = "$ip" ] && [ "${PORTS[k]}" = "$port" ]; then
                    dup=1
                fi
            done
            if [ "$dup" = "1" ]; then
                echo "That Iran server (same address and port) was already added — enter a different one."
                continue
            fi
            break
        done

        if check_reachable "$ip" "$port"; then
            echo "  OK: $(format_hostport "$ip" "$port") is reachable."
        else
            echo "  Warning: $(format_hostport "$ip" "$port") is not reachable right now."
            echo "           (Iran side not set up yet, firewall, or wrong IP version? The client keeps retrying every few seconds.)"
        fi

        IPS+=("$ip")
        PORTS+=("$port")
        prev_port="$port"
    done

    # --- create one client service per Iran server ---
    for k in "${!IPS[@]}"; do
        ip="${IPS[k]}"
        port="${PORTS[k]}"
        addr=$(format_hostport "$ip" "$port")
        tag=$(make_tag "$ip")
        name="kharej-${tag}-${port}"
        toml="$INSTALL_DIR/${name}.toml"

        write_client_toml "$toml" "$addr"
        write_service "backhaul-${name}" "Backhaul Kharej Client to ${addr}" "$toml"
        SVCS+=("backhaul-${name}.service")
        TARGETS+=("$addr")
    done

    systemctl daemon-reload
    for k in "${!SVCS[@]}"; do
        systemctl enable --now "${SVCS[k]}" >/dev/null 2>&1
    done

    echo ""
    echo "Kharej client services started (one per Iran server):"
    for k in "${!SVCS[@]}"; do
        echo "  ${SVCS[k]}  ->  ${TARGETS[k]}"
    done

    cat > "$STATE_FILE" << EOF
LOCAL_ROLE=Kharej
TRANSPORT=${TRANSPORT}
IRAN_SERVERS="${TARGETS[*]}"
EOF

    TUNNEL_PORT="${PORTS[*]}"
}

# ============================================================
# Install
# ============================================================

install_flow() {
    mkdir -p "$INSTALL_DIR"
    echo ""
    echo "Are you setting up the Iran server or the Kharej server?"
    select LOCAL_ROLE in "Iran" "Kharej"; do
        case $LOCAL_ROLE in
            Iran|Kharej) break;;
            *) echo "Invalid selection.";;
        esac
    done

    echo ""
    echo "Choose transport (must be the SAME on the Iran server(s) and the Kharej server):"
    echo "  1) wss     - TLS encrypted, looks like HTTPS to firewalls (recommended)"
    echo "  2) wssmux  - wss + multiplexing: many user connections share a few tunnel connections,"
    echo "               so no TLS handshake per user connection (less overhead for many small connections)"
    echo "  3) tcp     - plain TCP, fastest but not encrypted or disguised"
    echo "  4) tcpmux  - tcp + multiplexing"
    read -p "Enter choice [1-4] (default 1): " TRANSPORT_CHOICE
    case "$TRANSPORT_CHOICE" in
        2) TRANSPORT="wssmux" ;;
        3) TRANSPORT="tcp" ;;
        4) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="wss" ;;
    esac

    # Token is fixed (as requested) — same on every server, no prompt needed.
    # NOTE: this is much weaker than a random token. Anyone who guesses/knows
    # "123" can authenticate to your tunnel. Fine for quick testing; for anything real run e.g.
    #   BACKHAUL_TOKEN=$(openssl rand -hex 16) ./this-script.sh     (and use the SAME value on the other server)
    TOKEN="$FIXED_TOKEN"

    ensure_backhaul_local

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        setup_iran_server
    else
        setup_kharej_clients
    fi

    echo ""
    echo "=== Setup Completed! ==="
    echo "Role: $LOCAL_ROLE   Transport: $TRANSPORT   Tunnel port(s): $TUNNEL_PORT"
    echo "Token: $TOKEN"
    echo "Check: systemctl status 'backhaul-*'   (or menu option 2)"
    if [ "$TOKEN" = "123" ]; then
        echo "(Reminder: token is the fixed value '123' — fine for testing, weak for production.)"
    fi

    if ask_yn "Run system optimizer now (BBR, buffers, MTU, DNS, ulimits)?" n; then
        optimize_system
    fi

    if ask_yn "Install the watchdog (auto-restart on dead/idle tunnel)?" n; then
        setup_watchdog
    fi

    if ask_yn "Install the usage monitor (monthly data counters + optional quota guard)?" y; then
        setup_usage_monitor
    fi
}

# ============================================================
# Menu
# ============================================================

while true; do
    echo ""
    echo "==== Backhaul Tunnel Manager (v9) ===="
    echo "1) Install / Setup tunnel (IPv4/IPv6, Kharej: multiple Iran servers)"
    echo "2) Show tunnel status"
    echo "3) Manage inbound ports (Iran side)"
    echo "4) Manage services (start/stop/restart/logs/edit)"
    echo "5) System optimizer (kernel profile + MTU + DNS + ulimits)"
    echo "6) Install/repair Watchdog (auto-restart on dead/idle tunnel)"
    echo "7) Data usage & limits (counters / idle test / monthly quota)"
    echo "8) Apply data-saver fixes to existing tunnels"
    echo "9) Uninstall tunnel"
    echo "0) Exit"
    read -p "Select an option [0-9]: " CHOICE
    case "$CHOICE" in
        1) install_flow ;;
        2) show_status ;;
        3) manage_ports ;;
        4) manage_services ;;
        5) optimize_system ;;
        6) setup_watchdog ;;
        7) usage_menu ;;
        8) apply_fixes ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
