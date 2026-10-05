#!/bin/bash

# =====================================================================================
# Backhaul Tunnel Manager (Iran <-> Kharej) — v9
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding.
#
# v9 — ROOT-CAUSE FIX for "IPv6 tunnel connects, ping is good, but data is slow / pages load half":
#   That symptom is a Path-MTU black hole: small packets (ping, handshake, heartbeats) pass, but
#   full-size TCP segments are dropped somewhere on the IPv6 path and the ICMPv6 "Packet Too Big"
#   reply never comes back, so every tunnel connection stalls until TCP backs off (laggy / half pages).
#   Backhaul's ws/wss transports have NO `mss` option (only tcp/tcpmux have one), and v8 only pinned
#   the NIC MTU (optional, 1400 — not enough when the real IPv6 path MTU is lower).
#   v9 clamps the TCP MSS of the tunnel connections themselves:
#     - iptables/ip6tables `TCPMSS --set-mss` on the tunnel port (mss.sh, rebuilt from the .toml files,
#       re-applied at boot by backhaul-mss.service)
#     - native `mss =` in the .toml for tcp / tcpmux
#     - tcp_mtu_probing=1 as a safety net + ICMP "packet too big" explicitly allowed in
#   Defaults: IPv6 MSS 1220 (= MTU 1280, the IPv6 minimum -> always safe), IPv4 MSS 1360 (= MTU 1400).
#   Cost: < 1% throughput.  Menu 7 = detect the real path MTU / change MSS / diagnostics.
#   !! Run v9 on BOTH servers. Each side only protects the data it RECEIVES, so updating
#      one side fixes only one direction.
#
# v9 — stability / install fixes:
#   * systemd: StartLimitIntervalSec was in [Service] (systemd ignores it there) -> a fast crash loop
#     hit the default start limit and the unit stayed dead. Moved to [Unit]. Units now wait for
#     network-online.target; OOMScoreAdjust -1000 -> -500 (-1000 can hang the whole VPS instead of
#     killing the leaking process).
#   * `set -e` removed (a failing systemctl/ping/openssl used to kill the whole menu); errors are
#     handled explicitly, closed stdin no longer loops forever, Ctrl+C in live logs returns to the menu.
#   * Re-running a setup now RESTARTS the service (v8 used `enable --now`, which kept the old config
#     running). Service lists come from the unit files (disabled units used to vanish after a reboot).
#   * Watchdog: exponential back-off (30s, 60s ... 600s) instead of restarting every 30s forever when
#     the peer is down; respects "Stop" from the menu and disabled units; trims its own log.
#   * Backhaul's server exits (Fatalf) if an inbound port can't be bound, and it re-binds all ports on
#     every internal restart. v9 warns about ports already in use and reserves them
#     (ip_local_reserved_ports) so outgoing connections can't grab them meanwhile.
#   * Inbound port entries are validated (Backhaul splits targets on ':' -> IPv6 literal targets break).
#   * Optimizer: removed keys that don't exist / are obsolete (tcp_user_timeout, tcp_low_latency),
#     tcp_fastopen and ip_forward (not needed by a user-space tunnel); only keys the kernel really
#     accepted are persisted (BBR only if available); tcp_retries2 6 -> 8; the MTU pin only ever LOWERS
#     the MTU (v8 could raise a smaller NIC MTU to 1400 and break the link); DNS list follows what the
#     host can reach (IPv6-only hosts had 5s lookups) and /etc/resolv.conf is backed up + restorable.
#   * Install: missing packages (curl, openssl, iproute2, iptables, ping) are installed; download falls
#     back to /releases/latest/download, a custom URL or a local .tar.gz; uninstall can revert tuning.
#   * NOTE: Backhaul itself runs `sysctl -w` (tcp_tw_reuse=1, rmem/wmem_max up to 256MB, port range
#     1024-65535, tcp_fastopen ...) at every start unless the config has skip_optz = true. It was
#     left at its default; just be aware that it overrides same-named keys of the optimizer.
#   * Token: still the fixed default "123" (as requested) — weak: anyone who can reach the tunnel port and
#     guesses it can register as your client and receive the forwarded traffic. Override without
#     editing the script:  BACKHAUL_TOKEN='long-random-string' bash script.sh   (same on all servers).
#
# Run this SEPARATELY on each server (every Iran server + the Kharej server).
# Order: set up the Iran server(s) first, note their IP / tunnel port, then run the Kharej setup.
# =====================================================================================

VERSION="v9"
REPO="Musixal/Backhaul"
INSTALL_DIR="${BACKHAUL_DIR:-/root/backhaul-core}"
SYSTEMD_DIR="${BACKHAUL_SYSTEMD_DIR:-/etc/systemd/system}"
STATE_FILE="$INSTALL_DIR/state.env"
FIXED_TOKEN="${BACKHAUL_TOKEN:-123}"
WATCHDOG_SCRIPT="$INSTALL_DIR/watchdog.sh"
WATCHDOG_LOG="$INSTALL_DIR/watchdog.log"
WATCHDOG_STATE_DIR="$INSTALL_DIR/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=30
MSS_SCRIPT="$INSTALL_DIR/mss.sh"
MSS_ENV="$INSTALL_DIR/mss.env"
DEFAULT_MSS_V6=1220     # MTU 1280 (IPv6 minimum) - 60
DEFAULT_MSS_V4=1360     # MTU 1400 - 40
MTU_CAP=1400

MSS_V6=$DEFAULT_MSS_V6
MSS_V4=$DEFAULT_MSS_V4
MSS_ENABLE=1
TRANSPORT="wss"
TOKEN="$FIXED_TOKEN"
IP_MODE=4
PING6_CMD=""
PKG_MGR=""
LOCAL_ROLE=""
TUNNEL_PORT=""

# ============================================================
# Small helpers
# ============================================================

warn() { echo "Warning: $*"; }

ask() {
    # ask <var> <prompt> [default] — exits cleanly when stdin is closed (no endless prompt loops)
    local __v="$1" __p="$2" __d="${3:-}" __a=""
    if ! read -r -p "$__p" __a; then
        echo ""
        echo "Input closed — exiting."
        exit 1
    fi
    __a="${__a:-$__d}"
    printf -v "$__v" '%s' "$__a"
}

ask_yn() {
    # usage: ask_yn "Question?" [y|n]   -> returns 0 for yes, 1 for no
    local prompt="$1" def="${2:-n}" ans
    ask ans "$prompt [$def]: " "$def"
    case "$ans" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

choose() {
    # choose <var> <label> item...  -> sets <var> to the chosen item; returns 1 when cancelled (0)
    local __v="$1" __l="$2" __i __n __ans
    shift 2
    local -a __items=("$@")
    __n=${#__items[@]}
    while true; do
        for __i in "${!__items[@]}"; do
            printf '  %d) %s\n' $((__i + 1)) "${__items[__i]}"
        done
        ask __ans "${__l} [1-${__n}, 0 = cancel]: "
        if [ "$__ans" = "0" ]; then
            return 1
        fi
        if [[ "$__ans" =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le "$__n" ]; then
            printf -v "$__v" '%s' "${__items[__ans-1]}"
            return 0
        fi
        echo "Invalid selection."
    done
}

gen_port() {
    # below the default ephemeral range (32768+) so outgoing connections are less likely to collide
    echo $(( (RANDOM % 22000) + 10000 ))
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
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$ip" >/dev/null 2>&1
        return $?
    fi
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

valid_port_entry() {
    # Backhaul "ports" entries: 443 | 4000=5000 | 1000-1010 | 1000-1010:5201 | 443=1.1.1.1:5201 | 127.0.0.2:443=5201
    local e="$1" ip='([0-9]{1,3}\.){3}[0-9]{1,3}' p='[0-9]{1,5}' n
    [[ "$e" =~ ^(${ip}:)?${p}(-${p})?((=|:)(${ip}:)?${p})?$ ]] || return 1
    for n in $(echo "$e" | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}//g' | grep -oE '[0-9]+'); do
        [ "$n" -ge 1 ] && [ "$n" -le 65535 ] || return 1
    done
    return 0
}

entry_local_spec() {
    # prints the LOCAL port / port range of a Backhaul "ports" entry (no bind-IP, no target)
    local e="$1" l
    l="${e%%=*}"
    if [[ "$l" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:(.+)$ ]]; then
        l="${BASH_REMATCH[2]}"
    else
        l="${l%%:*}"
    fi
    echo "$l"
}

has_global_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6"
}

check_reachable() {
    # quick TCP probe (works for IPv4 and IPv6 literals)
    local host="$1" port="$2"
    timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

detect_ping6() {
    [ -n "$PING6_CMD" ] && return 0
    if ping -6 -c1 -W1 -n ::1 >/dev/null 2>&1; then
        PING6_CMD="ping -6"
    elif command -v ping6 >/dev/null 2>&1; then
        PING6_CMD="ping6"
    else
        PING6_CMD="ping -6"
    fi
}

run_ping() {
    # run_ping <host> <ping options...>   (picks the right IP version from the address)
    local host="$1"
    shift
    if [[ "$host" == *:* ]]; then
        detect_ping6
        # shellcheck disable=SC2086
        $PING6_CMD "$@" "$host"
    else
        ping -4 "$@" "$host"
    fi
}

ping_ok() {
    # plain reachability: ping_ok <host> [count] [timeout]
    run_ping "$1" -n -c "${2:-1}" -W "${3:-2}" >/dev/null 2>&1
}

# ---------- detection ----------

detect_public_ip() {
    local ip svc
    for svc in https://ifconfig.me https://api.ipify.org https://ipv4.icanhazip.com; do
        ip=$(curl -fsSL -4 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if valid_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    # fallback: source address of the default IPv4 route
    ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1
}

detect_public_ip6() {
    local ip svc
    for svc in https://ifconfig.me https://api6.ipify.org https://ipv6.icanhazip.com; do
        ip=$(curl -fsSL -6 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" == *:* ]] && valid_ipv6 "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -oE 'src [0-9a-fA-F:]+' | awk '{print $2}' | head -n1
}

detect_default_iface() {
    local iface
    iface=$(ip -o -4 route show to default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    [ -z "$iface" ] && iface=$(ip -o -6 route show to default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    [ -z "$iface" ] && iface=$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' | cut -d@ -f1)
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

# ---------- packages ----------

detect_pkg_mgr() {
    [ -n "$PKG_MGR" ] && return 0
    if command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf
    elif command -v yum >/dev/null 2>&1; then PKG_MGR=yum
    elif command -v apk >/dev/null 2>&1; then PKG_MGR=apk
    else PKG_MGR=none
    fi
}

pkg_for_cmd() {
    case "$PKG_MGR:$1" in
        apt:ip|apt:ss|apk:ip|apk:ss) echo iproute2 ;;
        dnf:ip|dnf:ss|yum:ip|yum:ss) echo iproute ;;
        apt:ping) echo iputils-ping ;;
        dnf:ping|yum:ping|apk:ping) echo iputils ;;
        *:ip6tables) echo iptables ;;
        *) echo "$1" ;;
    esac
}

ensure_cmds() {
    # ensure_cmds cmd...  — installs whatever is missing (best effort). Returns 1 if something is still missing.
    local c p rc=0
    local -a pkgs=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 && continue
        detect_pkg_mgr
        if [ "$PKG_MGR" = "none" ]; then
            warn "'$c' is missing and no supported package manager was found."
            continue
        fi
        p=$(pkg_for_cmd "$c")
        [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
    done
    if [ "${#pkgs[@]}" -gt 0 ]; then
        echo "Installing missing packages: ${pkgs[*]}"
        case "$PKG_MGR" in
            apt)
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 \
                    || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1; } ;;
            dnf) dnf install -y -q "${pkgs[@]}" >/dev/null 2>&1 ;;
            yum) yum install -y -q "${pkgs[@]}" >/dev/null 2>&1 ;;
            apk) apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1 ;;
        esac
    fi
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            warn "could not install '$c'."
            rc=1
        fi
    done
    return $rc
}

