#!/bin/bash

# Backhaul Tunnel Manager (Iran <-> Kharej) — v9 Low-Traffic
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding (wss/wssmux).
#
# v9 changes vs v8:
#   - IPv6 tunnel link: the tunnel between Iran server and Kharej client can now run over
#     IPv4 OR IPv6 (you are asked during setup).
#         Iran server  : bind_addr   = "0.0.0.0:PORT"   (IPv4)   or   "[::]:PORT"   (IPv6, dual-stack)
#         Kharej client: remote_addr = "IP:PORT"        (IPv4)   or   "[IPv6]:PORT"
#   - Multiple Iran servers: when setting up the Kharej server the script asks how many Iran
#     servers you have, then for EACH one asks IPv4/IPv6, the address and the tunnel port.
#     One client service is created per Iran server, so the Kharej server is tunnelled to
#     all of them at the same time.
#   - Watchdog is IPv6-aware and now matches connections by the service's own PID, so several
#     tunnels on the same machine (even with the same port number) can't mask each other.
#   - Fixes: "n" at the final prompts no longer exits the script (set -e), optimizer can be
#     re-run (resolv.conf immutable flag), "Manage inbound ports" no longer corrupts the
#     [server] header, service lists no longer break on the "●" bullet.
#
# Run this SEPARATELY on each server (every Iran server + the Kharej server).
# Order: set up the Iran server(s) first, note their IP / tunnel port, then run the Kharej setup.

set -e

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
STATE_FILE="$INSTALL_DIR/state.env"
FIXED_TOKEN="123"
WATCHDOG_SCRIPT="$INSTALL_DIR/watchdog.sh"
WATCHDOG_LOG="$INSTALL_DIR/watchdog.log"
WATCHDOG_STATE_DIR="$INSTALL_DIR/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=0

# Low-overhead tunnel defaults
CLIENT_POOL=1
CLIENT_AGGRESSIVE_POOL=false
KEEPALIVE_PERIOD=30
RETRY_INTERVAL=2
SERVER_HEARTBEAT=30
SERVER_MUX_CON=1

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
    iface=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
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
    systemctl list-units --all --plain --no-legend 'backhaul-*.service' 2>/dev/null | awk '{print $1}'
}

list_tunnel_units() {
    # tunnel services only (no MTU / watchdog helper units)
    list_backhaul_units | grep -vE '^backhaul-(mtu|watchdog)\.service$' || true
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
    sysctl -w fs.file-max=2097152 > /dev/null 2>&1

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
# System Optimizer (BBR + network sysctl tuning + MTU + DNS + ulimits)
# ============================================================

optimize_system() {
    echo ""
    echo "=== System Optimization ==="
    local INTERFACE
    INTERFACE=$(detect_default_iface)
    echo "Interface: $INTERFACE"

    sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1 && echo "BBR congestion control enabled." \
        || echo "BBR module not available on this kernel — staying on the default (usually CUBIC)."

    sysctl -w net.core.somaxconn=65535 > /dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog=250000 > /dev/null 2>&1
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" > /dev/null 2>&1

    sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
    sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_keepalive_time=60 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=6 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_user_timeout=30000 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_fin_timeout=15 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 > /dev/null 2>&1

    # Kept from the original profile — not superseded by the new list.
    # (net.ipv4.tcp_* settings apply to IPv6 TCP sockets too.)
    sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_sack=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_retries2=6 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_syn_retries=2 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_low_latency=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_no_metrics_save=1 > /dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    # Deliberately NOT set (can backfire on newer kernels / behind NAT-CGNAT):
    #   net.ipv4.tcp_tw_recycle   (removed in modern kernels)
    #   net.ipv4.tcp_tw_reuse=1   (can break behind NAT/CGNAT)
    # Deliberately NOT set: net.ipv6.conf.all.forwarding (would stop the host accepting
    # IPv6 router advertisements and can silently kill its IPv6 connectivity).

    cat > /etc/sysctl.d/99-backhaul-tunnel.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.ip_local_port_range=1024 65535
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_user_timeout=30000
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_retries2=6
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.ip_forward=1
EOF
    echo "Saved to /etc/sysctl.d/99-backhaul-tunnel.conf (persists across reboots)."

    ensure_ulimits
    ensure_mtu
    ensure_dns

    echo ""
    echo "Optimization complete."
}

# ============================================================
# Watchdog (health check + auto-restart)
# ============================================================

setup_watchdog() {
    echo ""
    echo "=== Installing Watchdog ==="
    mkdir -p "$WATCHDOG_STATE_DIR"

    cat > "$WATCHDOG_SCRIPT" << 'WDEOF'
#!/bin/bash
# Backhaul watchdog — runs every 15s via backhaul-watchdog.timer.
# IMPORTANT: an idle tunnel is NOT a failed tunnel. We no longer restart a healthy
# service merely because it has zero established user connections. That behavior
# caused repeated TLS/handshake/reconnect traffic and unnecessary data usage.
# The watchdog now restarts only inactive/crashed services; systemd handles the
# normal process restart policy as well.

INSTALL_DIR="/root/backhaul-core"
STATE_DIR="$INSTALL_DIR/watchdog-state"
LOG_FILE="$INSTALL_DIR/watchdog.log"
IDLE_THRESHOLD=0

mkdir -p "$STATE_DIR"

for unit in $(systemctl list-units --all --plain --no-legend 'backhaul-*.service' 2>/dev/null | awk '{print $1}'); do
    case "$unit" in
        backhaul-mtu.service|backhaul-watchdog.service) continue ;;
    esac

    if ! systemctl is-active --quiet "$unit"; then
        systemctl restart "$unit" 2>/dev/null
        echo "$(date '+%F %T') restarted $unit (service was inactive)" >> "$LOG_FILE"
        rm -f "${STATE_DIR}/${unit}.last_ok"
        continue
    fi

    # Do NOT inspect established connections here. A completely idle tunnel is
    # normal and restarting it creates needless reconnect/handshake traffic.
    pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
    if [ -z "$pid" ] || [ "$pid" = "0" ] || ! kill -0 "$pid" 2>/dev/null; then
        systemctl restart "$unit" 2>/dev/null || true
        echo "$(date '+%F %T') restarted $unit (missing/dead main process)" >> "$LOG_FILE"
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
Description=Run Backhaul Watchdog every 15 seconds

[Timer]
OnBootSec=20
OnUnitActiveSec=15
AccuracySec=1
Unit=backhaul-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-watchdog.timer >/dev/null 2>&1
    echo "Watchdog installed — checks every 15s and restarts only crashed/inactive tunnel processes (idle tunnels are left alone)."
    echo "Log: $WATCHDOG_LOG"
}

