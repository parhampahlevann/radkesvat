#!/bin/bash

# Backhaul Tunnel Manager (Iran <-> Kharej) — v7
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding (wss/wssmux).
#
# v7 changes vs v6:
#   - Rewritten sysctl profile (larger buffers/backlogs, BBR+fq, faster keepalive/timeouts)
#   - Tighter server/client tunnel config (faster heartbeat, bigger channel, aggressive pool)
#   - Hardened systemd unit (instant restart, no OOM kill, unlimited fds)
#   - New watchdog: checks every 10s per-service, restarts on inactive service OR
#     30s with zero established connections on the tunnel port
#   - MTU pinned to 1400 on the default interface, persisted via a oneshot systemd unit
#   - DNS pinned to 1.1.1.1 / 1.0.0.1 / 8.8.8.8 (static /etc/resolv.conf)
#   - System-wide file descriptor limits raised (fs.file-max + limits.conf)
#
# Run this SEPARATELY on each server (Iran and Kharej). No SSH auto-sync — keep it simple.

set -e

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
STATE_FILE="$INSTALL_DIR/state.env"
FIXED_TOKEN="123"
WATCHDOG_SCRIPT="$INSTALL_DIR/watchdog.sh"
WATCHDOG_LOG="$INSTALL_DIR/watchdog.log"
WATCHDOG_STATE_DIR="$INSTALL_DIR/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=30

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)."
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# ============================================================
# Helpers
# ============================================================

detect_public_ip() {
    curl -fsSL -4 https://ifconfig.me 2>/dev/null || curl -fsSL -4 https://api.ipify.org 2>/dev/null || echo ""
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
# Backhaul watchdog — runs every 10s via backhaul-watchdog.timer
# Restarts a service if:
#   1) it is not active, OR
#   2) it has been active but with zero established connections on its
#      tunnel port for WATCHDOG_IDLE_THRESHOLD seconds (link looks dead/hung).

INSTALL_DIR="/root/backhaul-core"
STATE_DIR="$INSTALL_DIR/watchdog-state"
LOG_FILE="$INSTALL_DIR/watchdog.log"
IDLE_THRESHOLD=30

mkdir -p "$STATE_DIR"

for unit in $(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}'); do
    case "$unit" in
        backhaul-mtu.service|backhaul-watchdog.service) continue ;;
    esac

    if ! systemctl is-active --quiet "$unit"; then
        systemctl restart "$unit" 2>/dev/null
        echo "$(date '+%F %T') restarted $unit (service was inactive)" >> "$LOG_FILE"
        rm -f "${STATE_DIR}/${unit}.last_ok"
        continue
    fi

    unit_file="/etc/systemd/system/${unit}"
    toml=$(grep -oE '/root/backhaul-core/[a-zA-Z0-9_.-]+\.toml' "$unit_file" 2>/dev/null | head -n1)
    [ -z "$toml" ] || [ ! -f "$toml" ] && continue

    port=""
    if grep -q '^\[server\]' "$toml" 2>/dev/null; then
        port=$(grep -oE 'bind_addr = "0\.0\.0\.0:[0-9]+"' "$toml" | grep -oE '[0-9]+$')
    else
        port=$(grep -oE 'remote_addr = "[^:"]+:[0-9]+"' "$toml" | grep -oE '[0-9]+$')
    fi
    [ -z "$port" ] && continue

    active_conns=$(ss -H -tn state established "( sport = :${port} or dport = :${port} )" 2>/dev/null | grep -c .)
    now=$(date +%s)
    state_file="${STATE_DIR}/${unit}.last_ok"

    if [ "${active_conns:-0}" -gt 0 ]; then
        echo "$now" > "$state_file"
    else
        last_ok=$(cat "$state_file" 2>/dev/null || echo "$now")
        idle=$(( now - last_ok ))
        if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
            systemctl restart "$unit" 2>/dev/null
            echo "$now" > "$state_file"
            echo "$(date '+%F %T') restarted $unit (idle ${idle}s, no established connections on port ${port})" >> "$LOG_FILE"
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
    echo "Watchdog installed — checks every 10s, restarts a tunnel after ${WATCHDOG_IDLE_THRESHOLD}s with no active connections."
    echo "Log: $WATCHDOG_LOG"
}

# ============================================================
# Status
# ============================================================

