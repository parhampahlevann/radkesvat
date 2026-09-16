#!/bin/bash
# =============================================================================
#  Backhaul Tunnel Manager  (Iran <-> Kharej)  —  v8.1
#
#  v8.1 fixes
#   * The install directory is now re-created before every download/write, so
#     "Failed to open /root/backhaul-core/backhaul.tar.gz" can no longer happen
#     (it showed up after Uninstall wiped the directory inside the same session).
#   * DNS is NEVER touched any more: no /etc/resolv.conf rewrite, no chattr.
#  Official Musixal/Backhaul release binary. Encrypted reverse port forwarding.
#
#  WHAT CHANGED vs v7
#   * Simpler menu (6 items) and a cleanly sectioned script.
#   * NEW: one Kharej server (client) -> MANY Iran servers (server) at once.
#          The client flow asks "how many Iran servers?", then IP + tunnel port
#          for each, and creates one independent service per Iran server.
#   * Service names are now unique per peer:
#          backhaul-kharej-<ip>-<port>.service   /   backhaul-iran-<port>.service
#   * New unit registry: /root/backhaul-core/units/*.env
#     -> the watchdog no longer has to guess anything from systemd files.
#   * Rewritten watchdog (see notes at the bottom of setup_watchdog):
#       - 5s tick
#       - per-PEER connection check (dst <ip>:<port>) so two tunnels that use
#         the same port number are never mixed up
#       - stall detection: TCP "unacked" on every socket = packet loss /
#         black-holed link, even while the socket still looks ESTABLISHED
#       - restart cooldown + start grace  -> no restart loops
#       - pause flag: a service you stopped by hand stays stopped
#       - automatic log rotation
#   * Faster failure detection: heartbeat 10s, dial_timeout 5s, retry 1s,
#     tcp_user_timeout 20s, keepalive 30/5/4.
#
#  Run this SEPARATELY on every server (each Iran server + the Kharej server).
# =============================================================================

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
BIN="$INSTALL_DIR/backhaul"
UNITS_DIR="$INSTALL_DIR/units"
WD_DIR="$INSTALL_DIR/watchdog"
WD_SCRIPT="$WD_DIR/watchdog.sh"
WD_CONF="$WD_DIR/watchdog.conf"
WD_LOG="$WD_DIR/watchdog.log"
WD_STATE="$WD_DIR/state"
FIXED_TOKEN="123"

# ---- watchdog tuning (written to $WD_CONF, editable later) -------------------
WD_TICK=5             # how often the watchdog runs (seconds)
WD_IDLE=20            # seconds with 0 established connections -> restart
WD_STALL=15           # seconds with all sockets unacked (packet loss) -> restart
WD_COOLDOWN=60        # min seconds between two restarts of the same service
WD_GRACE=45           # ignore a service for N seconds after it (re)starts

# =============================================================================
#  UI helpers
# =============================================================================
CG="\033[1;32m"; CR="\033[1;31m"; CY="\033[1;33m"; CB="\033[1;36m"; C0="\033[0m"
ok()   { echo -e "${CG}[ ok ]${C0} $*"; }
warn() { echo -e "${CY}[ !  ]${C0} $*"; }
fail() { echo -e "${CR}[err ]${C0} $*"; }
hr()   { echo "--------------------------------------------------------------"; }
title(){ echo; hr; echo -e "  ${CB}$*${C0}"; hr; }

ask() {  # ask "Question" "default"  -> prints the answer on stdout
    local p="$1" d="$2" v
    read -rp "$p${d:+ [$d]}: " v
    echo "${v:-$d}"
}
confirm() { local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]; }

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
slug()       { echo "${1//[^0-9A-Za-z]/-}"; }
gen_port()   { echo $(( (RANDOM % 40000) + 20000 )); }

if [ "$EUID" -ne 0 ]; then
    fail "Please run as root (sudo)."
    exit 1
fi
ensure_dirs() {   # called again before every write — the dir may have been wiped
    mkdir -p "$INSTALL_DIR" "$UNITS_DIR" "$WD_DIR" "$WD_STATE" 2>/dev/null
    if [ ! -d "$INSTALL_DIR" ] || [ ! -w "$INSTALL_DIR" ]; then
        fail "Cannot create or write to $INSTALL_DIR"
        df -h /root 2>/dev/null | tail -n1
        return 1
    fi
    return 0
}
ensure_dirs