# ============================================================
# Status
# ============================================================

show_status() {
    local units tunnel_units u toml addr state warn found_warning

    units=$(list_backhaul_units)
    tunnel_units=$(list_tunnel_units)

    if [ -n "$tunnel_units" ]; then
        echo ""
        echo "=== Tunnel summary (service / state / address) ==="
        for u in $tunnel_units; do
            toml=$(grep -oE '/root/backhaul-core/[a-zA-Z0-9_.-]+\.toml' "/etc/systemd/system/${u}" 2>/dev/null | head -n1)
            addr=""
            [ -n "$toml" ] && addr=$(grep -E '^(bind_addr|remote_addr)' "$toml" 2>/dev/null | head -n1 | cut -d'"' -f2)
            state=$(systemctl is-active "$u" 2>/dev/null || true)
            printf '%-55s %-10s %s\n' "$u" "$state" "$addr"
        done
    fi

    echo ""
    echo "=== Backhaul services ==="
    if [ -z "$units" ]; then
        echo "No Backhaul services found."
    else
        for u in $units; do
            echo "--- $u ---"
            systemctl status "$u" --no-pager -l | head -n 6
            echo ""
        done
    fi

    echo "=== Recent warnings (token mismatch / connection issues) ==="
    found_warning=0
    for u in $tunnel_units; do
        warn=$(journalctl -u "$u" -n 20 --no-pager 2>/dev/null | grep -iE "invalid security token|error|failed|unreachable|refused" | tail -n 3)
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

    if [ -f "$WATCHDOG_LOG" ]; then
        echo ""
        echo "=== Last 10 watchdog restarts (process-health only) ==="
        tail -n 10 "$WATCHDOG_LOG"
    fi
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
            2) systemctl stop "$SERVICE_NAME"; echo "Stopped." ;;
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
    if ! ask_yn "This will remove ALL Backhaul services (including watchdog/MTU units) on THIS server. Continue?" n; then
        echo "Cancelled."
        return
    fi

    units=$(list_backhaul_units)
    for u in $units; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done
    systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/backhaul-watchdog.timer /etc/systemd/system/backhaul-watchdog.service

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
    cat > "/etc/systemd/system/$1.service" << EOF
[Unit]
Description=$2
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c $3
Restart=always
RestartSec=1
StartLimitIntervalSec=0
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-1000
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_client_toml() {
    # $1 = toml path, $2 = remote_addr (already formatted, IPv6 in [])
    cat > "$1" << EOF
[client]
remote_addr = "$2"
transport = "${TRANSPORT}"
token = "${TOKEN}"
connection_pool = ${CLIENT_POOL}
aggressive_pool = ${CLIENT_AGGRESSIVE_POOL}
keepalive_period = ${KEEPALIVE_PERIOD}
nodelay = true
retry_interval = ${RETRY_INTERVAL}
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
        echo "keepalive_period = ${KEEPALIVE_PERIOD}"
        echo "nodelay = true"
        echo "channel_size = 16384"
        echo "heartbeat = ${SERVER_HEARTBEAT}"
        echo "mux_con = ${SERVER_MUX_CON}"
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
    echo "Low-traffic mode: pool=1, aggressive_pool=false, keepalive=30s, retry=2s."
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
            echo "           (Iran side not set up yet, firewall, or wrong IP version? The client keeps retrying every second.)"
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
    echo "  2) wssmux  - wss + multiplexing, best for many concurrent connections / high throughput"
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
    # "123" can authenticate to your tunnel. Fine for quick testing, but
    # consider a random token (openssl rand -hex 24) for anything real.
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

    if ask_yn "Install the watchdog (restart only crashed/inactive tunnel)?" n; then
        setup_watchdog
    fi
}

# ============================================================
# Menu
# ============================================================

while true; do
    echo ""
    echo "==== Backhaul Tunnel Manager (v9 Low-Traffic) ===="
    echo "1) Install / Setup tunnel (IPv4/IPv6, Kharej: multiple Iran servers)"
    echo "2) Show tunnel status"
    echo "3) Manage inbound ports (Iran side)"
    echo "4) Manage services (start/stop/restart/logs/edit)"
    echo "5) System optimizer (BBR + buffers + MTU + DNS + ulimits)"
    echo "6) Install/repair Watchdog (restart only crashed/inactive tunnel)"
    echo "7) Uninstall tunnel"
    echo "8) Exit"
    read -p "Select an option [1-8]: " CHOICE
    case "$CHOICE" in
        1) install_flow ;;
        2) show_status ;;
        3) manage_ports ;;
        4) manage_services ;;
        5) optimize_system ;;
        6) setup_watchdog ;;
        7) uninstall_all ;;
        8) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