# ============================================================
# Binary + TLS certificate
# ============================================================

ensure_backhaul_local() {
    local asset_arch url tmp attempt
    mkdir -p "$INSTALL_DIR"
    if [ -x "$INSTALL_DIR/backhaul" ] && "$INSTALL_DIR/backhaul" -v >/dev/null 2>&1; then
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64) asset_arch="amd64" ;;
        aarch64|arm64) asset_arch="arm64" ;;
        *) echo "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac

    tmp="$INSTALL_DIR/backhaul.tar.gz"
    url="${BACKHAUL_URL:-}"
    if [ -z "$url" ]; then
        echo "Looking up the latest official Backhaul release on GitHub..."
        url=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
            | grep "browser_download_url" | grep "linux_${asset_arch}" | grep -v "\.sha256" \
            | head -n1 | cut -d '"' -f4)
        # API rate-limited / blocked? the "latest/download" redirect needs no API call.
        [ -z "$url" ] && url="https://github.com/${REPO}/releases/latest/download/backhaul_linux_${asset_arch}.tar.gz"
    fi

    while true; do
        rm -f "$tmp"
        if [ -f "$url" ]; then
            cp "$url" "$tmp"
        else
            echo "Downloading: $url"
            attempt=0
            until curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$tmp" "$url"; do
                attempt=$((attempt + 1))
                if [ "$attempt" -ge 3 ]; then
                    break
                fi
                echo "Retrying download..."
                sleep 2
            done
        fi
        if [ -s "$tmp" ] && tar -tzf "$tmp" >/dev/null 2>&1; then
            break
        fi
        rm -f "$tmp"
        echo "Download failed or the file is not a valid .tar.gz (check disk space (df -h), DNS and GitHub access)."
        ask url "Paste another download URL or a local .tar.gz path (empty = cancel): "
        if [ -z "$url" ]; then
            return 1
        fi
    done

    if ! tar -xzf "$tmp" -C "$INSTALL_DIR"; then
        echo "Extraction failed."
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    chmod +x "$INSTALL_DIR/backhaul" 2>/dev/null
    if ! "$INSTALL_DIR/backhaul" -v >/dev/null 2>&1; then
        echo "The extracted binary does not run on this machine (wrong architecture or archive layout)."
        return 1
    fi
    echo "Backhaul binary installed: $("$INSTALL_DIR/backhaul" -v 2>/dev/null | head -n1)"
    return 0
}

ensure_tls_cert_local() {
    # wss/wssmux require tls_cert/tls_key on the server side.
    if [ -s "$INSTALL_DIR/server.crt" ] && [ -s "$INSTALL_DIR/server.key" ]; then
        return 0
    fi
    ensure_cmds openssl || return 1
    echo "Generating self-signed TLS certificate for wss/wssmux..."
    if ! openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" \
            -days 3650 -subj "/CN=backhaul" >/dev/null 2>&1; then
        echo "openssl could not generate the certificate."
        rm -f "$INSTALL_DIR/server.key" "$INSTALL_DIR/server.crt"
        return 1
    fi
    chmod 600 "$INSTALL_DIR/server.key"
    return 0
}

# ============================================================
# Unit / toml lookups
# ============================================================

list_backhaul_units() {
    # from the unit FILES (units that are disabled + not loaded would not show up in `systemctl list-units`)
    local f
    for f in "$SYSTEMD_DIR"/backhaul-*.service; do
        [ -e "$f" ] && basename "$f"
    done
}

list_tunnel_units() {
    # tunnel services only (no MTU / MSS / watchdog helper units)
    list_backhaul_units | grep -vE '^backhaul-(mtu|mss|watchdog)\.service$' || true
}

unit_toml() {
    # prints the .toml path a backhaul unit was started with
    local f="$SYSTEMD_DIR/$1"
    [ -f "$f" ] || return 0
    sed -n 's/^ExecStart=.*[[:space:]]-c[[:space:]]\{1,\}\([^[:space:]]\{1,\}\.toml\).*$/\1/p' "$f" | head -n1
}

toml_str() {
    # toml_str <file> <key>  -> string value
    grep -E "^$2[[:space:]]*=" "$1" 2>/dev/null | head -n1 | cut -d'"' -f2
}

toml_tunnel_port() {
    grep -E '^(bind_addr|remote_addr)[[:space:]]*=' "$1" 2>/dev/null | head -n1 | grep -oE '[0-9]+"$' | tr -d '"'
}