# =============================================================================
#  Detection / installation helpers
# =============================================================================
detect_public_ip() {
    curl -fsSL -4 --max-time 6 https://ifconfig.me 2>/dev/null \
        || curl -fsSL -4 --max-time 6 https://api.ipify.org 2>/dev/null \
        || echo ""
}

detect_default_iface() {
    local i
    i=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
    [ -z "$i" ] && i=$(ip link show | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    [ -z "$i" ] && i="eth0"
    echo "$i"
}

ensure_backhaul() {
    ensure_dirs || return 1
    [ -x "$BIN" ] && return 0
    echo "Fetching the latest official Backhaul release..."
    local arch asset url tries=0
    arch=$(uname -m)
    case "$arch" in
        x86_64)  asset="amd64" ;;
        aarch64) asset="arm64" ;;
        *) fail "Unsupported architecture: $arch"; return 1 ;;
    esac
    url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep "browser_download_url" | grep "linux_${asset}" | grep -v ".sha256" \
        | head -n1 | cut -d '"' -f4)
    [ -z "$url" ] && url=$(ask "Could not resolve the asset. Paste the .tar.gz URL" "")
    [ -z "$url" ] && { fail "No download URL."; return 1; }

    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    until curl -fSL --retry 3 --retry-delay 2 -o "$INSTALL_DIR/backhaul.tar.gz" "$url"; do
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then
            fail "Download failed."
            echo "  Free space on /root:"; df -h /root 2>/dev/null | tail -n1
            echo "  URL: $url"
            return 1
        fi
        echo "Retrying..."; ensure_dirs; sleep 2
    done
    if ! tar -tzf "$INSTALL_DIR/backhaul.tar.gz" >/dev/null 2>&1; then
        fail "Downloaded file is not a valid archive."; rm -f "$INSTALL_DIR/backhaul.tar.gz"; return 1
    fi
    tar -xzf "$INSTALL_DIR/backhaul.tar.gz" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    chmod +x "$BIN"
    ok "Backhaul binary installed."
}

ensure_tls_cert() {
    ensure_dirs || return 1
    [ -f "$INSTALL_DIR/server.crt" ] && [ -f "$INSTALL_DIR/server.key" ] && return 0
    echo "Generating a self-signed TLS certificate for wss/wssmux..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" \
        -days 3650 -subj "/CN=backhaul" >/dev/null 2>&1
}

pick_transport() {
    {
        echo "Transport:"
        echo "  1) wss     - TLS, looks like HTTPS to firewalls (recommended)"
        echo "  2) wssmux  - wss + multiplexing (many concurrent connections)"
        echo "  3) tcp     - plain TCP, fastest, not encrypted/disguised"
        echo "  4) tcpmux  - tcp + multiplexing"
    } >&2
    local c; read -rp "Choice [1-4] (default 1): " c
    case "$c" in 2) echo "wssmux" ;; 3) echo "tcp" ;; 4) echo "tcpmux" ;; *) echo "wss" ;; esac
}

# =============================================================================
#  Unit registry  (one .env per tunnel service — used by the watchdog)
# =============================================================================
list_units() {
    { systemctl list-unit-files 'backhaul-*.service' --no-legend 2>/dev/null
      systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null; } \
      | awk '{print $1}' | grep -E '\.service$' \
      | grep -vE '^backhaul-(mtu|watchdog)\.service$' | sort -u
}

register_unit() {  # unit role toml port peer transport
    mkdir -p "$UNITS_DIR"
    cat > "$UNITS_DIR/$1.env" << EOF
ROLE=$2
TOML=$3
PORT=$4
PEER=$5
TRANSPORT=$6
EOF
}