show_status() {
    echo ""
    echo "=== Backhaul services ==="
    local units
    units=$(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}')
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
    local found_warning=0
    for u in $units; do
        case "$u" in
            backhaul-mtu.service|backhaul-watchdog.service) continue ;;
        esac
        local warn
        warn=$(journalctl -u "$u" -n 20 --no-pager 2>/dev/null | grep -iE "invalid security token|error|failed" | tail -n 3)
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
    fi

    if [ -f "$WATCHDOG_LOG" ]; then
        echo ""
        echo "=== Last 10 watchdog restarts ==="
        tail -n 10 "$WATCHDOG_LOG"
    fi
}

# ============================================================
# Manage inbound ports (Iran server side only)
# ============================================================

manage_ports() {
    local tomls
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

    echo ""
    echo "Current ports:"
    sed -n '/ports = \[/,/\]/p' "$TOML_FILE"

    echo ""
    echo "1) Add a port"
    echo "2) Remove a port"
    read -p "Choice [1-2]: " PCHOICE

    PORT_NUM=$(basename "$TOML_FILE" | grep -oE '[0-9]+' | head -n1)
    SERVICE_NAME="backhaul-iran${PORT_NUM}.service"

    if [ "$PCHOICE" = "1" ]; then
        read -p "Port to add: " NEWPORT
        sed -i "s/\]/    \"${NEWPORT}\"\n]/" "$TOML_FILE"
        # normalize: ensure previous last line got a trailing comma
        python3 - "$TOML_FILE" << 'PYEOF' 2>/dev/null || true
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
lines = content.split("\n")
out = []
in_ports = False
port_lines_idx = []
for i, l in enumerate(lines):
    if 'ports = [' in l:
        in_ports = True
    if in_ports and l.strip().startswith('"'):
        port_lines_idx.append(i)
    if in_ports and l.strip() == ']':
        in_ports = False
for idx_pos, i in enumerate(port_lines_idx):
    l = lines[i].rstrip(',').rstrip()
    if idx_pos != len(port_lines_idx) - 1:
        lines[i] = l + ","
    else:
        lines[i] = l
with open(path, "w") as f:
    f.write("\n".join(lines))
PYEOF
        echo "Added port ${NEWPORT}."
    else
        read -p "Port to remove: " OLDPORT
        sed -i "/\"${OLDPORT}\"/d" "$TOML_FILE"
        echo "Removed port ${OLDPORT}."
    fi

    systemctl restart "$SERVICE_NAME"
    echo "Restarted $SERVICE_NAME."
}

# ============================================================
# Service management (start/stop/restart/logs/enable/disable/edit)
# ============================================================