toml_family() {
    local addr
    addr=$(grep -E '^(bind_addr|remote_addr)[[:space:]]*=' "$1" 2>/dev/null | head -n1 | cut -d'"' -f2)
    if [[ "$addr" == \[* ]]; then echo 6; else echo 4; fi
}

unit_conn_count() {
    # number of established tunnel connections that belong to this unit
    local unit="$1" toml port pid
    toml=$(unit_toml "$unit")
    if [ -z "$toml" ] || [ ! -f "$toml" ]; then echo 0; return 0; fi
    port=$(toml_tunnel_port "$toml")
    if [ -z "$port" ]; then echo 0; return 0; fi
    if grep -q '^\[server\]' "$toml"; then
        ss -H -tn state established "( sport = :${port} )" 2>/dev/null | grep -c .
    else
        pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
        if [ -z "$pid" ] || [ "$pid" = "0" ]; then echo 0; return 0; fi
        ss -H -tnp state established "( dport = :${port} )" 2>/dev/null | grep -c "pid=${pid},"
    fi
    return 0
}

# ---------- ports ----------

port_owner() {
    # name of the process listening on a TCP port (empty if free / unknown)
    ss -H -ltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | sed 's/users:(("//; s/"$//'
}

ports_conflict_ok() {
    # ports_conflict_ok spec... — warns about ports already used by OTHER programs. 0 = ok / confirmed.
    local spec owner bad=0
    for spec in "$@"; do
        [[ "$spec" =~ ^[0-9]+$ ]] || continue
        if ss -H -ltn "( sport = :${spec} )" 2>/dev/null | grep -q .; then
            owner=$(port_owner "$spec")
            if [ "$owner" != "backhaul" ]; then
                echo "  Port ${spec} is already in use by '${owner:-another program}'."
                bad=1
            fi
        fi
    done
    if [ "$bad" = "1" ]; then
        echo "  Backhaul's server exits when it cannot bind one of its ports (crash loop)."
        ask_yn "Continue anyway?" n
        return $?
    fi
    return 0
}

collect_reserved_ports() {
    local toml addr port e spec
    local -a out=()
    for toml in "$INSTALL_DIR"/*.toml; do
        [ -f "$toml" ] || continue
        grep -q '^\[server\]' "$toml" || continue
        addr=$(toml_str "$toml" bind_addr)
        port=${addr##*:}
        [[ "$port" =~ ^[0-9]+$ ]] && out+=("$port")
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            spec=$(entry_local_spec "$e")
            [[ "$spec" =~ ^[0-9]+(-[0-9]+)?$ ]] && out+=("$spec")
        done < <(sed -n '/^ports = \[/,/^\]/p' "$toml" | grep -oE '"[^"]+"' | tr -d '"')
    done
    [ "${#out[@]}" -eq 0 ] && return 0
    printf '%s\n' "${out[@]}" | sort -u | paste -sd, -
}

update_reserved_ports() {
    # keep tunnel + inbound ports out of the ephemeral pool (Backhaul also widens the pool to 1024-65535)
    local ours cur merged conf="/etc/sysctl.d/96-backhaul-reserved.conf"
    ours=$(collect_reserved_ports)
    if [ -z "$ours" ]; then
        rm -f "$conf"
        return 0
    fi
    cur=$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null)
    merged=$(printf '%s\n' "${cur}${cur:+,}${ours}" | tr ',' '\n' | grep -v '^$' | sort -u | paste -sd, -)
    sysctl -w "net.ipv4.ip_local_reserved_ports=${merged}" >/dev/null 2>&1 || return 1
    echo "net.ipv4.ip_local_reserved_ports=${merged}" > "$conf"
    return 0
}

prepare_ipv6() {
    # Make sure IPv6 is enabled in the kernel and listeners are dual-stack.
    # Returns 1 if the user wants to go back (no global IPv6 on this host).
    local conf="/etc/sysctl.d/98-backhaul-ipv6.conf"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1
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

ask_ip_version() {
    # sets global IP_MODE to 4 or 6
    local prompt="$1" c
    echo ""
    echo "$prompt"
    echo "  1) IPv4"
    echo "  2) IPv6"
    ask c "Enter choice [1-2] (default 1): " "1"
    case "$c" in
        2) IP_MODE=6 ;;
        *) IP_MODE=4 ;;
    esac
}

# ============================================================
# Path MTU / MSS  (the fix for "ping ok, data stalls")
# ============================================================

mss_load_env() {
    MSS_V6=$DEFAULT_MSS_V6
    MSS_V4=$DEFAULT_MSS_V4
    # shellcheck disable=SC1090
    [ -f "$MSS_ENV" ] && . "$MSS_ENV"
}

mss_save_env() {
    mkdir -p "$INSTALL_DIR"
    cat > "$MSS_ENV" << EOF
MSS_V6=${MSS_V6}
MSS_V4=${MSS_V4}
EOF
}

mss_from_mtu() {
    # mss_from_mtu <path-mtu> <4|6> -> MSS to use (MTU capped at MTU_CAP, IPv6 never below MTU 1280)
    local mtu="$1" fam="$2"
    [ "$mtu" -gt "$MTU_CAP" ] && mtu=$MTU_CAP
    if [ "$fam" = "6" ]; then
        [ "$mtu" -lt 1280 ] && mtu=1280
        echo $((mtu - 60))
    else
        echo $((mtu - 40))
    fi
}

pingdf() {
    # one "don't fragment" probe with <payload> bytes of ICMP data; 0 = at least one reply
    run_ping "$1" -n -c 3 -i 0.3 -W 2 -M do -s "$2" >/dev/null 2>&1
}

probe_pmtu() {
    # probe_pmtu <host> -> prints the path MTU (IP packet size that still gets an echo reply, both
    # directions). Prints nothing and returns 1 when it cannot be measured (ICMP echo blocked).
    local host="$1" hdr lo hi mid best l h dev
    if [[ "$host" == *:* ]]; then hdr=48; lo=1280; else hdr=28; lo=1200; fi
    hi=1500
    dev=$(ip route get "$host" 2>/dev/null | grep -oE 'dev [^ ]+' | head -n1 | awk '{print $2}')
    if [ -n "$dev" ] && [ -r "/sys/class/net/$dev/mtu" ]; then
        l=$(cat "/sys/class/net/$dev/mtu")
        [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -lt "$hi" ] && hi=$l
    fi
    run_ping "$host" -n -c 2 -W 2 -s 56 >/dev/null 2>&1 || return 1
    pingdf "$host" $((lo - hdr)) || return 1
    if [ "$hi" -le "$lo" ]; then echo "$lo"; return 0; fi
    if pingdf "$host" $((hi - hdr)); then echo "$hi"; return 0; fi
    best=$lo
    l=$((lo + 1))
    h=$((hi - 1))
    while [ "$l" -le "$h" ]; do
        mid=$(( (l + h) / 2 ))
        if pingdf "$host" $((mid - hdr)); then
            best=$mid
            l=$((mid + 1))
        else
            h=$((mid - 1))
        fi
    done
    echo "$best"
}

write_mss_script() {
    mkdir -p "$INSTALL_DIR"
    cat > "$MSS_SCRIPT" << 'MSSEOF'
#!/bin/bash
# Backhaul MSS clamp (path-MTU black-hole protection). Rebuilt from the *.toml files in this
# directory on every run, so it is idempotent:
#   mss.sh apply | remove | status
# Server config -> clamp the SYN-ACK of our tunnel listener   (protects data the Kharej sends us)
# Client config -> clamp our SYN towards the Iran server       (protects data the Iran server sends us)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN="BACKHAUL_MSS"
ICMP_CHAIN="BACKHAUL_ICMP"
MSS_V6=1220
MSS_V4=1360
# shellcheck disable=SC1091
[ -f "$DIR/mss.env" ] && . "$DIR/mss.env"

WAIT4=""
WAIT6=""
SERVER_PORTS=()
CLIENT_PEERS=()

have_ipt() {
    if [ "$1" = 6 ]; then command -v ip6tables >/dev/null 2>&1; else command -v iptables >/dev/null 2>&1; fi
}

init_wait() {
    local f bin w
    for f in 4 6; do
        have_ipt "$f" || continue
        bin=iptables
        [ "$f" = 6 ] && bin=ip6tables
        w=""
        if "$bin" -w 10 -S >/dev/null 2>&1; then
            w="-w 10"
        elif "$bin" -w -S >/dev/null 2>&1; then
            w="-w"
        fi
        if [ "$f" = 4 ]; then WAIT4="$w"; else WAIT6="$w"; fi
    done
}

ipt() {
    local fam="$1"
    shift
    # shellcheck disable=SC2086
    if [ "$fam" = 6 ]; then ip6tables $WAIT6 "$@"; else iptables $WAIT4 "$@"; fi
}

parse_tomls() {
    local toml addr port host
    for toml in "$DIR"/*.toml; do
        [ -f "$toml" ] || continue
        if grep -q '^\[server\]' "$toml"; then
            addr=$(grep -E '^bind_addr[[:space:]]*=' "$toml" | head -n1 | cut -d'"' -f2)
            port=${addr##*:}
            [[ "$port" =~ ^[0-9]+$ ]] && SERVER_PORTS+=("$port")
        elif grep -q '^\[client\]' "$toml"; then
            addr=$(grep -E '^remote_addr[[:space:]]*=' "$toml" | head -n1 | cut -d'"' -f2)
            port=${addr##*:}
            host=${addr%:*}
            host=${host#\[}
            host=${host%\]}
            if [[ "$port" =~ ^[0-9]+$ ]] && [ -n "$host" ]; then
                CLIENT_PEERS+=("$host $port")
            fi
        fi
    done
}

remove_rules() {
    local fam
    for fam in 6 4; do
        have_ipt "$fam" || continue
        ipt "$fam" -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null
        ipt "$fam" -t mangle -F "$CHAIN" 2>/dev/null
        ipt "$fam" -t mangle -X "$CHAIN" 2>/dev/null
        ipt "$fam" -D INPUT -j "$ICMP_CHAIN" 2>/dev/null
        ipt "$fam" -F "$ICMP_CHAIN" 2>/dev/null
        ipt "$fam" -X "$ICMP_CHAIN" 2>/dev/null
    done
}

apply() {
    local fam mss p peer host port hfam rc=0 done_any=0
    parse_tomls
    init_wait
    if [ "${#SERVER_PORTS[@]}" -eq 0 ] && [ "${#CLIENT_PEERS[@]}" -eq 0 ]; then
        remove_rules
        echo "No tunnel configs in $DIR — nothing to clamp."
        return 0
    fi
    for fam in 6 4; do
        if ! have_ipt "$fam"; then
            echo "IPv$fam: iptables binary not found — skipped."
            continue
        fi
        if ! ipt "$fam" -t mangle -S >/dev/null 2>&1; then
            echo "IPv$fam: netfilter mangle table not usable here — skipped."
            continue
        fi
        if [ "$fam" = 6 ]; then mss=$MSS_V6; else mss=$MSS_V4; fi

        ipt "$fam" -t mangle -N "$CHAIN" 2>/dev/null
        if ! ipt "$fam" -t mangle -F "$CHAIN"; then
            rc=1
            continue
        fi
        ipt "$fam" -t mangle -C OUTPUT -j "$CHAIN" 2>/dev/null || ipt "$fam" -t mangle -I OUTPUT 1 -j "$CHAIN" || rc=1

        for p in "${SERVER_PORTS[@]}"; do
            ipt "$fam" -t mangle -A "$CHAIN" -p tcp --sport "$p" --tcp-flags SYN,RST SYN \
                -j TCPMSS --set-mss "$mss" || rc=1
        done
        for peer in "${CLIENT_PEERS[@]}"; do
            read -r host port <<< "$peer"
            if [[ "$host" == *:* ]]; then hfam=6; else hfam=4; fi
            [ "$hfam" = "$fam" ] || continue
            ipt "$fam" -t mangle -A "$CHAIN" -p tcp -d "$host" --dport "$port" --tcp-flags SYN,RST SYN \
                -j TCPMSS --set-mss "$mss" || rc=1
        done

        # make sure the ICMP errors that normal PMTU discovery needs are never dropped locally
        ipt "$fam" -N "$ICMP_CHAIN" 2>/dev/null
        ipt "$fam" -F "$ICMP_CHAIN" 2>/dev/null
        if [ "$fam" = 6 ]; then
            ipt 6 -A "$ICMP_CHAIN" -p icmpv6 --icmpv6-type packet-too-big -j ACCEPT 2>/dev/null
        else
            ipt 4 -A "$ICMP_CHAIN" -p icmp --icmp-type fragmentation-needed -j ACCEPT 2>/dev/null
        fi
        ipt "$fam" -C INPUT -j "$ICMP_CHAIN" 2>/dev/null || ipt "$fam" -I INPUT 1 -j "$ICMP_CHAIN" 2>/dev/null

        echo "IPv$fam: MSS clamp active (MSS $mss)."
        done_any=1
    done
    [ "$done_any" = 1 ] || rc=1
    return $rc
}

status() {
    local fam
    init_wait
    for fam in 6 4; do
        have_ipt "$fam" || continue
        echo "--- IPv$fam  mangle/OUTPUT -> $CHAIN ---"
        ipt "$fam" -t mangle -L "$CHAIN" -n -v 2>&1 | sed 's/^/  /'
    done
}

case "${1:-apply}" in
    apply)  apply ;;
    remove) init_wait; remove_rules; echo "MSS clamp rules removed." ;;
    status) status ;;
    *) echo "usage: $0 apply|remove|status"; exit 2 ;;
esac
MSSEOF
    chmod +x "$MSS_SCRIPT"
}

write_mss_unit() {
    cat > "$SYSTEMD_DIR/backhaul-mss.service" << EOF
[Unit]
Description=Backhaul TCP MSS clamp (path-MTU black-hole protection)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${MSS_SCRIPT} apply
ExecStop=/bin/bash ${MSS_SCRIPT} remove

[Install]
WantedBy=multi-user.target
EOF
}

mss_refresh() {
    # re-apply the rules after a toml/port change (no-op if MSS protection was never installed)
    [ -f "$MSS_SCRIPT" ] && bash "$MSS_SCRIPT" apply >/dev/null 2>&1
    return 0
}

mss_active() {
    ip6tables -t mangle -S BACKHAUL_MSS 2>/dev/null | grep -q TCPMSS \
        || iptables -t mangle -S BACKHAUL_MSS 2>/dev/null | grep -q TCPMSS
}

sync_toml_mss() {
    # keep the native `mss =` line of tcp/tcpmux configs in step with mss.env. Returns 0 if any file changed.
    local toml tr fam val changed=1
    mss_load_env
    for toml in "$INSTALL_DIR"/*.toml; do
        [ -f "$toml" ] || continue
        tr=$(toml_str "$toml" transport)
        case "$tr" in tcp|tcpmux) ;; *) continue ;; esac
        fam=$(toml_family "$toml")
        if [ "$fam" = "6" ]; then val=$MSS_V6; else val=$MSS_V4; fi
        if grep -qE '^mss[[:space:]]*=' "$toml"; then
            sed -i -E "s/^mss[[:space:]]*=.*/mss = ${val}/" "$toml"
        else
            sed -i -E "/^transport[[:space:]]*=/a mss = ${val}" "$toml"
        fi
        changed=0
    done
    return $changed
}

setup_mss_protection() {
    mss_load_env
    ensure_cmds iptables ip6tables >/dev/null 2>&1
    write_mss_script
    write_mss_unit
    mss_save_env
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
    echo "net.ipv4.tcp_mtu_probing=1" > /etc/sysctl.d/97-backhaul-mtu.conf
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable backhaul-mss.service >/dev/null 2>&1
    echo ""
    echo "=== MSS / path-MTU protection ==="
    if bash "$MSS_SCRIPT" apply; then
        echo "Done: tunnel connections now use small, safe segments (survives reboot via backhaul-mss.service)."
    else
        warn "the iptables MSS clamp could not be installed on this host."
        echo "         Falling back to tcp_mtu_probing=2 (works without ICMP, slightly slower ramp-up)."
        sysctl -w net.ipv4.tcp_mtu_probing=2 >/dev/null 2>&1
        echo "net.ipv4.tcp_mtu_probing=2" > /etc/sysctl.d/97-backhaul-mtu.conf
    fi
}

peer_list() {
    # peer_list -> prints the other end(s): Kharej = the Iran servers from the client configs;
    # otherwise asks for an address.
    local u toml peer p
    local -a peers=()
    for u in $(list_tunnel_units); do
        toml=$(unit_toml "$u")
        [ -f "$toml" ] || continue
        if grep -q '^\[client\]' "$toml"; then
            peer=$(toml_str "$toml" remote_addr)
            peer=${peer%:*}
            peer=${peer#\[}
            peer=${peer%\]}
            [ -n "$peer" ] && peers+=("$peer")
        fi
    done
    if [ "${#peers[@]}" -eq 0 ]; then
        ask p "IPv4/IPv6 address of the OTHER server to test against (Enter = skip): " >&2
        p=$(clean_ip_input "$p")
        [ -n "$p" ] && peers+=("$p")
    fi
    [ "${#peers[@]}" -gt 0 ] && printf '%s\n' "${peers[@]}"
    return 0
}

detect_and_apply_mss() {
    local peer pm m fam best6="" best4=""
    ensure_cmds ping ip >/dev/null 2>&1
    while IFS= read -r peer; do
        [ -n "$peer" ] || continue
        echo "Probing path MTU to ${peer} (up to ~30s)..."
        pm=$(probe_pmtu "$peer")
        if [ -z "$pm" ]; then
            echo "  could not measure (no ICMP echo reply) — skipped."
            continue
        fi
        if [[ "$peer" == *:* ]]; then fam=6; else fam=4; fi
        m=$(mss_from_mtu "$pm" "$fam")
        echo "  path MTU ${pm}  ->  MSS ${m}"
        if [ "$fam" = "6" ]; then
            if [ -z "$best6" ] || [ "$m" -lt "$best6" ]; then best6=$m; fi
        else
            if [ -z "$best4" ] || [ "$m" -lt "$best4" ]; then best4=$m; fi
        fi
    done < <(peer_list)
    if [ -z "$best6" ] && [ -z "$best4" ]; then
        echo "Nothing could be measured — MSS left unchanged."
        return 0
    fi
    mss_load_env
    [ -n "$best6" ] && MSS_V6=$best6
    [ -n "$best4" ] && MSS_V4=$best4
    setup_mss_protection
    sync_toml_mss && echo "tcp/tcpmux configs updated — restart those services (menu 4) to use the new mss."
}

set_mss_manually() {
    local v6 v4
    mss_load_env
    ask v6 "IPv6 MSS (1100-1440) [${MSS_V6}]: " "$MSS_V6"
    ask v4 "IPv4 MSS (1100-1460) [${MSS_V4}]: " "$MSS_V4"
    if ! [[ "$v6" =~ ^[0-9]+$ ]] || [ "$v6" -lt 1100 ] || [ "$v6" -gt 1440 ]; then echo "Invalid IPv6 MSS."; return 0; fi
    if ! [[ "$v4" =~ ^[0-9]+$ ]] || [ "$v4" -lt 1100 ] || [ "$v4" -gt 1460 ]; then echo "Invalid IPv4 MSS."; return 0; fi
    MSS_V6=$v6
    MSS_V4=$v4
    setup_mss_protection
    sync_toml_mss && echo "tcp/tcpmux configs updated — restart those services (menu 4) to use the new mss."
}

diagnose_tunnel() {
    local iface mtu u toml port peer pm fam m cur l out
    ensure_cmds ip ss ping >/dev/null 2>&1
    iface=$(detect_default_iface)
    mtu=$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null)
    mss_load_env
    echo ""
    echo "=== Network ==="
    echo "Default interface : ${iface} (MTU ${mtu:-?})"
    echo "Global IPv6       : $(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n3 | tr '\n' ' ')"
    echo "IPv6 default route: $(ip -6 route show default 2>/dev/null | head -n1)"
    echo "tcp_mtu_probing   : $(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    echo "congestion / qdisc: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "Configured MSS    : IPv6=${MSS_V6}  IPv4=${MSS_V4}"

    echo ""
    echo "=== MSS clamp rules (packet counters grow when a tunnel (re)connects) ==="
    if [ -f "$MSS_SCRIPT" ]; then bash "$MSS_SCRIPT" status; else echo "Not installed — use menu 7 -> 1."; fi

    echo ""
    echo "=== Live tunnel sockets (mss / pmtu / rtt / retrans) ==="
    for u in $(list_tunnel_units); do
        toml=$(unit_toml "$u")
        [ -f "$toml" ] || continue
        port=$(toml_tunnel_port "$toml")
        echo "--- $u (port $port) ---"
        ss -H -tin state established "( sport = :${port} or dport = :${port} )" 2>/dev/null | paste - - | head -n 6 | while IFS= read -r l; do
            peer=$(echo "$l" | awk '{print $4}')
            echo "  ${peer}   $(echo "$l" | grep -oE '(rtt|mss|pmtu|retrans|cwnd|unacked):[^ ]+' | tr '\n' ' ')"
        done
    done

    echo ""
    echo "=== Path to the other server ==="
    while IFS= read -r peer; do
        [ -n "$peer" ] || continue
        echo "--- ${peer} ---"
        if ! ping_ok "$peer" 3 2; then
            echo "  No ICMP echo reply: cannot measure (ICMP filtered or host unreachable)."
            echo "  The MSS clamp still protects the tunnel; if data still stalls, lower the MSS (menu 7 -> 3, e.g. 1160)."
            continue
        fi
        pm=$(probe_pmtu "$peer")
        if [[ "$peer" == *:* ]]; then fam=6; cur=$MSS_V6; else fam=4; cur=$MSS_V4; fi
        if [ -n "$pm" ]; then
            m=$(mss_from_mtu "$pm" "$fam")
            echo "  Path MTU (echo, both directions): ${pm}   -> MSS that fits: ${m}"
            if [ "$cur" -le "$m" ]; then
                echo "  OK: configured MSS ${cur} fits the measured path."
            else
                echo "  PROBLEM: configured MSS ${cur} is larger than the path allows (${m}) -> menu 7 -> 2."
            fi
        else
            echo "  Path MTU could not be measured."
        fi
        out=$(run_ping "$peer" -n -c 20 -i 0.2 -W 2 -s 56 2>&1 | grep -E 'packet loss')
        echo "  small packets (56B) : ${out:-no result}"
        if [ "$fam" = "6" ]; then l=1232; else l=1372; fi
        out=$(run_ping "$peer" -n -c 20 -i 0.2 -W 2 -M do -s "$l" 2>&1 | grep -E 'packet loss')
        echo "  large packets (${l}B): ${out:-no result}"
        echo "  (loss only on the large packets = path-MTU / size filtering problem)"
    done < <(peer_list)
    echo ""
}