rebuild_registry() {  # re-derive the registry from whatever is installed
    mkdir -p "$UNITS_DIR"
    rm -f "$UNITS_DIR"/*.env
    local u toml role port peer transport addr
    for u in $(list_units); do
        toml=$(grep -oE "${INSTALL_DIR}/[A-Za-z0-9_.-]+\.toml" "/etc/systemd/system/$u" 2>/dev/null | head -n1)
        [ -n "$toml" ] && [ -f "$toml" ] || continue
        transport=$(grep -oE '^transport *= *"[^"]+"' "$toml" | cut -d'"' -f2)
        if grep -q '^\[server\]' "$toml"; then
            role="iran"; peer=""
            addr=$(grep -oE '^bind_addr *= *"[^"]+"' "$toml" | cut -d'"' -f2)
        else
            role="kharej"
            addr=$(grep -oE '^remote_addr *= *"[^"]+"' "$toml" | cut -d'"' -f2)
            peer="${addr%:*}"
        fi
        port="${addr##*:}"
        [ -n "$port" ] || continue
        register_unit "$u" "$role" "$toml" "$port" "$peer" "$transport"
    done
}

count_conns() {  # role port peer -> number of established connections
    local role="$1" port="$2" peer="$3" filter
    if [ "$role" = "iran" ]; then
        filter="( sport = :$port )"
    elif valid_ipv4 "$peer"; then
        filter="( dst $peer:$port )"
    else
        filter="( dport = :$port )"
    fi
    ss -H -tn state established "$filter" 2>/dev/null | grep -c .
}

# =============================================================================
#  systemd unit writer
# =============================================================================
write_service() {  # unit-name description toml
    cat > "/etc/systemd/system/$1" << EOF
[Unit]
Description=$2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN} -c $3
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

# =============================================================================
#  Install — Iran side (server)
# =============================================================================
install_iran() {
    title "Iran server (server side)"
    ensure_dirs || return 1
    local port inbound transport toml unit

    while true; do
        port=$(ask "Tunnel port" "$(gen_port)")
        valid_port "$port" && break || fail "Invalid port."
    done
    transport=$(pick_transport)
    while true; do
        inbound=$(ask "Inbound ports on this server (comma separated, e.g. 2050,2087)" "")
        [ -n "$inbound" ] && break || fail "At least one inbound port is required."
    done

    ensure_backhaul || return 1
    case "$transport" in wss|wssmux) ensure_tls_cert ;; esac

    toml="$INSTALL_DIR/iran-${port}.toml"
    unit="backhaul-iran-${port}.service"

    {
        echo "[server]"
        echo "bind_addr = \"0.0.0.0:${port}\""
        echo "transport = \"${transport}\""
        echo "token = \"${FIXED_TOKEN}\""
        echo "keepalive_period = 20"
        echo "nodelay = true"
        echo "channel_size = 16384"
        echo "heartbeat = 10"
        echo "mux_con = 8"
        case "$transport" in wss|wssmux)
            echo "tls_cert = \"${INSTALL_DIR}/server.crt\""
            echo "tls_key = \"${INSTALL_DIR}/server.key\"" ;;
        esac
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"warn\""
        echo ""
        echo "ports = ["
    } > "$toml"
    local -a arr; IFS=',' read -ra arr <<< "$inbound"
    local i p
    for i in "${!arr[@]}"; do
        p=$(echo "${arr[i]}" | xargs)
        [ -z "$p" ] && continue
        if [ $((i + 1)) -eq ${#arr[@]} ]; then echo "    \"${p}\"" >> "$toml"
        else echo "    \"${p}\"," >> "$toml"; fi
    done
    echo "]" >> "$toml"

    write_service "$unit" "Backhaul Iran server (port ${port})" "$toml"
    register_unit "$unit" "iran" "$toml" "$port" "" "$transport"
    rm -f "$WD_STATE/$unit.paused"
    systemctl daemon-reload
    systemctl enable --now "$unit" >/dev/null 2>&1
    ok "Iran server started on port ${port} (${transport})."
    echo
    echo "  >>> On the Kharej server, enter this server's IP and port ${port}."
}

# =============================================================================
#  Install — Kharej side (client)  —  supports MANY Iran servers
# =============================================================================
create_client() {  # ip port transport
    ensure_dirs || return 1
    local ip="$1" port="$2" transport="$3" toml unit
    toml="$INSTALL_DIR/kharej-$(slug "$ip")-${port}.toml"
    unit="backhaul-kharej-$(slug "$ip")-${port}.service"

    if [ -f "/etc/systemd/system/$unit" ]; then
        if ! confirm "  A tunnel to ${ip}:${port} already exists. Overwrite?"; then
            warn "  Skipped ${ip}:${port}."; return 0
        fi
    fi

    cat > "$toml" << EOF
[client]
remote_addr = "${ip}:${port}"
transport = "${transport}"
token = "${FIXED_TOKEN}"
connection_pool = 8
aggressive_pool = true
keepalive_period = 20
dial_timeout = 5
retry_interval = 1
nodelay = true
sniffer = false
web_port = 0
log_level = "warn"
EOF

    write_service "$unit" "Backhaul Kharej client -> ${ip}:${port}" "$toml"
    register_unit "$unit" "kharej" "$toml" "$port" "$ip" "$transport"
    rm -f "$WD_STATE/$unit.paused"
    systemctl daemon-reload
    systemctl enable --now "$unit" >/dev/null 2>&1
    ok "  Tunnel -> ${ip}:${port} started (${transport})."
}

install_kharej() {
    title "Kharej server (client side)"
    ensure_dirs || return 1
    echo "One Kharej server can hold several tunnels at the same time —"
    echo "one independent service per Iran server."
    echo

    local n transport i ip port
    while true; do
        n=$(ask "How many Iran servers do you want to connect to now?" "1")
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && break || fail "Enter a number >= 1."
    done
    transport=$(pick_transport)
    echo "(All Iran servers below must use the same transport: ${transport})"

    ensure_backhaul || return 1

    for ((i = 1; i <= n; i++)); do
        echo
        echo -e "${CB}--- Iran server #${i} ---${C0}"
        while true; do
            ip=$(ask "  Public IP of Iran server #${i}" "")
            [ -n "$ip" ] || { fail "  IP cannot be empty."; continue; }
            valid_ipv4 "$ip" || warn "  Not an IPv4 address — the watchdog will fall back to port-only checks."
            break
        done
        while true; do
            port=$(ask "  Tunnel port of Iran server #${i} (must match that server)" "")
            valid_port "$port" && break || fail "  Invalid port."
        done
        create_client "$ip" "$port" "$transport"
    done

    echo
    ok "${n} tunnel(s) configured on this Kharej server."
    echo "  Run option 1 again any time to add more Iran servers."
}

install_flow() {
    title "Install / add a tunnel"
    echo "  1) Iran server    (server side — accepts the tunnel)"
    echo "  2) Kharej server  (client side — connects to Iran servers)"
    local r; read -rp "Select [1-2]: " r
    case "$r" in
        1) install_iran ;;
        2) install_kharej ;;
        *) fail "Invalid selection."; return ;;
    esac

    echo
    confirm "Run the system optimizer now (BBR, buffers, MTU, limits)?" && optimize_system
    confirm "Install/refresh the watchdog?" && setup_watchdog
}

# =============================================================================
#  Status
# =============================================================================
show_status() {
    title "Status"
    local units u conns state uptime
    units=$(list_units)
    if [ -z "$units" ]; then warn "No tunnel service on this server."; return; fi

    printf "%-42s %-9s %-7s %s\n" "SERVICE" "STATE" "CONNS" "TARGET"
    for u in $units; do
        ( unset ROLE TOML PORT PEER TRANSPORT
          [ -f "$UNITS_DIR/$u.env" ] && . "$UNITS_DIR/$u.env"
          if systemctl is-active --quiet "$u"; then state="UP"; else state="DOWN"; fi
          [ -f "$WD_STATE/$u.paused" ] && state="PAUSED"
          conns=$(count_conns "${ROLE:-iran}" "${PORT:-0}" "${PEER:-}")
          if [ "${ROLE:-}" = "kharej" ]; then target="${PEER}:${PORT} (${TRANSPORT})"
          else target="0.0.0.0:${PORT} (${TRANSPORT})"; fi
          printf "%-42s %-9s %-7s %s\n" "$u" "$state" "$conns" "$target" )
    done

    echo
    echo "Recent errors (last 20 log lines per service):"
    local found=0 warnmsg
    for u in $units; do
        warnmsg=$(journalctl -u "$u" -n 20 --no-pager 2>/dev/null \
            | grep -iE "invalid security token|error|failed" | tail -n 2)
        if [ -n "$warnmsg" ]; then found=1; echo "  --- $u"; echo "$warnmsg" | sed 's/^/    /'; fi
    done
    [ "$found" = "0" ] && echo "  none"
    [ "$found" = "1" ] && echo "  (invalid security token = the token differs between the two servers)"

    echo
    if systemctl is-active --quiet backhaul-watchdog.timer; then
        ok "Watchdog: active (every ${WD_TICK}s)"
    else
        warn "Watchdog: not installed/inactive — use menu option 5."
    fi
    if [ -f "$WD_LOG" ]; then
        echo "Last 8 watchdog actions:"
        tail -n 8 "$WD_LOG" | sed 's/^/  /'
    fi
}

# =============================================================================
#  Inbound port editor (Iran side)
# =============================================================================
read_ports()  { sed -n '/^ports = \[/,/^\]/p' "$1" | grep -oE '"[^"]*"' | tr -d '"'; }
write_ports() {  # file port...
    local f="$1"; shift
    local tmp; tmp=$(mktemp)
    sed '/^ports = \[/,/^\]/d' "$f" > "$tmp"
    { echo "ports = ["
      local n=$# i=0 p
      for p in "$@"; do
          i=$((i + 1))
          if [ "$i" -lt "$n" ]; then echo "    \"$p\","; else echo "    \"$p\""; fi
      done
      echo "]"
    } >> "$tmp"
    mv "$tmp" "$f"
}

ports_menu() {  # toml unit
    local toml="$1" unit="$2" c p; local -a arr
    while true; do
        echo
        echo "Inbound ports in $(basename "$toml"):"
        if [ -z "$(read_ports "$toml")" ]; then echo "  (none)"; else read_ports "$toml" | sed 's/^/  - /'; fi
        echo "  1) Add    2) Remove    0) Back"
        read -rp "Select: " c
        case "$c" in
            1) p=$(ask "Port to add (e.g. 2050 or 443=1.1.1.1:443)" "")
               [ -z "$p" ] && continue
               mapfile -t arr < <(read_ports "$toml"); arr+=("$p")
               write_ports "$toml" "${arr[@]}"
               systemctl restart "$unit"; ok "Added and restarted." ;;
            2) p=$(ask "Port to remove" "")
               [ -z "$p" ] && continue
               mapfile -t arr < <(read_ports "$toml" | grep -vx "$p")
               write_ports "$toml" "${arr[@]}"
               systemctl restart "$unit"; ok "Removed and restarted." ;;
            0) return ;;
            *) fail "Invalid option." ;;
        esac
    done
}

# =============================================================================
#  Service manager
# =============================================================================
manage_services() {
    local units; units=$(list_units)
    if [ -z "$units" ]; then warn "No tunnel service on this server."; return; fi

    title "Services"
    local -a list; mapfile -t list < <(echo "$units")
    local i
    for i in "${!list[@]}"; do printf "  %d) %s\n" "$((i + 1))" "${list[i]}"; done
    echo "  0) Back"
    local sel; read -rp "Select: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] || { fail "Invalid."; return; }
    [ "$sel" = "0" ] && return
    local unit="${list[$((sel - 1))]}"
    [ -z "$unit" ] && { fail "Invalid."; return; }

    unset ROLE TOML PORT PEER TRANSPORT
    [ -f "$UNITS_DIR/$unit.env" ] && . "$UNITS_DIR/$unit.env"
    [ -z "$TOML" ] && TOML=$(grep -oE "${INSTALL_DIR}/[A-Za-z0-9_.-]+\.toml" "/etc/systemd/system/$unit" | head -n1)

    local c r d
    while true; do
        echo
        hr
        echo "  $unit"
        systemctl is-active  --quiet "$unit"   && echo "  State: RUNNING" || echo "  State: STOPPED"
        systemctl is-enabled --quiet "$unit" 2>/dev/null && echo "  Auto-start: enabled" || echo "  Auto-start: disabled"
        [ -f "$WD_STATE/$unit.paused" ] && echo "  Watchdog: PAUSED (stopped by hand)"
        [ -n "$PORT" ] && echo "  Connections: $(count_conns "${ROLE:-iran}" "$PORT" "${PEER:-}")"
        hr
        echo "  1) Start        2) Stop         3) Restart"
        echo "  4) Live logs    5) View config  6) Edit config"
        [ "${ROLE:-}" = "iran" ] && echo "  7) Inbound ports"
        echo "  8) Delete this service"
        echo "  0) Back"
        read -rp "Select: " c
        case "$c" in
            1) rm -f "$WD_STATE/$unit.paused"; systemctl start "$unit"; ok "Started." ;;
            2) touch "$WD_STATE/$unit.paused"; systemctl stop "$unit"
               ok "Stopped (the watchdog will leave it alone until you start it again)." ;;
            3) rm -f "$WD_STATE/$unit.paused"; systemctl restart "$unit"; ok "Restarted." ;;
            4) journalctl -u "$unit" -f ;;
            5) [ -n "$TOML" ] && cat "$TOML" || fail "Config not found." ;;
            6) if [ -n "$TOML" ]; then
                   ${EDITOR:-nano} "$TOML"
                   confirm "Restart to apply?" && systemctl restart "$unit" && ok "Restarted."
                   rebuild_registry
               else fail "Config not found."; fi ;;
            7) [ "${ROLE:-}" = "iran" ] && ports_menu "$TOML" "$unit" || fail "Invalid option." ;;
            8) read -rp "Delete $unit and its config? [y/N]: " d
               if [[ "$d" =~ ^[Yy]$ ]]; then
                   systemctl disable --now "$unit" >/dev/null 2>&1
                   rm -f "/etc/systemd/system/$unit" "$UNITS_DIR/$unit.env"
                   rm -f "$WD_STATE/$unit".*
                   [ -n "$TOML" ] && rm -f "$TOML"
                   systemctl daemon-reload
                   ok "Deleted."; return
               fi ;;
            0) return ;;
            *) fail "Invalid option." ;;
        esac
    done
}

# =============================================================================
#  System optimizer (BBR + sysctl + MTU + ulimits)   — DNS is never touched
# =============================================================================
ensure_ulimits() {
    echo "-- file descriptor limits"
    sysctl -w fs.file-max=2097152 >/dev/null 2>&1
    if ! grep -q "backhaul-tunnel limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'EOF'

# backhaul-tunnel limits
root soft nofile 1048576
root hard nofile 1048576
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
    ulimit -n 1048576 2>/dev/null
    ok "File descriptor limits raised."
}

ensure_mtu() {
    echo "-- MTU 1400"
    local iface; iface=$(detect_default_iface)
    ip link set dev "$iface" mtu 1400 2>/dev/null || warn "Could not set MTU live (will apply at next boot)."
    cat > /etc/systemd/system/backhaul-mtu.service << EOF
[Unit]
Description=Pin MTU 1400 on ${iface} for the Backhaul tunnel
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
    ok "MTU 1400 pinned on ${iface} (persists after reboot)."
}

# NOTE: DNS is intentionally left alone. This script never edits
# /etc/resolv.conf and never runs chattr on it.

optimize_system() {
    title "System optimizer"
    echo "Interface: $(detect_default_iface)"

    cat > /etc/sysctl.d/99-backhaul-tunnel.conf << 'EOF'
# --- Backhaul tunnel profile -------------------------------------------------
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.ip_local_port_range=1024 65535
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
# fast dead-peer / packet-loss detection
net.ipv4.tcp_keepalive_time=30
net.ipv4.tcp_keepalive_intvl=5
net.ipv4.tcp_keepalive_probes=4
net.ipv4.tcp_user_timeout=20000
net.ipv4.tcp_retries2=6
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.ip_forward=1
fs.file-max=2097152
# Deliberately NOT set: tcp_tw_recycle (removed from modern kernels),
# tcp_tw_reuse (can break behind NAT/CGNAT).
EOF
    sysctl --system >/dev/null 2>&1
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        ok "BBR + fq enabled."
    else
        warn "BBR not available on this kernel — staying on the default (usually CUBIC)."
    fi
    ok "Saved to /etc/sysctl.d/99-backhaul-tunnel.conf (persists across reboots)."

    ensure_ulimits
    ensure_mtu
    echo
    ok "Optimization complete (DNS untouched)."
}

# =============================================================================
#  Watchdog
# =============================================================================
setup_watchdog() {
    title "Watchdog"
    command -v ss >/dev/null 2>&1 || warn "'ss' not found — install iproute2, the watchdog needs it."

    mkdir -p "$WD_DIR" "$WD_STATE"
    rebuild_registry

    cat > "$WD_CONF" << EOF
# Backhaul watchdog tuning — edit, then: systemctl restart backhaul-watchdog.timer
IDLE_THRESHOLD=${WD_IDLE}      # seconds with 0 established connections -> restart
STALL_THRESHOLD=${WD_STALL}    # seconds with every socket unacked (packet loss) -> restart
RESTART_COOLDOWN=${WD_COOLDOWN} # min seconds between two restarts of one service
START_GRACE=${WD_GRACE}        # ignore a service for N seconds after it (re)starts
LOG_MAX_LINES=800
EOF

    cat > "$WD_SCRIPT" << 'WDEOF'
#!/bin/bash
# Backhaul watchdog — started every few seconds by backhaul-watchdog.timer
#
# A service is restarted when:
#   1) it is not active at all                       -> restart (short cooldown)
#   2) it has 0 established connections on its own
#      tunnel endpoint for IDLE_THRESHOLD seconds    -> link is dead
#   3) every established socket of that endpoint has
#      unacknowledged data for STALL_THRESHOLD secs  -> packet loss / black hole
#      (the socket still says ESTABLISHED, but nothing gets through)
#
# It never touches a service that: was stopped from the menu (.paused),
# is disabled, or (re)started less than START_GRACE seconds ago.

INSTALL_DIR="/root/backhaul-core"
UNITS_DIR="$INSTALL_DIR/units"
WD_DIR="$INSTALL_DIR/watchdog"
STATE="$WD_DIR/state"
LOG="$WD_DIR/watchdog.log"
CONF="$WD_DIR/watchdog.conf"

IDLE_THRESHOLD=20
STALL_THRESHOLD=15
RESTART_COOLDOWN=60
START_GRACE=45
LOG_MAX_LINES=800
[ -f "$CONF" ] && . "$CONF"

mkdir -p "$STATE"
NOW=$(date +%s)

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

unit_uptime() {  # seconds since the unit became active (999999 if unknown)
    local t up
    t=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$1" 2>/dev/null)
    if [ -z "$t" ] || [ "$t" = "0" ]; then echo 999999; return; fi
    up=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
    echo $(( (up - t) / 1000000 ))
}

do_restart() {  # unit reason cooldown
    local unit="$1" reason="$2" cd="$3" f="$STATE/$unit.restart" last
    last=$(cat "$f" 2>/dev/null || echo 0)
    [ $(( NOW - last )) -lt "$cd" ] && return 0
    echo "$NOW" > "$f"
    systemctl restart "$unit" >/dev/null 2>&1
    rm -f "$STATE/$unit.ok" "$STATE/$unit.stall"
    log "restarted $unit — $reason"
}

for envf in "$UNITS_DIR"/*.env; do
    [ -f "$envf" ] || continue
    unset ROLE TOML PORT PEER TRANSPORT
    . "$envf"
    unit=$(basename "$envf" .env)

    [ -f "/etc/systemd/system/$unit" ] || { rm -f "$envf"; continue; }
    [ -f "$STATE/$unit.paused" ] && continue
    systemctl is-enabled --quiet "$unit" 2>/dev/null || continue

    # 1) service down
    if ! systemctl is-active --quiet "$unit"; then
        do_restart "$unit" "service was not active" 10
        continue
    fi

    # give it time to build its connection pool after a (re)start
    [ "$(unit_uptime "$unit")" -lt "$START_GRACE" ] && continue
    [ -n "$PORT" ] || continue

    if [ "$ROLE" = "iran" ]; then
        filter="( sport = :$PORT )"; label="port $PORT"
    elif [[ "$PEER" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        filter="( dst $PEER:$PORT )"; label="$PEER:$PORT"
    else
        filter="( dport = :$PORT )"; label="port $PORT"
    fi

    raw=$(ss -H -tin state established "$filter" 2>/dev/null)
    conns=$(printf '%s\n' "$raw" | grep -c '^[^[:space:]]')
    stuck=$(printf '%s\n' "$raw" | grep -c 'unacked:')

    if [ "$conns" -eq 0 ]; then
        # 2) nothing established on this endpoint
        rm -f "$STATE/$unit.stall"
        last_ok=$(cat "$STATE/$unit.ok" 2>/dev/null)
        if [ -z "$last_ok" ]; then echo "$NOW" > "$STATE/$unit.ok"; last_ok=$NOW; fi
        idle=$(( NOW - last_ok ))
        if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
            do_restart "$unit" "no established connection on $label for ${idle}s" "$RESTART_COOLDOWN"
        fi
    else
        echo "$NOW" > "$STATE/$unit.ok"
        # 3) every socket has unacked data -> traffic is not getting through
        if [ "$stuck" -ge "$conns" ]; then
            first=$(cat "$STATE/$unit.stall" 2>/dev/null)
            if [ -z "$first" ]; then echo "$NOW" > "$STATE/$unit.stall"; first=$NOW; fi
            stalled=$(( NOW - first ))
            if [ "$stalled" -ge "$STALL_THRESHOLD" ]; then
                do_restart "$unit" "all $conns socket(s) on $label stalled (unacked) for ${stalled}s" "$RESTART_COOLDOWN"
            fi
        else
            rm -f "$STATE/$unit.stall"
        fi
    fi
done

# keep the log small
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$LOG_MAX_LINES" ]; then
    tail -n "$LOG_MAX_LINES" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
WDEOF
    chmod +x "$WD_SCRIPT"

    cat > /etc/systemd/system/backhaul-watchdog.service << EOF
[Unit]
Description=Backhaul watchdog (health check / auto-restart)

[Service]
Type=oneshot
ExecStart=${WD_SCRIPT}
EOF

    cat > /etc/systemd/system/backhaul-watchdog.timer << EOF
[Unit]
Description=Run the Backhaul watchdog every ${WD_TICK} seconds

[Timer]
OnBootSec=20
OnUnitActiveSec=${WD_TICK}
AccuracySec=1
Unit=backhaul-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-watchdog.timer >/dev/null 2>&1
    ok "Watchdog installed — tick ${WD_TICK}s, dead link ${WD_IDLE}s, stalled link ${WD_STALL}s."
    echo "  Tuning: $WD_CONF"
    echo "  Log:    $WD_LOG"
}

# =============================================================================
#  Uninstall
# =============================================================================
uninstall_all() {
    title "Uninstall"
    if ! confirm "Remove ALL Backhaul services on THIS server?"; then echo "Cancelled."; return; fi

    local u
    for u in $(list_units); do
        systemctl disable --now "$u" >/dev/null 2>&1
        rm -f "/etc/systemd/system/$u"
    done
    systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/backhaul-watchdog.timer /etc/systemd/system/backhaul-watchdog.service
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    ok "Services and configs removed."

    if confirm "Also revert the system tuning (sysctl / MTU)?"; then
        systemctl disable --now backhaul-mtu.service >/dev/null 2>&1
        rm -f /etc/systemd/system/backhaul-mtu.service /etc/sysctl.d/99-backhaul-tunnel.conf
        systemctl daemon-reload
        sysctl --system >/dev/null 2>&1
        ok "System tuning reverted (a reboot fully restores the MTU)."
    else
        warn "System tuning left in place."
    fi
}

# =============================================================================
#  Main menu
# =============================================================================
while true; do
    echo
    hr
    echo -e "  ${CB}Backhaul Tunnel Manager — v8.1${C0}    services: $(list_units | grep -c .)"
    hr
    echo "  1) Install / add a tunnel"
    echo "  2) Status"
    echo "  3) Manage services  (start/stop/logs/config/ports/delete)"
    echo "  4) System optimizer (BBR, buffers, MTU, limits)"
    echo "  5) Install / repair watchdog"
    echo "  6) Uninstall"
    echo "  0) Exit"
    read -rp "Select [0-6]: " CHOICE
    case "$CHOICE" in
        1) install_flow ;;
        2) show_status ;;
        3) manage_services ;;
        4) optimize_system ;;
        5) setup_watchdog ;;
        6) uninstall_all ;;
        0) exit 0 ;;
        *) fail "Invalid option." ;;
    esac
done