manage_services() {
    local units
    units=$(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}' | grep -vE '^backhaul-(mtu|watchdog)\.service$')
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

    local TOML_FILE
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
            8) [ -n "$TOML_FILE" ] && cat "$TOML_FILE" || echo "Config path not found." ;;
            9) if [ -n "$TOML_FILE" ]; then
                   ${EDITOR:-nano} "$TOML_FILE"
                   read -p "Restart service to apply changes? (y/n): " R
                   [ "$R" = "y" ] && systemctl restart "$SERVICE_NAME" && echo "Restarted."
               else
                   echo "Config path not found."
               fi ;;
            10) read -p "Delete $SERVICE_NAME and its config? (y/n): " D
                if [ "$D" = "y" ]; then
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
    read -p "This will remove ALL Backhaul services (including watchdog/MTU units) on THIS server. Continue? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Cancelled."
        return
    fi

    local units
    units=$(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}')
    for u in $units; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done
    systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/backhaul-watchdog.timer /etc/systemd/system/backhaul-watchdog.service

    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    echo "Uninstalled. (Note: MTU/DNS/sysctl system tuning was left in place — re-run and choose"
    echo "the optimizer options manually to revert those if needed.)"
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

    LOCAL_PUBLIC_IP_GUESS=$(detect_public_ip)
    read -p "This server's public IP [${LOCAL_PUBLIC_IP_GUESS}]: " LOCAL_PUBLIC_IP
    LOCAL_PUBLIC_IP=${LOCAL_PUBLIC_IP:-$LOCAL_PUBLIC_IP_GUESS}

    read -p "The OTHER server's public IP: " PEER_PUBLIC_IP

    echo ""
    echo "Choose transport:"
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

    # Token is fixed (as requested) — same on both servers, no prompt needed.
    # NOTE: this is much weaker than a random token. Anyone who guesses/knows
    # "123" can authenticate to your tunnel. Fine for quick testing, but
    # consider a random token (openssl rand -hex 24) for anything real.
    TOKEN="$FIXED_TOKEN"

    # Tunnel port still has to match on both sides. Iran picks/generates it;
    # Kharej must type in EXACTLY the same port Iran is using.
    if [ "$LOCAL_ROLE" = "Iran" ]; then
        TUNNEL_PORT_DEFAULT=$(gen_port)
        read -p "Tunnel port [${TUNNEL_PORT_DEFAULT}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$TUNNEL_PORT_DEFAULT}
        read -p "Inbound ports on the Iran server (comma separated, e.g. 2050,2023): " INBOUND_PORTS
        IRAN_IP="$LOCAL_PUBLIC_IP"; KHAREJ_IP="$PEER_PUBLIC_IP"
        echo ""
        echo ">>> Tunnel port: $TUNNEL_PORT   (token is fixed: $TOKEN)"
        echo ">>> Enter this EXACT port when you run this script on the Kharej server."
    else
        echo ""
        echo "This MUST exactly match the port shown on the Iran server."
        read -p "Enter the tunnel port used on the Iran server: " TUNNEL_PORT
        KHAREJ_IP="$LOCAL_PUBLIC_IP"; IRAN_IP="$PEER_PUBLIC_IP"
    fi

    ensure_backhaul_local
    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        if [ "$LOCAL_ROLE" = "Iran" ]; then
            ensure_tls_cert_local
        fi
    fi

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        TOML_FILE="$INSTALL_DIR/iran${TUNNEL_PORT}.toml"
        {
            echo "[server]"
            echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
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

        SERVICE_FILE="/etc/systemd/system/backhaul-iran${TUNNEL_PORT}.service"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul Iran Server Port ${TUNNEL_PORT}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${TOML_FILE}
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
        systemctl daemon-reload
        systemctl enable --now "backhaul-iran${TUNNEL_PORT}.service"
        echo "Local Backhaul (Iran server side) started on port ${TUNNEL_PORT}."
    else
        TOML_FILE="$INSTALL_DIR/kharej${TUNNEL_PORT}.toml"
        cat > "$TOML_FILE" << EOF
[client]
remote_addr = "${IRAN_IP}:${TUNNEL_PORT}"
transport = "${TRANSPORT}"
token = "${TOKEN}"
connection_pool = 8
aggressive_pool = true
keepalive_period = 20
nodelay = true
retry_interval = 1
sniffer = false
web_port = 0
log_level = "warn"
EOF
        SERVICE_FILE="/etc/systemd/system/backhaul-kharej${TUNNEL_PORT}.service"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul Kharej Client Port ${TUNNEL_PORT}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${TOML_FILE}
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
        systemctl daemon-reload
        systemctl enable --now "backhaul-kharej${TUNNEL_PORT}.service"
        echo "Local Backhaul (Kharej client side) started, connecting to ${IRAN_IP}:${TUNNEL_PORT}."
    fi

    cat > "$STATE_FILE" << EOF
LOCAL_ROLE=${LOCAL_ROLE}
TUNNEL_PORT=${TUNNEL_PORT}
IRAN_IP=${IRAN_IP}
KHAREJ_IP=${KHAREJ_IP}
TRANSPORT=${TRANSPORT}
EOF

    echo ""
    echo "=== Setup Completed! ==="
    echo "Tunnel port: $TUNNEL_PORT"
    echo "Token: $TOKEN"
    echo "Check: systemctl status 'backhaul-*'"
    if [ "$TOKEN" = "123" ]; then
        echo "(Reminder: token is the fixed value '123' — fine for testing, weak for production.)"
    fi

    read -p "Run system optimizer now (BBR, buffers, MTU, DNS, ulimits)? (y/n): " RUNOPT
    [ "$RUNOPT" = "y" ] && optimize_system

    read -p "Install the watchdog (auto-restart on dead/idle tunnel)? (y/n): " RUNWD
    [ "$RUNWD" = "y" ] && setup_watchdog
}

# ============================================================
# Menu
# ============================================================

while true; do
    echo ""
    echo "==== Backhaul Tunnel Manager (v7) ===="
    echo "1) Install / Setup tunnel"
    echo "2) Show tunnel status"
    echo "3) Manage inbound ports (Iran side)"
    echo "4) Manage services (start/stop/restart/logs/edit)"
    echo "5) System optimizer (BBR + buffers + MTU + DNS + ulimits)"
    echo "6) Install/repair Watchdog (auto-restart on dead/idle tunnel)"
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