mtu_menu() {
    local c
    while true; do
        mss_load_env
        echo ""
        echo "=== MTU / MSS  (fixes 'ping ok but data stalls / pages load half', mostly on IPv6) ==="
        echo "MSS clamp: $(mss_active && echo ACTIVE || echo "not active")   (IPv6 MSS ${MSS_V6}, IPv4 MSS ${MSS_V4})"
        echo "1) Apply / refresh the MSS clamp now (recommended)"
        echo "2) Detect the real path MTU to the other server and use it"
        echo "3) Set MSS manually"
        echo "4) Diagnostics (path MTU, packet loss, live tunnel sockets)"
        echo "5) Remove the MSS clamp"
        echo "0) Back"
        ask c "Select: "
        case "$c" in
            1) setup_mss_protection ;;
            2) detect_and_apply_mss ;;
            3) set_mss_manually ;;
            4) diagnose_tunnel ;;
            5) if [ -f "$MSS_SCRIPT" ]; then bash "$MSS_SCRIPT" remove; fi
               systemctl disable backhaul-mss.service >/dev/null 2>&1
               echo "Removed (tcp/tcpmux configs keep their native mss line)." ;;
            0) return ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ============================================================
# System tuning: MTU cap, DNS, ulimits, optimizer
# ============================================================

ensure_mtu() {
    echo ""
    echo "=== Capping the NIC MTU at ${MTU_CAP} (only ever lowers it) ==="
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/mtu.sh" << 'MTUEOF'
#!/bin/bash
CAP="${1:-1400}"
iface=$(ip -o -4 route show to default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
[ -z "$iface" ] && iface=$(ip -o -6 route show to default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
[ -z "$iface" ] && exit 0
cur=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo 0)
if [ "$cur" -gt "$CAP" ]; then
    ip link set dev "$iface" mtu "$CAP" && echo "MTU of $iface lowered from $cur to $CAP"
else
    echo "MTU of $iface is $cur (<= $CAP): left unchanged"
fi
exit 0
MTUEOF
    chmod +x "$INSTALL_DIR/mtu.sh"

    cat > "$SYSTEMD_DIR/backhaul-mtu.service" << EOF
[Unit]
Description=Cap NIC MTU at ${MTU_CAP} for the Backhaul tunnel (never raises it)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/mtu.sh ${MTU_CAP}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable backhaul-mtu.service >/dev/null 2>&1
    bash "$INSTALL_DIR/mtu.sh" "$MTU_CAP"
}

ensure_dns() {
    echo ""
    echo "=== Setting DNS (Cloudflare / Google) ==="
    local n ok4=0 ok6=0
    local -a lines=()
    mkdir -p "$INSTALL_DIR"
    # only use the IP families this host can actually reach (a dead first nameserver = 5s per lookup)
    for n in 1.1.1.1 1.0.0.1 8.8.8.8; do
        if ping_ok "$n" 1 2; then ok4=1; break; fi
    done
    for n in 2606:4700:4700::1111 2001:4860:4860::8888; do
        if ping_ok "$n" 1 2; then ok6=1; break; fi
    done
    if [ "$ok4" = 0 ] && [ "$ok6" = 0 ]; then
        echo "None of the public resolvers answered ping — DNS left untouched."
        return 0
    fi
    [ "$ok4" = 1 ] && lines+=("nameserver 1.1.1.1" "nameserver 1.0.0.1" "nameserver 8.8.8.8")
    [ "$ok6" = 1 ] && lines+=("nameserver 2606:4700:4700::1111" "nameserver 2001:4860:4860::8888")

    chattr -i /etc/resolv.conf 2>/dev/null
    # back up the original once, so uninstall can restore it
    if [ ! -f "$INSTALL_DIR/resolv.conf.orig" ] && [ ! -f "$INSTALL_DIR/resolv.conf.link" ]; then
        if [ -L /etc/resolv.conf ]; then
            readlink /etc/resolv.conf > "$INSTALL_DIR/resolv.conf.link"
        elif [ -f /etc/resolv.conf ]; then
            cp /etc/resolv.conf "$INSTALL_DIR/resolv.conf.orig"
        fi
    fi
    if [ -L /etc/resolv.conf ]; then
        # usually systemd-resolved's stub: replace the symlink with a static file so it isn't reset
        rm -f /etc/resolv.conf
    fi
    {
        printf '%s\n' "${lines[@]}"
        echo "options timeout:2 attempts:2"
    } > /etc/resolv.conf
    # Best-effort: stop NetworkManager / dhcp clients from overwriting it back.
    chattr +i /etc/resolv.conf 2>/dev/null
    echo "DNS set (${lines[*]//nameserver /}). /etc/resolv.conf is now static/locked (chattr +i); uninstall can restore it."
}

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
    ulimit -n 1048576 2>/dev/null
    echo "File descriptor limits raised (the services also get LimitNOFILE=1048576 from systemd)."
}

optimize_system() {
    local conf="/etc/sysctl.d/99-backhaul-tunnel.conf" tmp kv key
    local -a skipped=()
    local -a SETTINGS=(
        "net.core.default_qdisc=fq"
        "net.ipv4.tcp_congestion_control=bbr"
        "net.core.somaxconn=65535"
        "net.core.netdev_max_backlog=250000"
        "net.core.rmem_max=134217728"
        "net.core.wmem_max=134217728"
        "net.ipv4.tcp_rmem=4096 87380 134217728"
        "net.ipv4.tcp_wmem=4096 65536 134217728"
        "net.ipv4.tcp_keepalive_time=60"
        "net.ipv4.tcp_keepalive_intvl=10"
        "net.ipv4.tcp_keepalive_probes=6"
        "net.ipv4.tcp_fin_timeout=15"
        "net.ipv4.tcp_mtu_probing=1"
        "net.ipv4.tcp_window_scaling=1"
        "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_sack=1"
        "net.ipv4.tcp_retries2=8"
        "net.ipv4.tcp_syn_retries=2"
        "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_no_metrics_save=1"
    )
    echo ""
    echo "=== System Optimization ==="
    echo "Interface: $(detect_default_iface)"
    modprobe tcp_bbr >/dev/null 2>&1

    # keep fs.file-max if ensure_ulimits wrote it earlier; rebuild the rest from what the kernel accepts
    tmp=$(mktemp)
    grep "^fs.file-max" "$conf" 2>/dev/null > "$tmp"
    {
        echo "# Written by the Backhaul tunnel manager ${VERSION} — only keys the kernel accepted."
    } >> "$tmp"
    for kv in "${SETTINGS[@]}"; do
        key=${kv%%=*}
        if sysctl -w "$kv" > /dev/null 2>&1; then
            echo "$kv" >> "$tmp"
        else
            skipped+=("$key")
        fi
    done
    mv "$tmp" "$conf"
    chmod 644 "$conf"

    if grep -q '^net.ipv4.tcp_congestion_control=bbr' "$conf"; then
        echo "BBR congestion control enabled."
        echo "tcp_bbr" > /etc/modules-load.d/backhaul-bbr.conf 2>/dev/null
    else
        echo "BBR is not available on this kernel — staying on the default congestion control."
    fi
    [ "${#skipped[@]}" -gt 0 ] && echo "Not supported by this kernel (skipped): ${skipped[*]}"
    echo "Saved to $conf (persists across reboots)."
    echo "Note: Backhaul itself also re-applies a few sysctls (buffers, tcp_tw_reuse, port range...) at every start."

    update_reserved_ports
    ensure_ulimits
    ensure_mtu
    ensure_dns

    echo ""
    echo "Optimization complete."
}

revert_tuning() {
    chattr -i /etc/resolv.conf 2>/dev/null
    if [ -f "$INSTALL_DIR/resolv.conf.link" ]; then
        rm -f /etc/resolv.conf
        ln -s "$(cat "$INSTALL_DIR/resolv.conf.link")" /etc/resolv.conf
        echo "DNS: /etc/resolv.conf symlink restored."
    elif [ -f "$INSTALL_DIR/resolv.conf.orig" ]; then
        cat "$INSTALL_DIR/resolv.conf.orig" > /etc/resolv.conf
        echo "DNS: original /etc/resolv.conf restored."
    fi
    rm -f /etc/sysctl.d/99-backhaul-tunnel.conf /etc/sysctl.d/98-backhaul-ipv6.conf \
          /etc/sysctl.d/97-backhaul-mtu.conf /etc/sysctl.d/96-backhaul-reserved.conf \
          /etc/modules-load.d/backhaul-bbr.conf
    sed -i '/^# backhaul-tunnel limits$/,/^\* hard nofile 1048576$/d' /etc/security/limits.conf 2>/dev/null
    echo "Sysctl drop-ins and limits.conf entries removed (live values are reset at the next reboot)."
}

# ============================================================
# Watchdog (health check + auto-restart with back-off)
# ============================================================

setup_watchdog() {
    echo ""
    echo "=== Installing Watchdog ==="
    mkdir -p "$WATCHDOG_STATE_DIR"

    cat > "$WATCHDOG_SCRIPT" << 'WDEOF'
#!/bin/bash
# Backhaul watchdog — runs every 10s via backhaul-watchdog.timer
# Restarts a tunnel service when
#   1) it is not active, or
#   2) it is active but has had ZERO established tunnel connections for longer than the idle threshold.
# Restarts back off exponentially (30s, 60s, 120s ... max 600s) so a peer that is down does not turn into
# a restart storm; the counter resets as soon as a connection is seen again.
# Skipped: units that are disabled, and units stopped from the manager menu ("paused").
#
# Works with IPv4 and IPv6 tunnels and with several tunnel services on one machine: each service is
# judged only by the connections that belong to its own process.

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$INSTALL_DIR/watchdog-state"
LOG_FILE="$INSTALL_DIR/watchdog.log"
SYSTEMD_DIR="/etc/systemd/system"
BASE_IDLE=30
MAX_IDLE=600

mkdir -p "$STATE_DIR"

# keep the log small
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

log() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

for unit_file in "$SYSTEMD_DIR"/backhaul-*.service; do
    [ -e "$unit_file" ] || continue
    unit=$(basename "$unit_file")
    case "$unit" in
        backhaul-mtu.service|backhaul-mss.service|backhaul-watchdog.service) continue ;;
    esac
    [ -e "$STATE_DIR/${unit}.paused" ] && continue
    systemctl is-enabled --quiet "$unit" 2>/dev/null || continue

    now=$(date +%s)
    state_file="$STATE_DIR/${unit}.state"      # "<last_ok_epoch> <consecutive_restarts>"
    last_ok=""
    fails=""
    [ -f "$state_file" ] && read -r last_ok fails < "$state_file"
    last_ok=${last_ok:-$now}
    fails=${fails:-0}

    if ! systemctl is-active --quiet "$unit"; then
        systemctl reset-failed "$unit" 2>/dev/null
        systemctl restart "$unit" 2>/dev/null
        log "restarted $unit (service was inactive)"
        echo "$now $fails" > "$state_file"
        continue
    fi

    toml=$(sed -n 's/^ExecStart=.*[[:space:]]-c[[:space:]]\{1,\}\([^[:space:]]\{1,\}\.toml\).*$/\1/p' "$unit_file" | head -n1)
    { [ -z "$toml" ] || [ ! -f "$toml" ]; } && continue

    # Tunnel port = last number of bind_addr (server) or remote_addr (client).
    # Handles "0.0.0.0:443", "[::]:443", "1.2.3.4:443" and "[2001:db8::1]:443".
    port=$(grep -E '^(bind_addr|remote_addr)[[:space:]]*=' "$toml" | head -n1 | grep -oE '[0-9]+"$' | tr -d '"')
    [ -z "$port" ] && continue
    pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
    { [ -z "$pid" ] || [ "$pid" = "0" ]; } && continue

    if grep -q '^\[server\]' "$toml" 2>/dev/null; then
        # Iran side: connections accepted on the tunnel port
        active_conns=$(ss -H -tn state established "( sport = :${port} )" 2>/dev/null | grep -c .)
    else
        # Kharej side: connections of THIS service's process to the tunnel port
        active_conns=$(ss -H -tnp state established "( dport = :${port} )" 2>/dev/null | grep -c "pid=${pid},")
    fi

    if [ "${active_conns:-0}" -gt 0 ]; then
        echo "$now 0" > "$state_file"
        continue
    fi

    [ "$fails" -gt 5 ] && fails=5
    threshold=$(( BASE_IDLE << fails ))
    [ "$threshold" -gt "$MAX_IDLE" ] && threshold=$MAX_IDLE
    idle=$(( now - last_ok ))
    if [ "$idle" -ge "$threshold" ]; then
        systemctl restart "$unit" 2>/dev/null
        log "restarted $unit (no established connections for ${idle}s on port ${port}; next retry after ~$(( BASE_IDLE << (fails + 1) ))s if still down)"
        echo "$now $(( fails + 1 ))" > "$state_file"
    else
        echo "$last_ok $fails" > "$state_file"
    fi
done
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$SYSTEMD_DIR/backhaul-watchdog.service" << EOF
[Unit]
Description=Backhaul Watchdog (health check / auto-restart)

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF

    cat > "$SYSTEMD_DIR/backhaul-watchdog.timer" << 'EOF'
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
    echo "Watchdog installed — checks every 10s; restarts a tunnel after ${WATCHDOG_IDLE_THRESHOLD}s without connections (then 60s, 120s ... up to 10 min)."
    echo "Log: $WATCHDOG_LOG"
}

# ============================================================
# Status
# ============================================================

show_status() {
    local units tunnel_units u toml addr state warn_txt found_warning n

    units=$(list_backhaul_units)
    tunnel_units=$(list_tunnel_units)

    if [ -n "$tunnel_units" ]; then
        echo ""
        echo "=== Tunnel summary (service / state / tunnel connections / address) ==="
        for u in $tunnel_units; do
            toml=$(unit_toml "$u")
            addr=""
            [ -n "$toml" ] && addr=$(toml_str "$toml" bind_addr)
            [ -n "$toml" ] && [ -z "$addr" ] && addr=$(toml_str "$toml" remote_addr)
            state=$(systemctl is-active "$u" 2>/dev/null)
            n=$(unit_conn_count "$u")
            printf '%-55s %-10s %-5s %s\n' "$u" "$state" "$n" "$addr"
        done
    fi

    echo ""
    echo "=== MSS / path-MTU protection ==="
    mss_load_env
    if mss_active; then
        echo "MSS clamp: ACTIVE  (IPv6 MSS ${MSS_V6}, IPv4 MSS ${MSS_V4})"
    else
        echo "MSS clamp: NOT active — enable it in menu 7 (needed for stable IPv6 tunnels)."
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
        warn_txt=$(journalctl -u "$u" -n 20 --no-pager 2>/dev/null | grep -iE "invalid security token|error|failed|unreachable|refused" | tail -n 3)
        if [ -n "$warn_txt" ]; then
            found_warning=1
            echo "--- $u ---"
            echo "$warn_txt"
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
        echo "If the tunnel connects but data stalls: menu 7 (MSS clamp + diagnostics)."
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
    local TOML_FILE PCHOICE SERVICE_NAME NEWPORT OLDPORT p i found line_no end_line tmp spec
    local -a tomls=() CUR_PORTS=() NEW_PORTS=()

    mapfile -t tomls < <(ls "$INSTALL_DIR"/iran*.toml 2>/dev/null)
    if [ "${#tomls[@]}" -eq 0 ]; then
        echo "No Iran server config found on this machine. Run this on the Iran server."
        return
    fi

    echo "Found config(s):"
    choose TOML_FILE "Config" "${tomls[@]}" || return

    mapfile -t CUR_PORTS < <(sed -n '/^ports = \[/,/^\]/p' "$TOML_FILE" | grep -oE '"[^"]+"' | tr -d '"')

    echo ""
    echo "Current ports:"
    for p in "${CUR_PORTS[@]}"; do
        echo "  - $p"
    done

    echo ""
    echo "1) Add a port"
    echo "2) Remove a port"
    ask PCHOICE "Choice [1-2]: "

    SERVICE_NAME="backhaul-$(basename "$TOML_FILE" .toml).service"

    if [ "$PCHOICE" = "1" ]; then
        ask NEWPORT "Port to add (e.g. 443, 443=8443, 1000-1010): "
        NEWPORT="${NEWPORT// /}"
        if [ -z "$NEWPORT" ]; then
            echo "Nothing entered."
            return
        fi
        if ! valid_port_entry "$NEWPORT"; then
            echo "Invalid entry. Allowed: 443 | 4000=5000 | 1000-1010 | 1000-1010:5201 | 443=1.1.1.1:5201 | 127.0.0.2:443=5201"
            return
        fi
        spec=$(entry_local_spec "$NEWPORT")
        ports_conflict_ok "$spec" || return
        CUR_PORTS+=("$NEWPORT")
        echo "Added port ${NEWPORT}."
    elif [ "$PCHOICE" = "2" ]; then
        ask OLDPORT "Port entry to remove (exactly as listed above): "
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

    update_reserved_ports
    rm -f "$WATCHDOG_STATE_DIR/${SERVICE_NAME}.paused"
    if systemctl restart "$SERVICE_NAME"; then
        echo "Restarted $SERVICE_NAME."
    else
        echo "Restart failed — see: journalctl -u ${SERVICE_NAME} -n 30"
    fi
}

# ============================================================
# Service management (start/stop/restart/logs/enable/disable/edit)
# ============================================================

manage_services() {
    local SERVICE_NAME TOML_FILE SCHOICE editor e
    local -a units=()
    mapfile -t units < <(list_tunnel_units)
    if [ "${#units[@]}" -eq 0 ]; then
        echo "No Backhaul tunnel services found on this server."
        return
    fi

    echo ""
    echo "Select a service to manage:"
    choose SERVICE_NAME "Service" "${units[@]}" || return

    TOML_FILE=$(unit_toml "$SERVICE_NAME")

    while true; do
        echo ""
        echo "=== $SERVICE_NAME ==="
        systemctl is-active --quiet "$SERVICE_NAME" && echo "Status: RUNNING" || echo "Status: STOPPED"
        systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && echo "Auto-start: enabled" || echo "Auto-start: disabled"
        echo ""
        echo "1) Start"
        echo "2) Stop   (the watchdog will leave it alone until you start it again)"
        echo "3) Restart"
        echo "4) Full status"
        echo "5) Live logs (Ctrl+C to return)"
        echo "6) Enable auto-start"
        echo "7) Disable auto-start"
        echo "8) View config"
        echo "9) Edit config"
        echo "10) Delete this service"
        echo "0) Back"
        ask SCHOICE "Select: "
        case "$SCHOICE" in
            1) rm -f "$WATCHDOG_STATE_DIR/${SERVICE_NAME}.paused"
               systemctl start "$SERVICE_NAME" && echo "Started." || echo "Start failed — see option 5 / journalctl -u ${SERVICE_NAME}" ;;
            2) mkdir -p "$WATCHDOG_STATE_DIR"; touch "$WATCHDOG_STATE_DIR/${SERVICE_NAME}.paused"
               systemctl stop "$SERVICE_NAME"; echo "Stopped." ;;
            3) rm -f "$WATCHDOG_STATE_DIR/${SERVICE_NAME}.paused"
               systemctl restart "$SERVICE_NAME" && echo "Restarted." || echo "Restart failed — see option 5 / journalctl -u ${SERVICE_NAME}" ;;
            4) systemctl status "$SERVICE_NAME" --no-pager -l ;;
            5) trap 'echo' INT
               journalctl -u "$SERVICE_NAME" -f
               trap - INT ;;
            6) systemctl enable "$SERVICE_NAME"; echo "Enabled." ;;
            7) systemctl disable "$SERVICE_NAME"; echo "Disabled." ;;
            8) if [ -n "$TOML_FILE" ] && [ -f "$TOML_FILE" ]; then cat "$TOML_FILE"; else echo "Config path not found."; fi ;;
            9) if [ -n "$TOML_FILE" ] && [ -f "$TOML_FILE" ]; then
                   editor="${EDITOR:-}"
                   if [ -z "$editor" ]; then
                       for e in nano vim vi; do
                           if command -v "$e" >/dev/null 2>&1; then editor="$e"; break; fi
                       done
                   fi
                   if [ -z "$editor" ]; then
                       echo "No editor found (install nano or set EDITOR)."
                   else
                       "$editor" "$TOML_FILE"
                       update_reserved_ports
                       mss_refresh
                       if ask_yn "Restart service to apply changes?" y; then
                           rm -f "$WATCHDOG_STATE_DIR/${SERVICE_NAME}.paused"
                           systemctl restart "$SERVICE_NAME" && echo "Restarted." || echo "Restart failed."
                       fi
                   fi
               else
                   echo "Config path not found."
               fi ;;
            10) if ask_yn "Delete $SERVICE_NAME and its config?" n; then
                    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
                    rm -f "$SYSTEMD_DIR/${SERVICE_NAME}"
                    [ -n "$TOML_FILE" ] && rm -f "$TOML_FILE"
                    rm -f "$WATCHDOG_STATE_DIR/${SERVICE_NAME}".*
                    systemctl daemon-reload
                    update_reserved_ports
                    mss_refresh
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
    local u revert=0
    if ! ask_yn "This will remove ALL Backhaul services (including watchdog / MSS / MTU units) on THIS server. Continue?" n; then
        echo "Cancelled."
        return
    fi
    if ask_yn "Also revert the system tuning done by this script (DNS lock, sysctl files, MTU cap, file limits)?" y; then
        revert=1
    fi

    [ -f "$MSS_SCRIPT" ] && bash "$MSS_SCRIPT" remove

    for u in $(list_backhaul_units); do
        systemctl disable --now "$u" >/dev/null 2>&1
        rm -f "$SYSTEMD_DIR/$u"
    done
    systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1
    rm -f "$SYSTEMD_DIR/backhaul-watchdog.timer" "$SYSTEMD_DIR/backhaul-watchdog.service"

    [ "$revert" = "1" ] && revert_tuning

    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    echo "Uninstalled."
}

# ============================================================
# Install: shared pieces
# ============================================================

write_service() {
    # $1 = unit name (without .service), $2 = description, $3 = toml path
    cat > "$SYSTEMD_DIR/$1.service" << EOF
[Unit]
Description=$2
After=network-online.target backhaul-mss.service
Wants=network-online.target backhaul-mss.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c $3
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-500
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_server_toml() {
    # $1 = toml path, $2 = bind_addr, $3 = mss (used by tcp/tcpmux), $4... = inbound port entries
    local toml="$1" bind="$2" mss="$3" i port
    shift 3
    local -a entries=("$@")
    {
        echo "[server]"
        echo "bind_addr = \"${bind}\""
        echo "transport = \"${TRANSPORT}\""
        echo "token = \"${TOKEN}\""
        echo "keepalive_period = 20"
        echo "nodelay = true"
        echo "channel_size = 16384"
        echo "heartbeat = 15"
        case "$TRANSPORT" in
            tcpmux|wsmux|wssmux) echo "mux_con = 8" ;;
        esac
        case "$TRANSPORT" in
            tcp|tcpmux) echo "mss = ${mss}" ;;
        esac
        case "$TRANSPORT" in
            wss|wssmux)
                echo "tls_cert = \"${INSTALL_DIR}/server.crt\""
                echo "tls_key = \"${INSTALL_DIR}/server.key\""
                ;;
        esac
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"warn\""
        echo ""
        echo "ports = ["
        for i in "${!entries[@]}"; do
            port=$(echo "${entries[i]}" | xargs)
            if [ $((i + 1)) -eq ${#entries[@]} ]; then
                echo "    \"${port}\""
            else
                echo "    \"${port}\","
            fi
        done
        echo "]"
    } > "$toml"
}

write_client_toml() {
    # $1 = toml path, $2 = remote_addr (already formatted, IPv6 in []), $3 = mss (used by tcp/tcpmux)
    local toml="$1" remote="$2" mss="$3"
    {
        echo "[client]"
        echo "remote_addr = \"${remote}\""
        echo "transport = \"${TRANSPORT}\""
        echo "token = \"${TOKEN}\""
        echo "connection_pool = 8"
        echo "aggressive_pool = true"
        echo "keepalive_period = 20"
        echo "nodelay = true"
        echo "retry_interval = 1"
        echo "dial_timeout = 10"
        case "$TRANSPORT" in
            tcp|tcpmux) echo "mss = ${mss}" ;;
        esac
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"warn\""
    } > "$toml"
}

# ============================================================
# Install: Iran server side
# ============================================================

setup_iran_server() {
    local bind_addr guess public_ip default_port port p spec mss unit
    local -a PORT_ARRAY=() BAD=() SPECS=()

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
    while true; do
        ask public_ip "This Iran server's public IPv${IP_MODE} (shown to you for the Kharej setup) [${guess}]: " "$guess"
        public_ip=$(clean_ip_input "$public_ip")
        if [ "$IP_MODE" = "6" ]; then
            valid_ipv6 "$public_ip" && break
            echo "Not a valid IPv6 address (example: 2001:db8::10)."
        else
            valid_ipv4 "$public_ip" && break
            echo "Not a valid IPv4 address (example: 203.0.113.10)."
        fi
    done

    # --- Tunnel port ---
    default_port=$(gen_port)
    while true; do
        ask TUNNEL_PORT "Tunnel port [${default_port}]: " "$default_port"
        if ! valid_port "$TUNNEL_PORT"; then
            echo "Invalid port (1-65535)."
            continue
        fi
        # a previous run of this same tunnel must not count as "in use"
        unit="backhaul-iran${TUNNEL_PORT}.service"
        if [ -f "$SYSTEMD_DIR/$unit" ]; then
            systemctl stop "$unit" >/dev/null 2>&1
        fi
        ports_conflict_ok "$TUNNEL_PORT" && break
    done

    # --- Inbound (user-facing) ports ---
    while true; do
        ask INBOUND_PORTS "Inbound ports on this Iran server (comma separated, e.g. 2050,2023 or 443=8443 or 1000-1010): "
        INBOUND_PORTS="${INBOUND_PORTS// /}"
        if [ -z "$INBOUND_PORTS" ]; then
            echo "Enter at least one port."
            continue
        fi
        IFS=',' read -ra PORT_ARRAY <<< "$INBOUND_PORTS"
        BAD=()
        SPECS=()
        for p in "${PORT_ARRAY[@]}"; do
            if valid_port_entry "$p"; then
                spec=$(entry_local_spec "$p")
                SPECS+=("$spec")
            else
                BAD+=("$p")
            fi
        done
        if [ "${#BAD[@]}" -gt 0 ]; then
            echo "Invalid entry: ${BAD[*]}"
            echo "Allowed: 443 | 4000=5000 | 1000-1010 | 1000-1010:5201 | 443=1.1.1.1:5201 | 127.0.0.2:443=5201"
            echo "(Backhaul cannot forward to IPv6 literal targets.)"
            continue
        fi
        ports_conflict_ok "${SPECS[@]}" && break
    done

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        ensure_tls_cert_local || return 1
    fi

    if [ "$IP_MODE" = "6" ]; then
        bind_addr="[::]:${TUNNEL_PORT}"
        mss=$MSS_V6
    else
        bind_addr="0.0.0.0:${TUNNEL_PORT}"
        mss=$MSS_V4
    fi

    TOML_FILE="$INSTALL_DIR/iran${TUNNEL_PORT}.toml"
    write_server_toml "$TOML_FILE" "$bind_addr" "$mss" "${PORT_ARRAY[@]}"
    write_service "backhaul-iran${TUNNEL_PORT}" "Backhaul Iran Server Port ${TUNNEL_PORT}" "$TOML_FILE"
    systemctl daemon-reload

    update_reserved_ports
    [ "$MSS_ENABLE" = "1" ] && setup_mss_protection

    systemctl enable "backhaul-iran${TUNNEL_PORT}.service" >/dev/null 2>&1
    if ! systemctl restart "backhaul-iran${TUNNEL_PORT}.service"; then
        echo "The service failed to start — see: journalctl -u backhaul-iran${TUNNEL_PORT} -n 30"
    fi
    echo "Local Backhaul (Iran server side) started, listening on ${bind_addr}."

    sleep 2
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
    return 0
}

# ============================================================
# Install: Kharej client side (one or many Iran servers)
# ============================================================

setup_kharej_clients() {
    local count i k ip port prev_port="" dup addr tag name toml mss n up
    local -a IPS=() PORTS=() SVCS=() TARGETS=()

    echo ""
    echo "This Kharej server can be tunnelled to several Iran servers at the same time"
    echo "(one Backhaul client service is created per Iran server)."
    while true; do
        ask count "How many Iran servers should this Kharej server connect to? [1]: " "1"
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
                ask ip "Iran server #${i} public IPv${IP_MODE} address: "
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
                ask port "Tunnel port of Iran server #${i} [${prev_port}]: " "$prev_port"
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
            echo "           (Iran side not set up yet, firewall, or wrong IP version? The client keeps retrying.)"
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
        if [[ "$ip" == *:* ]]; then mss=$MSS_V6; else mss=$MSS_V4; fi

        write_client_toml "$toml" "$addr" "$mss"
        write_service "backhaul-${name}" "Backhaul Kharej Client to ${addr}" "$toml"
        SVCS+=("backhaul-${name}.service")
        TARGETS+=("$addr")
    done
    systemctl daemon-reload

    # the clamp must be in place BEFORE the first tunnel connection is made
    [ "$MSS_ENABLE" = "1" ] && setup_mss_protection

    for k in "${!SVCS[@]}"; do
        systemctl enable "${SVCS[k]}" >/dev/null 2>&1
        systemctl restart "${SVCS[k]}" || echo "  ${SVCS[k]} failed to start — see: journalctl -u ${SVCS[k]%.service} -n 30"
    done

    echo ""
    echo "Kharej client services started (one per Iran server):"
    for k in "${!SVCS[@]}"; do
        echo "  ${SVCS[k]}  ->  ${TARGETS[k]}"
    done

    echo ""
    echo "Waiting for the tunnel(s) to come up (max 15s)..."
    for ((n=0; n<15; n++)); do
        up=0
        for k in "${!SVCS[@]}"; do
            [ "$(unit_conn_count "${SVCS[k]}")" -gt 0 ] && up=$((up + 1))
        done
        [ "$up" -eq "${#SVCS[@]}" ] && break
        sleep 1
    done
    for k in "${!SVCS[@]}"; do
        n=$(unit_conn_count "${SVCS[k]}")
        if [ "${n:-0}" -gt 0 ]; then
            echo "  OK    ${TARGETS[k]}  (${n} tunnel connection(s))"
        else
            echo "  WAIT  ${TARGETS[k]}  (no tunnel connection yet: Iran side not running / token or transport mismatch / firewall)"
        fi
    done

    cat > "$STATE_FILE" << EOF
LOCAL_ROLE=Kharej
TRANSPORT=${TRANSPORT}
IRAN_SERVERS="${TARGETS[*]}"
EOF

    TUNNEL_PORT="${PORTS[*]}"
    return 0
}

# ============================================================
# Install
# ============================================================

install_flow() {
    mkdir -p "$INSTALL_DIR"
    ensure_cmds curl tar ip ss ping >/dev/null 2>&1

    echo ""
    echo "Are you setting up the Iran server or the Kharej server?"
    choose LOCAL_ROLE "Role" "Iran" "Kharej" || return

    echo ""
    echo "Choose transport (must be the SAME on the Iran server(s) and the Kharej server):"
    echo "  1) wss     - TLS encrypted, looks like HTTPS to firewalls (recommended)"
    echo "  2) wssmux  - wss + multiplexing, best for many concurrent connections / high throughput"
    echo "  3) tcp     - plain TCP, fastest but not encrypted or disguised"
    echo "  4) tcpmux  - tcp + multiplexing"
    ask TRANSPORT_CHOICE "Enter choice [1-4] (default 1): " "1"
    case "$TRANSPORT_CHOICE" in
        2) TRANSPORT="wssmux" ;;
        3) TRANSPORT="tcp" ;;
        4) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="wss" ;;
    esac

    # Token is fixed by default (same on every server, no prompt). Override: BACKHAUL_TOKEN=... bash script.sh
    TOKEN="$FIXED_TOKEN"
    if ! [[ "$TOKEN" =~ ^[A-Za-z0-9._~+=-]+$ ]]; then
        echo "BACKHAUL_TOKEN may only contain letters, digits and . _ ~ + = -"
        return
    fi

    echo ""
    echo "TCP-MSS protection stops the 'ping works, but pages load half / lag' problem (path-MTU black hole),"
    echo "mostly seen on IPv6 links. It only touches the tunnel connections — do it on BOTH servers."
    if ask_yn "Enable MSS protection (recommended)?" y; then MSS_ENABLE=1; else MSS_ENABLE=0; fi
    mss_load_env

    if ! ensure_backhaul_local; then
        echo "Backhaul binary is not available — setup aborted."
        return
    fi

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        setup_iran_server || { echo "Setup aborted."; return; }
    else
        setup_kharej_clients || { echo "Setup aborted."; return; }
    fi

    echo ""
    echo "=== Setup Completed! ==="
    echo "Role: $LOCAL_ROLE   Transport: $TRANSPORT   Tunnel port(s): $TUNNEL_PORT"
    echo "Token: $TOKEN"
    echo "Check: systemctl status 'backhaul-*'   (or menu option 2)"
    if [ "$TOKEN" = "123" ]; then
        echo "(Reminder: the token is the fixed value '123' — anyone who can reach the tunnel port and guesses it"
        echo " can register as your client. Use BACKHAUL_TOKEN='...' for a strong one, identical on all servers.)"
    fi
    if [ "$MSS_ENABLE" = "1" ]; then
        echo "MSS clamp: IPv6 MSS ${MSS_V6}, IPv4 MSS ${MSS_V4} — run this script on the OTHER server too."
        echo "Test the path (replace PEER):  ping -6 -M do -s 1232 PEER   (1280-byte packets must work)"
        echo "More: menu 7 -> 4 (diagnostics) / 2 (measure the real path MTU)."
    fi

    if ask_yn "Run system optimizer now (BBR, buffers, MTU cap, DNS, ulimits)?" n; then
        optimize_system
    fi

    if ask_yn "Install the watchdog (auto-restart on dead/idle tunnel)?" n; then
        setup_watchdog
    fi
}

# ============================================================
# Menu
# ============================================================

main() {
    local CHOICE
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (sudo)."
        exit 1
    fi
    mkdir -p "$INSTALL_DIR"

    while true; do
        echo ""
        echo "==== Backhaul Tunnel Manager (${VERSION}) ===="
        echo "1) Install / Setup tunnel (IPv4/IPv6, Kharej: multiple Iran servers)"
        echo "2) Show tunnel status"
        echo "3) Manage inbound ports (Iran side)"
        echo "4) Manage services (start/stop/restart/logs/edit)"
        echo "5) System optimizer (BBR + buffers + MTU cap + DNS + ulimits)"
        echo "6) Install/repair Watchdog (auto-restart on dead/idle tunnel)"
        echo "7) MTU / MSS fix + IPv6 diagnostics  (use when ping is fine but data stalls)"
        echo "8) Uninstall tunnel"
        echo "9) Exit"
        ask CHOICE "Select an option [1-9]: "
        case "$CHOICE" in
            1) install_flow ;;
            2) show_status ;;
            3) manage_ports ;;
            4) manage_services ;;
            5) optimize_system ;;
            6) setup_watchdog ;;
            7) mtu_menu ;;
            8) uninstall_all ;;
            9) exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# run the menu only when executed (not when sourced, e.g. for testing)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
