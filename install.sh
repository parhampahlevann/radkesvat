#!/bin/bash

# =====================================================================================
# Backhaul Tunnel Manager (Iran <-> Kharej) — v12
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding.
#
# v12 — binary update + IPv6 / port-forward / MSS fixes
#   * Menu 11: update the Backhaul binary to the latest OFFICIAL release (Musixal/Backhaul). Shows installed vs
#     latest, keeps a backup (backhaul.bak), restarts the tunnels, rolls back automatically if the new binary
#     does not come up. Do it on BOTH servers (same version on both sides).
#   * Menu 12: IPv6 check + repair (also runs automatically at the end of an IPv6 install): IPv6 sysctls,
#     stable source address (use_tempaddr=0 — a rotating "temporary" address is a classic reason why an IPv6
#     tunnel works for a day and then "does not connect"), default route, listener on [::], firewall chain,
#     TCP probe to the Iran server, MSS re-measure.
#   * Iran setup now proposes a STABLE global IPv6 address (never a temporary/deprecated one) as the address
#     you give to the Kharej side, and lists all stable addresses of the server.
#   * MSS: the clamp now also covers the user-facing INBOUND ports on the Iran side (SYN-ACK of connections from
#     your users — an IPv6 path-MTU black hole between users and Iran looked like a "tunnel problem"). Toggle:
#     menu 7 -> 10. The path MTU is measured against the real peer (on Iran the Kharej address is taken from the
#     established tunnel connections — no typing).
#   * Menu 13: port-forward check — which family each inbound port listens on, local IPv4/IPv6 connect test,
#     and (Kharej) whether the backend target answers on 127.0.0.1 / ::1.
#
# v11 — fixes found while testing v10 on a real Iran <-> Kharej pair
#   * Kharej setup no longer leaves a dead client behind. If you set up the same Iran server again on
#     a NEW tunnel port (e.g. 2124 -> 2060), the old client service (the one that kept logging
#     "dial tcp ...:2124: i/o timeout" forever) is detected and you are offered to remove it.
#   * The token is no longer silently fixed. At install you choose: Enter = default, type your own,
#     or "r" = generate a strong random token (shown at the end — copy it to the other server).
#   * New main-menu option 10: change the token on THIS server in all tunnel configs + restart.
#   * Status shows the Backhaul binary version (compare it on both servers — a version mismatch is a
#     possible cause of "invalid signal received for channel") and explains that log line:
#     a single occurrence = stray connection / scanner on the tunnel port (harmless); repeating every
#     few seconds = token / transport / version mismatch.
#   * Deleting a service (menu 4 -> 10) and the stale-client cleanup share one helper.
#   Everything from v10 is kept (firewall auto-open, TCP probe, SYN watch, MSS clamp, watchdog).
#
# v10 — "ping works but the Kharej client never connects" ('i/o timeout' = the SYN gets no answer):
#   Iran setup opens the tunnel + inbound ports (ufw / firewalld / iptables+ip6tables chain
#   BACKHAUL_FW, re-applied at boot by backhaul-mss.service); Kharej setup / status probe the TCP port
#   and print a verdict; menu 7 has 6) TCP test  7) listener + firewall check  8) watch incoming SYN
#   9) open the firewall now. Port changes refresh the firewall rules.
# v9  — path-MTU black-hole fix (ping ok but data stalls): TCP MSS clamp, tcp_mtu_probing, ICMP
#   packet-too-big allowed. IPv6 MSS 1220, IPv4 MSS 1360. Run on BOTH servers.
#
# Run this SEPARATELY on each server (every Iran server + the Kharej server).
# Order: set up the Iran server(s) first, note their IP / tunnel port / token, then run the Kharej setup.
# Token: the SAME value on every server. Default "123" is weak (it is the only authentication).
#   Pick your own or "r" (random) at the prompt, or:  BACKHAUL_TOKEN='long-random-string' bash script.sh
# =====================================================================================

VERSION="v12"
REPO="Musixal/Backhaul"
INSTALL_DIR="${BACKHAUL_DIR:-/root/backhaul-core}"
SYSTEMD_DIR="${BACKHAUL_SYSTEMD_DIR:-/etc/systemd/system}"
SYSCTL_DIR="${BACKHAUL_SYSCTL_DIR:-/etc/sysctl.d}"
LIMITS_FILE="${BACKHAUL_LIMITS_FILE:-/etc/security/limits.conf}"
RESOLV_CONF="${BACKHAUL_RESOLV_CONF:-/etc/resolv.conf}"
MODULES_DIR="${BACKHAUL_MODULES_DIR:-/etc/modules-load.d}"
STATE_FILE="$INSTALL_DIR/state.env"
FIXED_TOKEN="${BACKHAUL_TOKEN:-123}"
WATCHDOG_SCRIPT="$INSTALL_DIR/watchdog.sh"
WATCHDOG_LOG="$INSTALL_DIR/watchdog.log"
WATCHDOG_STATE_DIR="$INSTALL_DIR/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=30
MSS_SCRIPT="$INSTALL_DIR/mss.sh"
MSS_ENV="$INSTALL_DIR/mss.env"
FW_ADDED_LIST="$INSTALL_DIR/fw-added.list"
DEFAULT_MSS_V6=1220     # MTU 1280 (IPv6 minimum) - 60
DEFAULT_MSS_V4=1360     # MTU 1400 - 40
MTU_CAP=1400

MSS_V6=$DEFAULT_MSS_V6
MSS_V4=$DEFAULT_MSS_V4
MSS_ON=1                # MSS clamp requested
FW_OPEN=1               # open the tunnel/inbound ports in the local firewall (Iran side)
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

# ---------- token ----------

valid_token() {
    # letters, digits and . _ ~ + = -  (safe inside the .toml and inside sed), 3-128 characters
    [[ "$1" =~ ^[A-Za-z0-9._~+=-]{3,128}$ ]]
}

gen_token() {
    # 24 random letters/digits
    local t=""
    t=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24)
    if [ "${#t}" -lt 24 ] && command -v openssl >/dev/null 2>&1; then
        t=$(openssl rand -hex 12)
    fi
    echo "$t"
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

tcp_probe() {
    # tcp_probe <host> <port> [timeout]  -> prints OPEN | REFUSED | TIMEOUT | UNREACH | FAIL
    #   OPEN     handshake completed
    #   REFUSED  host answered with RST: reachable, but nothing listens on that port (or wrong family)
    #   TIMEOUT  SYN got no answer at all: firewall DROP / filtering somewhere on the path
    #   UNREACH  no route (the host has no working path for this IP version)
    local host="$1" port="$2" t="${3:-6}" err rc
    err=$(timeout "$t" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then echo OPEN
    elif [ "$rc" -eq 124 ]; then echo TIMEOUT
    elif echo "$err" | grep -qi 'refused'; then echo REFUSED
    elif echo "$err" | grep -qiE 'unreachable|no route'; then echo UNREACH
    else echo FAIL
    fi
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

list_stable_ipv6() {
    # global IPv6 addresses that are NOT temporary / deprecated / tentative (the ones that stay valid)
    ip -6 -o addr show scope global 2>/dev/null | grep -vE 'temporary|deprecated|tentative|dadfailed' \
        | awk '{print $4}' | cut -d/ -f1
}

detect_public_ip6() {
    # Prefers a STABLE address. The curl "what is my IP" answer is the outgoing source address, which can be a
    # temporary (privacy) address that rotates — giving that to the Kharej side breaks the tunnel later.
    local ip="" svc stable
    stable=$(list_stable_ipv6)
    for svc in https://ifconfig.me https://api6.ipify.org https://ipv6.icanhazip.com; do
        ip=$(curl -fsSL -6 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" == *:* ]] && valid_ipv6 "$ip"; then
            break
        fi
        ip=""
    done
    if [ -n "$ip" ]; then
        if [ -n "$stable" ] && ! grep -qxF "$ip" <<< "$stable"; then
            ip=$(head -n1 <<< "$stable")
        fi
        echo "$ip"
        return 0
    fi
    if [ -n "$stable" ]; then
        head -n1 <<< "$stable"
        return 0
    fi
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

delete_tunnel_unit() {
    # stop + remove one tunnel service, its .toml and its watchdog state
    local u="$1" toml
    toml=$(unit_toml "$u")
    systemctl disable --now "$u" >/dev/null 2>&1
    rm -f "$SYSTEMD_DIR/$u"
    [ -n "$toml" ] && rm -f "$toml"
    rm -f "$WATCHDOG_STATE_DIR/${u}".*
    systemctl daemon-reload
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

toml_peer_host() {
    # host part of remote_addr of a client toml (IPv6 without brackets)
    local addr host
    addr=$(toml_str "$1" remote_addr)
    host=${addr%:*}
    host=${host#\[}
    host=${host%\]}
    echo "$host"
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
    # comma separated: tunnel port + inbound ports/ranges of all [server] configs
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
    local ours cur merged conf="${SYSCTL_DIR}/96-backhaul-reserved.conf"
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

ipv6_sysctls() {
    # IPv6 enabled, dual-stack listeners, and a STABLE outgoing source address (no temporary addresses).
    local conf="${SYSCTL_DIR}/98-backhaul-ipv6.conf" iface
    iface=$(detect_default_iface)
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.use_tempaddr=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.use_tempaddr=0 >/dev/null 2>&1
    sysctl -w "net.ipv6.conf.${iface}.use_tempaddr=0" >/dev/null 2>&1
    cat > "$conf" << EOF
-net.ipv6.conf.all.disable_ipv6=0
-net.ipv6.conf.default.disable_ipv6=0
-net.ipv6.bindv6only=0
-net.ipv6.conf.all.use_tempaddr=0
-net.ipv6.conf.default.use_tempaddr=0
-net.ipv6.conf.${iface}.use_tempaddr=0
EOF
}

prepare_ipv6() {
    # Make sure IPv6 is enabled in the kernel and listeners are dual-stack.
    # Returns 1 if the user wants to go back (no global IPv6 on this host).
    ipv6_sysctls
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
# Connectivity diagnostics (the "ping ok, tunnel never connects" part)
# ============================================================

check_listener() {
    # check_listener <port> <4|6>  — is the tunnel port really listening (and on the right family)?
    local port="$1" mode="$2" addrs
    addrs=$(ss -H -ltn "( sport = :${port} )" 2>/dev/null | awk '{print $4}' | paste -sd' ' -)
    if [ -z "$addrs" ]; then
        echo "  Warning: nothing is listening on tunnel port ${port}."
        return 1
    fi
    echo "  Listening on: ${addrs}"
    if [ "$mode" = "6" ] && ! echo "$addrs" | grep -qE '(^| )(\[::\]|\*):'; then
        echo "  Warning: IPv6 mode, but the port is not listening on [::] / * — IPv6 clients cannot connect."
        return 1
    fi
    return 0
}

diagnose_connect() {
    # diagnose_connect <host> <port> [already-measured-result]
    # Explains WHY a client cannot reach the Iran server's tunnel port.
    local host="$1" port="$2" r="${3:-}" p res fam other_open=0 summary=""
    [[ "$host" == *:* ]] && fam=6 || fam=4
    echo ""
    echo "--- Connectivity test to $(format_hostport "$host" "$port") ---"
    if ping_ok "$host" 3 2; then echo "  ping (ICMP)            : reply"; else echo "  ping (ICMP)            : no reply"; fi
    [ -n "$r" ] || r=$(tcp_probe "$host" "$port" 6)
    echo "  TCP ${port} (tunnel port) : ${r}"
    if [ "$r" != "OPEN" ]; then
        for p in 22 443 80; do
            [ "$p" = "$port" ] && continue
            res=$(tcp_probe "$host" "$p" 4)
            summary="${summary} ${p}=${res}"
            [ "$res" = "OPEN" ] && other_open=1
        done
        echo "  other TCP ports        :${summary}"
    fi
    case "$r" in
        OPEN)
            echo "  => The TCP handshake works: the network path is fine."
            echo "     If the tunnel still shows 0 connections: token / transport mismatch between the two"
            echo "     .toml files, or the service on the Iran side stopped. Check: journalctl -u <service> -n 30"
            ;;
        REFUSED)
            echo "  => The host answered with a reset: it is reachable, but NOTHING LISTENS on port ${port}"
            echo "     for IPv${fam}. On the Iran server: menu 7 -> 7 (is the service running / listening on [::]?"
            echo "     was it created in IPv4 mode? wrong tunnel port typed on the Kharej side?)"
            ;;
        UNREACH)
            echo "  => No route: this server has no working IPv${fam} path to that address."
            ;;
        TIMEOUT|FAIL)
            echo "  => The SYN gets NO answer. Ping working only proves ICMP passes; TCP is being dropped."
            if [ "$other_open" = "1" ]; then
                echo "     Other TCP ports on that host answer, only port ${port} does not -> port-specific block."
                echo "     Fix: open ${port}/tcp on the Iran server (menu 7 -> 9) AND in the provider panel / cloud"
                echo "     firewall, or recreate the tunnel on a port that is open (e.g. 443 or 8443)."
            else
                echo "     No TCP port of that host answers over IPv${fam} (22/443/80 too) while ping works ->"
                echo "     TCP over IPv${fam} to that host is filtered upstream (provider firewall / ISP), or the host"
                echo "     firewall drops everything. If the Iran side already opened its firewall (menu 7 -> 9),"
                echo "     use IPv4 for this tunnel, or ask the provider to allow inbound IPv${fam} TCP."
            fi
            echo "     Decisive test: on the Iran server run menu 7 -> 8 while this client retries:"
            echo "       SYN packets seen  -> blocked on that server (firewall / not listening)"
            echo "       no SYN seen       -> blocked BEFORE it (provider firewall, ISP, wrong IP)"
            ;;
    esac
    echo ""
}

diagnose_clients() {
    # Kharej: run the connectivity test against every configured Iran server
    local u toml host port found=0
    for u in $(list_tunnel_units); do
        toml=$(unit_toml "$u")
        [ -f "$toml" ] || continue
        grep -q '^\[client\]' "$toml" || continue
        host=$(toml_peer_host "$toml")
        port=$(toml_tunnel_port "$toml")
        [ -n "$host" ] && [ -n "$port" ] || continue
        found=1
        diagnose_connect "$host" "$port"
    done
    [ "$found" = "1" ] || echo "No Kharej client config found on this machine (run this on the Kharej server)."
}

fw_active() {
    ip6tables -S BACKHAUL_FW >/dev/null 2>&1 || iptables -S BACKHAUL_FW >/dev/null 2>&1
}

iran_check() {
    # Iran: what is listening, and which firewall layers could be dropping the port?
    local toml port bind fam found=0
    ensure_cmds ss ip >/dev/null 2>&1
    for toml in "$INSTALL_DIR"/*.toml; do
        [ -f "$toml" ] || continue
        grep -q '^\[server\]' "$toml" || continue
        found=1
        bind=$(toml_str "$toml" bind_addr)
        port=${bind##*:}
        fam=$(toml_family "$toml")
        echo ""
        echo "=== $(basename "$toml")  (bind ${bind}, IPv${fam}) ==="
        if check_listener "$port" "$fam"; then echo "  Listener: OK"; fi
        echo "  Service : $(systemctl is-active "backhaul-$(basename "$toml" .toml).service" 2>/dev/null)"
    done
    if [ "$found" = "0" ]; then
        echo "No Iran server config found on this machine (run this on the Iran server)."
        return 0
    fi
    echo ""
    echo "=== Firewall layers on this server ==="
    if command -v ufw >/dev/null 2>&1; then echo "ufw       : $(ufw status 2>/dev/null | head -n1)"; fi
    if command -v firewall-cmd >/dev/null 2>&1; then echo "firewalld : $(firewall-cmd --state 2>&1 | head -n1)"; fi
    echo "iptables  INPUT: $(iptables -S INPUT 2>/dev/null | head -n1)"
    echo "ip6tables INPUT: $(ip6tables -S INPUT 2>/dev/null | head -n1)"
    if fw_active; then
        echo "BACKHAUL_FW chain (ACCEPT for the tunnel / inbound ports): present"
        ip6tables -L BACKHAUL_FW -n -v 2>/dev/null | sed 's/^/  v6 /' | head -n 12
    else
        echo "BACKHAUL_FW chain: not present -> menu 7 -> 9 opens the ports"
    fi
    if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE 'hook input'; then
        echo "nftables  : input hooks exist (native nft rules, not touched by this script) — check: nft list ruleset"
    fi
    echo ""
    echo "A firewall in the PROVIDER panel (security group / cloud firewall) cannot be seen or changed from here."
    echo "If everything above looks fine and the client still times out: menu 7 -> 8 (watch incoming SYN)."
}

watch_syn() {
    # Iran: the decisive test — do the client's SYN packets arrive at all?
    local -a tomls=()
    local toml port out n
    mapfile -t tomls < <(grep -l '^\[server\]' "$INSTALL_DIR"/*.toml 2>/dev/null)
    if [ "${#tomls[@]}" -eq 0 ]; then
        echo "No Iran server config found on this machine (run this on the Iran server)."
        return 0
    fi
    if [ "${#tomls[@]}" -eq 1 ]; then
        toml="${tomls[0]}"
    else
        choose toml "Config" "${tomls[@]}" || return 0
    fi
    port=$(toml_tunnel_port "$toml")
    ensure_cmds tcpdump || { echo "tcpdump is not available — cannot watch."; return 0; }
    echo "Watching up to 25s for incoming TCP SYN packets on port ${port} (IPv4 + IPv6)."
    echo "Restart the Kharej client now:  systemctl restart <backhaul-kharej-...service>"
    out=$(timeout 25 tcpdump -l -ni any -c 10 \
        "(ip6 and ip6[6] = 6 and ip6[53] & 18 = 2 and ip6[42:2] = ${port}) or (ip and tcp[tcpflags] & 18 = 2 and dst port ${port})" 2>/dev/null)
    n=$(printf '%s\n' "$out" | grep -cE ' IP6? ')
    echo ""
    if [ "${n:-0}" -gt 0 ]; then
        printf '%s\n' "$out" | grep -E ' IP6? ' | head -n 5 | sed 's/^/  /'
        echo ""
        echo "=> SYN packets ARRIVE at this server, yet the tunnel does not come up: the problem is HERE."
        echo "   - the firewall drops them: menu 7 -> 9 (and check 'ip6tables -S INPUT')"
        echo "   - or nothing listens on that family: menu 7 -> 7"
    else
        echo "=> NO SYN reached this server in 25s. The packets are blocked BEFORE this machine:"
        echo "   provider firewall / security group, an ISP filter on IPv6 TCP (or on this port), or the client"
        echo "   uses a wrong address/port. Try: another port (443 / 8443), IPv4 instead of IPv6, or ask the provider."
    fi
}

# ============================================================
# Firewall opening (Iran side)
# ============================================================

open_fw_managers() {
    # ufw / firewalld: allow the tunnel + inbound ports (the iptables part is done by mss.sh)
    local specs s
    specs=$(collect_reserved_ports)
    [ -n "$specs" ] || return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        for s in ${specs//,/ }; do
            if ! ufw status 2>/dev/null | grep -qE "^${s/-/:}/tcp[[:space:]]"; then
                if ufw allow "${s/-/:}/tcp" >/dev/null 2>&1; then
                    grep -qxF "ufw ${s}" "$FW_ADDED_LIST" 2>/dev/null || echo "ufw ${s}" >> "$FW_ADDED_LIST"
                fi
            fi
        done
        echo "ufw: TCP ${specs} allowed."
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for s in ${specs//,/ }; do
            if ! firewall-cmd -q --query-port="${s}/tcp" 2>/dev/null; then
                firewall-cmd -q --permanent --add-port="${s}/tcp" >/dev/null 2>&1
                firewall-cmd -q --add-port="${s}/tcp" >/dev/null 2>&1
                grep -qxF "firewalld ${s}" "$FW_ADDED_LIST" 2>/dev/null || echo "firewalld ${s}" >> "$FW_ADDED_LIST"
            fi
        done
        echo "firewalld: TCP ${specs} allowed."
    fi
    return 0
}

close_fw_managers() {
    # undo only what open_fw_managers added (rules that existed before are left alone)
    local kind spec
    [ -f "$FW_ADDED_LIST" ] || return 0
    while read -r kind spec; do
        case "$kind" in
            ufw) ufw --force delete allow "${spec/-/:}/tcp" >/dev/null 2>&1 ;;
            firewalld)
                firewall-cmd -q --permanent --remove-port="${spec}/tcp" >/dev/null 2>&1
                firewall-cmd -q --remove-port="${spec}/tcp" >/dev/null 2>&1 ;;
        esac
    done < "$FW_ADDED_LIST"
    rm -f "$FW_ADDED_LIST"
}

# ============================================================
# Path MTU / MSS  (the fix for "ping ok, data stalls") + firewall ACCEPT chain
# ============================================================

mss_load_env() {
    MSS_V6=$DEFAULT_MSS_V6
    MSS_V4=$DEFAULT_MSS_V4
    MSS_ON=1
    FW_OPEN=1
    MSS_INBOUND=1
    # shellcheck disable=SC1090
    [ -f "$MSS_ENV" ] && . "$MSS_ENV"
}

mss_save_env() {
    mkdir -p "$INSTALL_DIR"
    cat > "$MSS_ENV" << EOF
MSS_V6=${MSS_V6}
MSS_V4=${MSS_V4}
MSS_ON=${MSS_ON}
FW_OPEN=${FW_OPEN}
MSS_INBOUND=${MSS_INBOUND}
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
    run_ping "$1" -n -c 3 -i 0.3 -W 2 -M 'do' -s "$2" >/dev/null 2>&1
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
# Backhaul network rules. Rebuilt from the *.toml files in this directory on every run (idempotent):
#   mss.sh apply | remove | status
#  1) TCP MSS clamp (MSS_ON=1) — path-MTU black-hole protection
#       Server config -> clamp the SYN-ACK of our tunnel listener   (protects data the Kharej sends us)
#                        and, with MSS_INBOUND=1, of the user-facing inbound ports (data we send to users)
#       Client config -> clamp our SYN towards the Iran server       (protects data the Iran server sends us)
#  2) Firewall ACCEPT chain (FW_OPEN=1, server configs only) — tunnel port + inbound ports, IPv4 and IPv6,
#     inserted at the top of INPUT so a restrictive INPUT policy / ufw / hand-made DROP rules cannot
#     silently block the tunnel (the classic "ping works, TCP times out").
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN="BACKHAUL_MSS"
ICMP_CHAIN="BACKHAUL_ICMP"
FW_CHAIN="BACKHAUL_FW"
MSS_V6=1220
MSS_V4=1360
MSS_ON=1
FW_OPEN=1
MSS_INBOUND=1
# shellcheck disable=SC1091
[ -f "$DIR/mss.env" ] && . "$DIR/mss.env"

WAIT4=""
WAIT6=""
SERVER_PORTS=()
CLIENT_PEERS=()
ALLOW_SPECS=()

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

del_chain() {
    # del_chain <fam> <table> <chain> <parent-chain>
    local fam="$1" table="$2" chain="$3" parent="$4"
    while ipt "$fam" -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
    ipt "$fam" -t "$table" -F "$chain" 2>/dev/null
    ipt "$fam" -t "$table" -X "$chain" 2>/dev/null
}

parse_tomls() {
    local toml addr port host e l
    for toml in "$DIR"/*.toml; do
        [ -f "$toml" ] || continue
        if grep -q '^\[server\]' "$toml"; then
            addr=$(grep -E '^bind_addr[[:space:]]*=' "$toml" | head -n1 | cut -d'"' -f2)
            port=${addr##*:}
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                SERVER_PORTS+=("$port")
                ALLOW_SPECS+=("$port")
            fi
            # inbound (user-facing) ports: local part of every "ports" entry
            while IFS= read -r e; do
                [ -n "$e" ] || continue
                l="${e%%=*}"
                if [[ "$l" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:(.+)$ ]]; then
                    l="${BASH_REMATCH[2]}"
                else
                    l="${l%%:*}"
                fi
                [[ "$l" =~ ^[0-9]+(-[0-9]+)?$ ]] && ALLOW_SPECS+=("$l")
            done < <(sed -n '/^ports = \[/,/^\]/p' "$toml" | grep -oE '"[^"]+"' | tr -d '"')
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
        del_chain "$fam" mangle "$CHAIN" OUTPUT
        del_chain "$fam" filter "$ICMP_CHAIN" INPUT
        del_chain "$fam" filter "$FW_CHAIN" INPUT
    done
}

apply() {
    local fam mss p peer host port hfam spec rc=0 done_any=0 seen
    local -a clamp_specs=()
    parse_tomls
    init_wait
    if [ "${#SERVER_PORTS[@]}" -eq 0 ] && [ "${#CLIENT_PEERS[@]}" -eq 0 ]; then
        remove_rules
        echo "No tunnel configs in $DIR — nothing to apply."
        return 0
    fi
    if [ "$MSS_ON" != 1 ] && { [ "$FW_OPEN" != 1 ] || [ "${#ALLOW_SPECS[@]}" -eq 0 ]; }; then
        remove_rules
        echo "MSS clamp and firewall rules are both off — nothing to apply."
        return 0
    fi
    for fam in 6 4; do
        if ! have_ipt "$fam"; then
            echo "IPv$fam: iptables binary not found — skipped."
            continue
        fi

        # ---- firewall ACCEPT chain (filter/INPUT) ----
        if [ "$FW_OPEN" = 1 ] && [ "${#ALLOW_SPECS[@]}" -gt 0 ]; then
            ipt "$fam" -N "$FW_CHAIN" 2>/dev/null
            if ipt "$fam" -F "$FW_CHAIN" 2>/dev/null; then
                for spec in "${ALLOW_SPECS[@]}"; do
                    ipt "$fam" -A "$FW_CHAIN" -p tcp --dport "${spec/-/:}" -j ACCEPT || rc=1
                done
                ipt "$fam" -C INPUT -j "$FW_CHAIN" 2>/dev/null || ipt "$fam" -I INPUT 1 -j "$FW_CHAIN" || rc=1
                echo "IPv$fam: firewall ACCEPT for TCP ${ALLOW_SPECS[*]}"
                done_any=1
            else
                echo "IPv$fam: filter table not usable here — firewall rules skipped."
                rc=1
            fi
        else
            del_chain "$fam" filter "$FW_CHAIN" INPUT
        fi

        # ---- MSS clamp (mangle/OUTPUT) + ICMP errors needed by PMTU discovery ----
        if [ "$MSS_ON" != 1 ]; then
            del_chain "$fam" mangle "$CHAIN" OUTPUT
            del_chain "$fam" filter "$ICMP_CHAIN" INPUT
            continue
        fi
        if ! ipt "$fam" -t mangle -S >/dev/null 2>&1; then
            echo "IPv$fam: netfilter mangle table not usable here — MSS clamp skipped."
            continue
        fi
        if [ "$fam" = 6 ]; then mss=$MSS_V6; else mss=$MSS_V4; fi

        ipt "$fam" -t mangle -N "$CHAIN" 2>/dev/null
        if ! ipt "$fam" -t mangle -F "$CHAIN"; then
            rc=1
            continue
        fi
        ipt "$fam" -t mangle -C OUTPUT -j "$CHAIN" 2>/dev/null || ipt "$fam" -t mangle -I OUTPUT 1 -j "$CHAIN" || rc=1

        clamp_specs=("${SERVER_PORTS[@]}")
        [ "$MSS_INBOUND" = 1 ] && clamp_specs+=("${ALLOW_SPECS[@]}")
        seen=" "
        for p in "${clamp_specs[@]}"; do
            case "$seen" in *" $p "*) continue ;; esac
            seen="${seen}${p} "
            ipt "$fam" -t mangle -A "$CHAIN" -p tcp --sport "${p/-/:}" --tcp-flags SYN,RST SYN \
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
        echo "--- IPv$fam  filter/INPUT -> $FW_CHAIN ---"
        ipt "$fam" -L "$FW_CHAIN" -n -v 2>&1 | sed 's/^/  /'
    done
}

case "${1:-apply}" in
    apply)  apply ;;
    remove) init_wait; remove_rules; echo "Backhaul MSS / firewall rules removed." ;;
    status) status ;;
    *) echo "usage: $0 apply|remove|status"; exit 2 ;;
esac
MSSEOF
    chmod +x "$MSS_SCRIPT"
}

write_mss_unit() {
    cat > "$SYSTEMD_DIR/backhaul-mss.service" << EOF
[Unit]
Description=Backhaul network rules (TCP MSS clamp + firewall ACCEPT for the tunnel ports)
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
    # re-apply the rules after a toml/port change (no-op if they were never installed)
    [ -f "$MSS_SCRIPT" ] && bash "$MSS_SCRIPT" apply >/dev/null 2>&1
    return 0
}

refresh_net_rules() {
    # after ports / configs changed: iptables chain + ufw/firewalld
    mss_load_env
    mss_refresh
    if [ "$FW_OPEN" = "1" ] && [ -f "$MSS_SCRIPT" ]; then
        open_fw_managers >/dev/null
    fi
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

setup_net_rules() {
    # uses MSS_V6 / MSS_V4 / MSS_ON / FW_OPEN currently in memory (callers load or change them first)
    ensure_cmds iptables ip6tables >/dev/null 2>&1
    write_mss_script
    write_mss_unit
    mss_save_env
    if [ "$MSS_ON" = "1" ]; then
        sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
        echo "net.ipv4.tcp_mtu_probing=1" > "${SYSCTL_DIR}/97-backhaul-mtu.conf"
    fi
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable backhaul-mss.service >/dev/null 2>&1
    echo ""
    echo "=== Network rules (MSS / path-MTU protection + firewall ACCEPT) ==="
    if bash "$MSS_SCRIPT" apply; then
        [ "$MSS_ON" = "1" ] && echo "Done: tunnel connections use small, safe segments (survives reboot via backhaul-mss.service)."
    else
        warn "some iptables rules could not be installed on this host."
        if [ "$MSS_ON" = "1" ]; then
            echo "         Falling back to tcp_mtu_probing=2 (works without ICMP, slightly slower ramp-up)."
            sysctl -w net.ipv4.tcp_mtu_probing=2 >/dev/null 2>&1
            echo "net.ipv4.tcp_mtu_probing=2" > "${SYSCTL_DIR}/97-backhaul-mtu.conf"
        fi
    fi
    if [ "$FW_OPEN" = "1" ]; then
        open_fw_managers
    fi
    return 0
}

setup_mss_protection() {
    MSS_ON=1
    setup_net_rules
}

peer_list() {
    # peer_list -> prints the other end(s): Kharej = the Iran servers from the client configs;
    # otherwise asks for an address.
    local u toml peer p t tp
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
        # Iran side: the Kharej peers are the established connections on our tunnel port(s)
        for t in "$INSTALL_DIR"/*.toml; do
            [ -f "$t" ] && grep -q '^\[server\]' "$t" || continue
            tp=$(toml_tunnel_port "$t")
            [ -n "$tp" ] || continue
            while IFS= read -r p; do
                p=${p%:*}
                p=${p#\[}
                p=${p%\]}
                p=${p#::ffff:}
                [ -n "$p" ] && peers+=("$p")
            done < <(ss -H -tn state established "( sport = :${tp} )" 2>/dev/null | awk '{print $4}')
        done
        if [ "${#peers[@]}" -gt 0 ]; then
            mapfile -t peers < <(printf '%s\n' "${peers[@]}" | sort -u)
            echo "(other end taken from the established tunnel connections: ${peers[*]})" >&2
        fi
    fi
    if [ "${#peers[@]}" -eq 0 ] && [ "${PEER_NOASK:-0}" != "1" ]; then
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
    echo "=== MSS clamp / firewall rules (packet counters grow when a tunnel (re)connects) ==="
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
            echo "  ${peer}   $(echo "$l" | tr ' \t' '\n\n' | grep -E '^(rtt|mss|pmtu|retrans|cwnd|unacked):' | tr '\n' ' ')"
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
        out=$(run_ping "$peer" -n -c 20 -i 0.2 -W 2 -M 'do' -s "$l" 2>&1 | grep -E 'packet loss')
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
        echo "=== Connection / MTU / MSS tools ==="
        echo "MSS clamp: $(mss_active && echo ACTIVE || echo "not active")   (IPv6 MSS ${MSS_V6}, IPv4 MSS ${MSS_V4})    Firewall ACCEPT chain: $(fw_active && echo ACTIVE || echo "not active")"
        echo "-- Tunnel does not connect ('i/o timeout', ping works) --"
        echo "6) Kharej: TCP connection test to the Iran server(s)  (tells you why it times out)"
        echo "7) Iran:   listener + firewall check"
        echo "8) Iran:   watch incoming SYN packets while the client retries  (decisive test)"
        echo "9) Iran:   open the firewall for the tunnel / inbound ports now"
        echo "-- Connected but data stalls / pages load half --"
        echo "1) Apply / refresh the MSS clamp now (recommended)"
        echo "2) Detect the real path MTU to the other server and use it"
        echo "3) Set MSS manually"
        echo "4) Diagnostics (path MTU, packet loss, live tunnel sockets)"
        echo "5) Remove the MSS clamp (firewall ACCEPT rules stay)"
        echo "10) Iran: MSS clamp on the user-facing inbound ports is $([ "$MSS_INBOUND" = "1" ] && echo ON || echo OFF) — toggle"
        echo "0) Back"
        ask c "Select: "
        case "$c" in
            1) setup_mss_protection ;;
            2) detect_and_apply_mss ;;
            3) set_mss_manually ;;
            4) diagnose_tunnel ;;
            5) mss_load_env
               MSS_ON=0
               mss_save_env
               if [ -f "$MSS_SCRIPT" ]; then bash "$MSS_SCRIPT" apply; fi
               echo "MSS clamp removed (tcp/tcpmux configs keep their native mss line)." ;;
            6) diagnose_clients ;;
            7) iran_check ;;
            8) watch_syn ;;
            9) mss_load_env
               FW_OPEN=1
               if [ -z "$(collect_reserved_ports)" ]; then
                   echo "No Iran server config on this machine — nothing to open (run this on the Iran server)."
               else
                   setup_net_rules
                   echo "Also check the PROVIDER panel / cloud firewall: it must allow the same TCP ports."
               fi ;;
            10) mss_load_env
                if [ "$MSS_INBOUND" = "1" ]; then MSS_INBOUND=0; else MSS_INBOUND=1; fi
                MSS_ON=1
                setup_net_rules
                echo "Inbound-port MSS clamp is now $([ "$MSS_INBOUND" = "1" ] && echo ON || echo OFF)." ;;
            0) return ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ============================================================
# Binary update (official Musixal/Backhaul releases only)
# ============================================================

backhaul_installed_version() {
    "$INSTALL_DIR/backhaul" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

latest_backhaul_tag() {
    # latest release tag of the official repo (API first, then the /releases/latest redirect)
    local tag
    tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
    if [ -z "$tag" ]; then
        tag=$(curl -fsSL --max-time 20 -o /dev/null -w '%{url_effective}' \
            "https://github.com/${REPO}/releases/latest" 2>/dev/null | sed -n 's#.*/tag/##p')
    fi
    echo "$tag"
}

update_backhaul() {
    local cur latest latn asset_arch url tmpd u bad=0
    local -a active=()
    ensure_cmds curl tar >/dev/null 2>&1
    mkdir -p "$INSTALL_DIR"
    cur=$(backhaul_installed_version)
    echo ""
    echo "=== Update the Backhaul binary (official ${REPO} releases) ==="
    echo "Checking the latest release on GitHub..."
    latest=$(latest_backhaul_tag)
    echo "  installed : ${cur:-not installed}"
    echo "  latest    : ${latest:-unknown}"
    if [ -z "$latest" ] && [ -z "${BACKHAUL_URL:-}" ]; then
        echo "Could not read the latest release (GitHub not reachable from this server?)."
        echo "Download backhaul_linux_<arch>.tar.gz on another machine, copy it here and run:"
        echo "  BACKHAUL_URL=/path/backhaul_linux_amd64.tar.gz bash <this script>   (then menu 11)"
        return 0
    fi
    latn=${latest#v}
    if [ -n "$cur" ] && [ "$cur" = "$latn" ] && [ -z "${BACKHAUL_URL:-}" ]; then
        echo "Already on the latest official version — nothing to do."
        echo "(Do the same check on the OTHER server: both sides should run the same version.)"
        return 0
    fi
    if ! ask_yn "Install ${latest:-the file from BACKHAUL_URL}? (running tunnels restart for a few seconds)" y; then
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64) asset_arch="amd64" ;;
        aarch64|arm64) asset_arch="arm64" ;;
        *) echo "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
    url="${BACKHAUL_URL:-https://github.com/${REPO}/releases/download/${latest}/backhaul_linux_${asset_arch}.tar.gz}"
    tmpd=$(mktemp -d)
    if [ -f "$url" ]; then
        cp "$url" "$tmpd/b.tar.gz"
    else
        echo "Downloading: $url"
        if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$tmpd/b.tar.gz" "$url"; then
            echo "Download failed — nothing changed."
            rm -rf "$tmpd"
            return 1
        fi
    fi
    if ! tar -tzf "$tmpd/b.tar.gz" >/dev/null 2>&1 || ! tar -xzf "$tmpd/b.tar.gz" -C "$tmpd" || [ ! -f "$tmpd/backhaul" ]; then
        echo "The download is not a valid Backhaul archive — nothing changed."
        rm -rf "$tmpd"
        return 1
    fi
    chmod +x "$tmpd/backhaul"
    if ! "$tmpd/backhaul" -v >/dev/null 2>&1; then
        echo "The new binary does not run on this machine — nothing changed."
        rm -rf "$tmpd"
        return 1
    fi
    echo "New binary reports: $("$tmpd/backhaul" -v 2>/dev/null | head -n1)"

    for u in $(list_tunnel_units); do
        systemctl is-active --quiet "$u" && active+=("$u")
    done
    [ -x "$INSTALL_DIR/backhaul" ] && cp -p "$INSTALL_DIR/backhaul" "$INSTALL_DIR/backhaul.bak"
    cp "$tmpd/backhaul" "$INSTALL_DIR/backhaul.new" && chmod +x "$INSTALL_DIR/backhaul.new" \
        && mv -f "$INSTALL_DIR/backhaul.new" "$INSTALL_DIR/backhaul"
    rm -rf "$tmpd"
    echo "Binary replaced (old one kept as backhaul.bak)."

    for u in "${active[@]}"; do
        systemctl restart "$u" >/dev/null 2>&1
    done
    if [ "${#active[@]}" -gt 0 ]; then
        echo "Restarted ${#active[@]} tunnel service(s); checking they stay up..."
        sleep 6
        for u in "${active[@]}"; do
            if systemctl is-active --quiet "$u"; then
                echo "  OK    $u"
            else
                echo "  DOWN  $u"
                bad=1
            fi
        done
    fi
    if [ "$bad" = "1" ] && [ -f "$INSTALL_DIR/backhaul.bak" ]; then
        echo "A service did not come up with the new binary — rolling back to the previous version."
        mv -f "$INSTALL_DIR/backhaul.bak" "$INSTALL_DIR/backhaul"
        for u in "${active[@]}"; do
            systemctl restart "$u" >/dev/null 2>&1
        done
        echo "Rolled back to: $(backhaul_installed_version)"
        return 1
    fi
    echo "Now running: $(backhaul_installed_version).  Repeat this on the OTHER server (same version on both sides)."
    return 0
}

# ============================================================
# IPv6 check + repair  (menu 12; runs automatically after an IPv6 install)
# ============================================================

ipv6_repair() {
    local auto="${1:-}" iface stable temps u toml host port r src found_srv=0 found_cli=0 bind lport rt
    ensure_cmds ip ss ping >/dev/null 2>&1
    [ "$auto" = "auto" ] && PEER_NOASK=1
    iface=$(detect_default_iface)
    echo ""
    echo "=== IPv6 check / repair ==="

    # [1] kernel settings
    ipv6_sysctls
    echo "[1] Kernel: IPv6 enabled, dual-stack listeners, stable source address (use_tempaddr=0) — applied and saved."

    # [2] addresses + default route
    stable=$(list_stable_ipv6 | paste -sd' ' -)
    temps=$(ip -6 -o addr show scope global 2>/dev/null | grep -c 'temporary')
    if [ -z "$stable" ]; then
        echo "[2] PROBLEM: no stable global IPv6 address on ${iface}. An IPv6 tunnel cannot work here:"
        echo "    ask the provider to enable IPv6, or use IPv4 for this tunnel."
    else
        echo "[2] Stable global IPv6 on ${iface}: ${stable}"
        [ "${temps:-0}" -gt 0 ] && echo "    (${temps} temporary address(es) exist — they are no longer preferred as the source address.)"
        echo "    Give the Kharej side one of the STABLE addresses above (not a temporary one)."
    fi
    rt=$(ip -6 route show default 2>/dev/null | head -n1)
    if [ -z "$rt" ]; then
        echo "    PROBLEM: no IPv6 default route — this server cannot reach any IPv6 destination."
        echo "    Check the provider's IPv6 gateway settings (netplan / /etc/network/interfaces)."
    else
        echo "    default route: ${rt}"
    fi

    # [3] Iran side: listener + firewall
    for toml in "$INSTALL_DIR"/*.toml; do
        [ -f "$toml" ] || continue
        grep -q '^\[server\]' "$toml" || continue
        found_srv=1
        bind=$(toml_str "$toml" bind_addr)
        lport=${bind##*:}
        echo "[3] Iran: $(basename "$toml")  bind ${bind}"
        if [ "$(toml_family "$toml")" = "6" ]; then
            if check_listener "$lport" 6; then echo "    listener OK (IPv6, dual-stack)"; fi
        else
            echo "    This tunnel is IPv4 (bind ${bind}): an IPv6 Kharej client cannot use it."
            echo "    Create it in IPv6 mode (menu 1 -> Iran -> IPv6) or connect the Kharej over IPv4."
        fi
    done
    if [ "$found_srv" = "1" ]; then
        mss_load_env
        FW_OPEN=1
        if [ "$auto" = "auto" ] && fw_active; then
            echo "    firewall ACCEPT chain (IPv4 + IPv6): present"
        else
            setup_net_rules
        fi
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active' \
            && grep -qiE '^IPV6=no' /etc/default/ufw 2>/dev/null; then
            echo "    note: ufw has IPV6=no (it ignores IPv6). The ip6tables ACCEPT chain of this script covers"
            echo "    the tunnel + inbound ports anyway; set IPV6=yes in /etc/default/ufw if you also want ufw to manage IPv6."
        fi
        echo "    A firewall in the PROVIDER panel must allow the same TCP ports for IPv6 — not visible from here."
    fi

    # [4] Kharej side: source address + TCP probe per IPv6 Iran server
    for u in $(list_tunnel_units); do
        toml=$(unit_toml "$u")
        [ -n "$toml" ] && [ -f "$toml" ] || continue
        grep -q '^\[client\]' "$toml" || continue
        host=$(toml_peer_host "$toml")
        [[ "$host" == *:* ]] || continue
        port=$(toml_tunnel_port "$toml")
        found_cli=1
        src=$(ip -6 route get "$host" 2>/dev/null | grep -oE 'src [0-9a-fA-F:]+' | awk '{print $2}' | head -n1)
        echo "[4] Kharej: ${u}  ->  $(format_hostport "$host" "$port")"
        echo "    outgoing source address: ${src:-unknown}"
        if [ -n "$src" ] && ip -6 -o addr show 2>/dev/null | grep -F " ${src}/" | grep -q 'temporary'; then
            echo "    WARNING: the source is a TEMPORARY address — it rotates; restart the tunnel after this repair."
        fi
        r=$(tcp_probe "$host" "$port" 6)
        echo "    TCP to the Iran tunnel port: ${r}   |   tunnel connections now: $(unit_conn_count "$u")"
        if [ "$r" != "OPEN" ]; then
            diagnose_connect "$host" "$port" "$r"
        fi
    done

    if [ "$found_srv" = "0" ] && [ "$found_cli" = "0" ]; then
        echo "[3/4] No IPv6 tunnel config found on this machine (only the kernel part above was applied)."
        PEER_NOASK=0
        return 0
    fi

    # [5] MSS against the real peer
    echo "[5] MSS / path MTU"
    if [ "$auto" = "auto" ] || ask_yn "Measure the real path MTU to the other server and set the MSS now?" y; then
        detect_and_apply_mss
        if [ "$found_srv" = "1" ] && [ "$auto" = "auto" ]; then
            echo "    (On the Iran side the other end is only known once the Kharej is connected: run menu 12 here again"
            echo "     after the Kharej client is up, so the MSS is measured against the real peer.)"
        fi
    fi

    # [6] restart (interactive only)
    if [ "$auto" != "auto" ] && ask_yn "Restart the tunnel service(s) now to apply everything?" y; then
        for u in $(list_tunnel_units); do
            rm -f "$WATCHDOG_STATE_DIR/${u}.paused"
            systemctl restart "$u" >/dev/null 2>&1 && echo "  restarted $u" || echo "  restart failed: $u"
        done
        echo "  Give it ~10 s, then check menu 2."
    fi
    PEER_NOASK=0
    return 0
}

# ============================================================
# Port-forward check  (menu 13)
# ============================================================

forward_check() {
    local toml e spec addrs r4 r6 u t found_srv=0 found_cli=0 tports
    local -a TP=()
    ensure_cmds ss >/dev/null 2>&1
    echo ""
    echo "=== Port-forward check ==="
    for toml in "$INSTALL_DIR"/*.toml; do
        [ -f "$toml" ] || continue
        grep -q '^\[server\]' "$toml" || continue
        found_srv=1
        echo "--- Iran: $(basename "$toml") ---"
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            spec=$(entry_local_spec "$e")
            if ! [[ "$spec" =~ ^[0-9]+$ ]]; then
                echo "  ${e}: port range — not tested"
                continue
            fi
            addrs=$(ss -H -ltn "( sport = :${spec} )" 2>/dev/null | awk '{print $4}' | paste -sd' ' -)
            r4=$(tcp_probe 127.0.0.1 "$spec" 3)
            r6=$(tcp_probe ::1 "$spec" 3)
            printf '  %-20s listens: %-26s local IPv4: %-8s local IPv6: %s\n' "$e" "${addrs:-NOTHING}" "$r4" "$r6"
            if [ -z "$addrs" ]; then
                echo "     -> nothing listens on ${spec}: the tunnel service is down, or the port is taken by another program."
            elif [ "$r4" = "OPEN" ] && [ "$r6" != "OPEN" ]; then
                echo "     -> reachable over IPv4 only: IPv6 users cannot connect (IPv6 off in the kernel?). Run menu 12."
            elif [ "$r4" = "OPEN" ] && [ "$r6" = "OPEN" ]; then
                echo "     -> OK locally for IPv4 and IPv6. From outside it also needs the firewall (menu 7 -> 7 / 9)"
                echo "        and the provider-panel firewall to allow TCP ${spec} for IPv6."
            fi
        done < <(sed -n '/^ports = \[/,/^\]/p' "$toml" | grep -oE '"[^"]+"' | tr -d '"')
    done
    for u in $(list_tunnel_units); do
        toml=$(unit_toml "$u")
        [ -n "$toml" ] && [ -f "$toml" ] || continue
        grep -q '^\[client\]' "$toml" && found_cli=1
    done
    if [ "$found_cli" = "1" ]; then
        echo ""
        echo "--- Kharej: do the forward targets answer on this machine? ---"
        ask tports "Target port(s) that the Iran inbound ports forward to (comma separated, Enter = skip): "
        tports="${tports// /}"
        if [ -n "$tports" ]; then
            IFS=',' read -ra TP <<< "$tports"
            for t in "${TP[@]}"; do
                valid_port "$t" || { echo "  ${t}: not a port"; continue; }
                r4=$(tcp_probe 127.0.0.1 "$t" 3)
                r6=$(tcp_probe ::1 "$t" 3)
                printf '  target %-6s 127.0.0.1: %-8s [::1]: %s\n' "$t" "$r4" "$r6"
                if [ "$r4" != "OPEN" ] && [ "$r6" = "OPEN" ]; then
                    echo "     -> the backend listens on IPv6 loopback only. My understanding is that the Backhaul client dials"
                    echo "        IPv4 (127.0.0.1) — not verified. Make the backend listen on 0.0.0.0 or :: (dual-stack)."
                elif [ "$r4" != "OPEN" ] && [ "$r6" != "OPEN" ]; then
                    echo "     -> nothing answers on port ${t}: start the backend (x-ui / xray / ...) or fix the target port."
                else
                    echo "     -> OK"
                fi
            done
        fi
    fi
    if [ "$found_srv" = "0" ] && [ "$found_cli" = "0" ]; then
        echo "No Backhaul config found on this machine."
    fi
    echo ""
    echo "Note: Backhaul cannot forward to an IPv6 literal target (\"443=[::1]:5201\"); targets are IPv4 / local ports."
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

    chattr -i "$RESOLV_CONF" 2>/dev/null
    # back up the original once, so uninstall can restore it
    if [ ! -f "$INSTALL_DIR/resolv.conf.orig" ] && [ ! -f "$INSTALL_DIR/resolv.conf.link" ]; then
        if [ -L "$RESOLV_CONF" ]; then
            readlink "$RESOLV_CONF" > "$INSTALL_DIR/resolv.conf.link"
        elif [ -f "$RESOLV_CONF" ]; then
            cp "$RESOLV_CONF" "$INSTALL_DIR/resolv.conf.orig"
        fi
    fi
    if [ -L "$RESOLV_CONF" ]; then
        # usually systemd-resolved's stub: replace the symlink with a static file so it isn't reset
        rm -f "$RESOLV_CONF"
    fi
    {
        printf '%s\n' "${lines[@]}"
        echo "options timeout:2 attempts:2"
    } > "$RESOLV_CONF"
    # Best-effort: stop NetworkManager / dhcp clients from overwriting it back.
    chattr +i "$RESOLV_CONF" 2>/dev/null
    echo "DNS set (${lines[*]//nameserver /}). ${RESOLV_CONF} is now static/locked (chattr +i); uninstall can restore it."
}

ensure_ulimits() {
    echo ""
    echo "=== Raising file descriptor limits ==="
    if ! grep -q "^fs.file-max" "${SYSCTL_DIR}/99-backhaul-tunnel.conf" 2>/dev/null; then
        echo "fs.file-max=2097152" >> "${SYSCTL_DIR}/99-backhaul-tunnel.conf"
    fi
    sysctl -w fs.file-max=2097152 > /dev/null 2>&1

    if ! grep -q "backhaul-tunnel limits" "$LIMITS_FILE" 2>/dev/null; then
        cat >> "$LIMITS_FILE" << EOF

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
    local conf="${SYSCTL_DIR}/99-backhaul-tunnel.conf" tmp kv key
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
        echo "tcp_bbr" > "${MODULES_DIR}/backhaul-bbr.conf" 2>/dev/null
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
    chattr -i "$RESOLV_CONF" 2>/dev/null
    if [ -f "$INSTALL_DIR/resolv.conf.link" ]; then
        rm -f "$RESOLV_CONF"
        ln -s "$(cat "$INSTALL_DIR/resolv.conf.link")" "$RESOLV_CONF"
        echo "DNS: ${RESOLV_CONF} symlink restored."
    elif [ -f "$INSTALL_DIR/resolv.conf.orig" ]; then
        cat "$INSTALL_DIR/resolv.conf.orig" > "$RESOLV_CONF"
        echo "DNS: original ${RESOLV_CONF} restored."
    fi
    rm -f "${SYSCTL_DIR}/99-backhaul-tunnel.conf" "${SYSCTL_DIR}/98-backhaul-ipv6.conf" \
          "${SYSCTL_DIR}/97-backhaul-mtu.conf" "${SYSCTL_DIR}/96-backhaul-reserved.conf" \
          "${MODULES_DIR}/backhaul-bbr.conf"
    sed -i '/^# backhaul-tunnel limits$/,/^\* hard nofile 1048576$/d' "$LIMITS_FILE" 2>/dev/null
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
    local units tunnel_units u toml addr state warn_txt found_warning n host port

    units=$(list_backhaul_units)
    tunnel_units=$(list_tunnel_units)

    if [ -x "$INSTALL_DIR/backhaul" ]; then
        echo ""
        echo "Backhaul binary on this server: $("$INSTALL_DIR/backhaul" -v 2>/dev/null | head -n1)   (it should be the same version on the Iran and the Kharej server)"
    fi

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

        # Kharej clients that are running but have no tunnel connection: say WHY
        for u in $tunnel_units; do
            toml=$(unit_toml "$u")
            [ -n "$toml" ] && [ -f "$toml" ] || continue
            grep -q '^\[client\]' "$toml" || continue
            systemctl is-active --quiet "$u" || continue
            [ "$(unit_conn_count "$u")" -gt 0 ] && continue
            host=$(toml_peer_host "$toml")
            port=$(toml_tunnel_port "$toml")
            [ -n "$host" ] && [ -n "$port" ] || continue
            echo ""
            echo ">>> $u has NO tunnel connection — testing the path to the Iran server:"
            diagnose_connect "$host" "$port"
            echo "    (If this is an OLD client for a port that no longer exists: menu 4 -> pick it -> 10 deletes it.)"
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
    if grep -qs '^\[server\]' "$INSTALL_DIR"/*.toml 2>/dev/null; then
        if fw_active; then
            echo "Firewall ACCEPT for the tunnel / inbound ports: ACTIVE"
        else
            echo "Firewall ACCEPT for the tunnel / inbound ports: NOT active — if clients time out, menu 7 -> 9."
        fi
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
        warn_txt=$(journalctl -u "$u" -n 20 --no-pager 2>/dev/null | grep -iE "invalid security token|invalid signal|error|failed|unreachable|refused|timeout" | tail -n 3)
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
        echo "two servers does not match — check with: grep token ${INSTALL_DIR}/*.toml  (menu 10 changes it)"
        echo "If you see 'invalid signal received for channel' ONCE (e.g. right after a start): usually a stray"
        echo "  connection / scanner on the tunnel port — harmless if the tunnel shows connections above."
        echo "  If it repeats every few seconds: token / transport mismatch, or different Backhaul versions"
        echo "  on the two servers (compare the 'Backhaul binary' line above on both)."
        echo "If you see 'i/o timeout' on the dialer: the SYN is not answered (firewall / provider / ISP filter)"
        echo "  although ping works -> menu 12 (IPv6 repair), menu 7 -> 6 (Kharej) and menu 7 -> 7 / 8 / 9 (Iran)."
        echo "If you see 'connection refused': nothing listens on that port/family on the Iran server."
        echo "If you see 'network is unreachable' on an IPv6 tunnel, the server has no working IPv6 route."
        echo "If the tunnel connects but data stalls: menu 7 (MSS clamp + diagnostics)."
    fi

    if [ -f "$WATCHDOG_LOG" ]; then
        echo ""
        echo "=== Last 10 watchdog restarts ==="
        tail -n 10 "$WATCHDOG_LOG"
    fi
}

# ============================================================
# Token change (all tunnels on THIS server)
# ============================================================

change_token() {
    local new u f count=0
    local -a tomls=()
    mapfile -t tomls < <(ls "$INSTALL_DIR"/*.toml 2>/dev/null)
    if [ "${#tomls[@]}" -eq 0 ]; then
        echo "No tunnel config found on this machine."
        return 0
    fi
    echo ""
    echo "This changes the token in ALL ${#tomls[@]} tunnel config(s) on THIS server and restarts the tunnels."
    echo "Do the same on the other server(s) with EXACTLY the same token, otherwise the tunnel drops"
    echo "('invalid security token'). Tip: change the Iran side first, then the Kharej side right after."
    ask new "New token (r = generate a random one, empty = cancel): "
    if [ -z "$new" ]; then
        echo "Cancelled."
        return 0
    fi
    if [ "$new" = "r" ] || [ "$new" = "R" ]; then
        new=$(gen_token)
    fi
    if ! valid_token "$new"; then
        echo "Token may only contain letters, digits and . _ ~ + = -  (3-128 characters). Nothing changed."
        return 0
    fi
    for f in "${tomls[@]}"; do
        if grep -qE '^token[[:space:]]*=' "$f"; then
            sed -i -E "s/^token[[:space:]]*=.*/token = \"${new}\"/" "$f"
            count=$((count + 1))
        fi
    done
    echo "Token updated in ${count} config(s)."
    for u in $(list_tunnel_units); do
        rm -f "$WATCHDOG_STATE_DIR/${u}.paused"
        if systemctl restart "$u" 2>/dev/null; then
            echo "  restarted $u"
        else
            echo "  restart failed: $u (journalctl -u ${u%.service} -n 30)"
        fi
    done
    echo ""
    echo ">>> NEW TOKEN: ${new}"
    echo ">>> Copy it to the other server(s) now (menu 10 there)."
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
    choose TOML_FILE "Config" "${tomls[@]}" || return 0

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
    refresh_net_rules
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
    choose SERVICE_NAME "Service" "${units[@]}" || return 0

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
                       refresh_net_rules
                       if ask_yn "Restart service to apply changes?" y; then
                           rm -f "$WATCHDOG_STATE_DIR/${SERVICE_NAME}.paused"
                           systemctl restart "$SERVICE_NAME" && echo "Restarted." || echo "Restart failed."
                       fi
                   fi
               else
                   echo "Config path not found."
               fi ;;
            10) if ask_yn "Delete $SERVICE_NAME and its config?" n; then
                    delete_tunnel_unit "$SERVICE_NAME"
                    update_reserved_ports
                    refresh_net_rules
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
    if ! ask_yn "This will remove ALL Backhaul services (including watchdog / MSS / firewall / MTU units) on THIS server. Continue?" n; then
        echo "Cancelled."
        return
    fi
    if ask_yn "Also revert the system tuning done by this script (DNS lock, sysctl files, MTU cap, file limits)?" y; then
        revert=1
    fi

    [ -f "$MSS_SCRIPT" ] && bash "$MSS_SCRIPT" remove
    close_fw_managers

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
    echo "(Tip: if a random port is filtered on your provider/ISP, use a common one such as 443 or 8443.)"
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
    # MSS clamp (optional) + firewall ACCEPT for the tunnel / inbound ports (v4 + v6) — BEFORE the service starts
    MSS_ON=$MSS_ENABLE
    setup_net_rules

    systemctl enable "backhaul-iran${TUNNEL_PORT}.service" >/dev/null 2>&1
    if ! systemctl restart "backhaul-iran${TUNNEL_PORT}.service"; then
        echo "The service failed to start — see: journalctl -u backhaul-iran${TUNNEL_PORT} -n 30"
    fi
    echo "Local Backhaul (Iran server side) started, listening on ${bind_addr}."

    sleep 2
    if check_listener "$TUNNEL_PORT" "$IP_MODE"; then
        echo "Check: tunnel port ${TUNNEL_PORT} is listening."
    else
        echo "         see: journalctl -u backhaul-iran${TUNNEL_PORT} -n 30"
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
    echo "      Token       : ${TOKEN}   (type exactly this on the Kharej server)"
    if [ "$FW_OPEN" = "1" ]; then
        echo ">>> The local firewall (ufw / firewalld / iptables$([ "$IP_MODE" = "6" ] && echo " + ip6tables")) was opened for TCP ${TUNNEL_PORT} and the inbound ports."
    else
        echo ">>> Make sure the firewall allows TCP ${TUNNEL_PORT}$([ "$IP_MODE" = "6" ] && echo " for IPv6 as well (ip6tables / ufw with IPV6=yes)") — or run menu 7 -> 9."
    fi
    echo ">>> A firewall in the PROVIDER panel (security group / cloud firewall) must allow TCP ${TUNNEL_PORT} too — this script cannot change that."
    echo ">>> If the Kharej client later shows 'i/o timeout': menu 7 -> 8 here (watch incoming SYN) tells you where it is blocked."
    echo ">>> Using several Iran servers? Run this script on each of them, then list them all on the Kharej server."
    return 0
}

# ============================================================
# Install: Kharej client side (one or many Iran servers)
# ============================================================

setup_kharej_clients() {
    local count i k ip port prev_port="" dup addr tag name toml mss n up r
    local su stoml shost sport same_host keep cdef
    local -a IPS=() PORTS=() SVCS=() TARGETS=() FAILED=()

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

        # real TCP probe BEFORE creating the service: tells open / refused / timeout / no route
        echo "  Testing TCP $(format_hostport "$ip" "$port") ..."
        r=$(tcp_probe "$ip" "$port" 6)
        if [ "$r" = "OPEN" ]; then
            echo "  OK: $(format_hostport "$ip" "$port") accepts TCP connections."
        else
            echo "  Warning: $(format_hostport "$ip" "$port") did not accept the connection (${r})."
            diagnose_connect "$ip" "$port" "$r"
            FAILED+=("$(format_hostport "$ip" "$port")")
            if ! ask_yn "Add this Iran server anyway (the client keeps retrying)?" y; then
                echo "Enter it again."
                i=$((i - 1))
                continue
            fi
        fi

        IPS+=("$ip")
        PORTS+=("$port")
        prev_port="$port"
    done

    # --- old client(s) to the SAME Iran server on ANOTHER port (e.g. the previous tunnel port) ---
    # Without this they keep retrying forever and fill the log with "dial tcp ...: i/o timeout".
    for su in $(list_tunnel_units); do
        stoml=$(unit_toml "$su")
        [ -n "$stoml" ] && [ -f "$stoml" ] || continue
        grep -q '^\[client\]' "$stoml" || continue
        shost=$(toml_peer_host "$stoml")
        sport=$(toml_tunnel_port "$stoml")
        same_host=0
        keep=0
        for k in "${!IPS[@]}"; do
            if [ "${IPS[k]}" = "$shost" ]; then
                same_host=1
                [ "${PORTS[k]}" = "$sport" ] && keep=1
            fi
        done
        if [ "$same_host" = "1" ] && [ "$keep" = "0" ]; then
            n=$(unit_conn_count "$su")
            echo ""
            echo "Found an OLD client to the same Iran server on another port:"
            echo "  $su  ->  $(format_hostport "$shost" "$sport")   (tunnel connections now: ${n:-0})"
            if [ "${n:-0}" -gt 0 ]; then
                cdef=n
                echo "  It is CONNECTED right now — it looks like a second working tunnel, so the default is to keep it."
            else
                cdef=y
                echo "  It has no connection — most likely a dead leftover from a previous tunnel port."
            fi
            if ask_yn "Remove it?" "$cdef"; then
                delete_tunnel_unit "$su"
                echo "  removed $su"
            fi
        fi
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
    MSS_ON=$MSS_ENABLE
    setup_net_rules

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
            echo "  WAIT  ${TARGETS[k]}  (no tunnel connection yet)"
            r=$(tcp_probe "$(clean_ip_input "${IPS[k]}")" "${PORTS[k]}" 6)
            case "$r" in
                OPEN)    echo "        TCP port is open -> token / transport mismatch? compare both .toml files: grep -E 'token|transport' ${INSTALL_DIR}/*.toml" ;;
                REFUSED) echo "        port refused -> nothing listens there (Iran service down / wrong port / IPv4-only listener): menu 7 -> 7 on the Iran server" ;;
                *)       echo "        TCP ${r} -> firewall / provider / ISP filtering: menu 7 -> 6 here, menu 7 -> 8 on the Iran server" ;;
            esac
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

ask_token() {
    # sets TOKEN: Enter = default, own value, or r = random
    local t
    echo ""
    echo "Token: the ONLY authentication of the tunnel — it must be IDENTICAL on the Iran and on the Kharej server(s)."
    if [ "$LOCAL_ROLE" = "Kharej" ]; then
        echo "  Type exactly the token that the Iran server printed ('r' makes no sense here: it would not match)."
    else
        echo "  Enter = '${FIXED_TOKEN}'  |  type your own  |  r = generate a strong random token (copy it to the Kharej server)"
    fi
    while true; do
        ask t "Token [Enter = ${FIXED_TOKEN}]: " ""
        case "$t" in
            "")    TOKEN="$FIXED_TOKEN" ;;
            r|R)   if [ "$LOCAL_ROLE" = "Kharej" ]; then
                       echo "A random token would not match the Iran server — type the token the Iran server printed."
                       continue
                   fi
                   TOKEN=$(gen_token)
                   echo "Generated token: ${TOKEN}  (copy it — the Kharej server needs exactly this)" ;;
            *)     TOKEN="$t" ;;
        esac
        if valid_token "$TOKEN"; then
            return 0
        fi
        echo "The token may only contain letters, digits and . _ ~ + = -  (3-128 characters)."
    done
}

install_flow() {
    mkdir -p "$INSTALL_DIR"
    ensure_cmds curl tar ip ss ping >/dev/null 2>&1

    echo ""
    echo "Are you setting up the Iran server or the Kharej server?"
    choose LOCAL_ROLE "Role" "Iran" "Kharej" || return 0

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

    ask_token

    echo ""
    echo "TCP-MSS protection stops the 'ping works, but pages load half / lag' problem (path-MTU black hole),"
    echo "mostly seen on IPv6 links. It only touches the tunnel connections — do it on BOTH servers."
    if ask_yn "Enable MSS protection (recommended)?" y; then MSS_ENABLE=1; else MSS_ENABLE=0; fi
    mss_load_env

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        echo ""
        echo "Firewall: the tunnel port and the inbound ports must accept TCP from outside (IPv4 and IPv6)."
        echo "The script can open them (ufw / firewalld / iptables + ip6tables). A firewall in the provider's"
        echo "panel (security group / cloud firewall) it cannot touch — open the same ports there yourself."
        if ask_yn "Open the firewall for these ports automatically (recommended)?" y; then FW_OPEN=1; else FW_OPEN=0; fi
    fi

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
    echo "Backhaul version: $("$INSTALL_DIR/backhaul" -v 2>/dev/null | head -n1)  (should be the same on both servers)"
    echo "Check: systemctl status 'backhaul-*'   (or menu option 2)"
    if [ "$TOKEN" = "123" ]; then
        echo "(Reminder: the token is the fixed value '123' — it is the only authentication, so anyone who finds the"
        echo " tunnel port and guesses it can connect as a client. Menu 10 changes it later, identical on all servers.)"
    fi
    if [ "$MSS_ENABLE" = "1" ]; then
        echo "MSS clamp: IPv6 MSS ${MSS_V6}, IPv4 MSS ${MSS_V4} — run this script on the OTHER server too."
        echo "More: menu 7 -> 4 (diagnostics) / 2 (measure the real path MTU)."
    fi
    echo "Tunnel does not connect although ping works?  Menu 7 -> 6 (Kharej) / 7, 8, 9 (Iran)."

    # IPv6 tunnel: verify + repair right after the install (stable address, listener, firewall, probe, MSS)
    if { [ "$LOCAL_ROLE" = "Iran" ] && [ "$IP_MODE" = "6" ]; } \
        || { [ "$LOCAL_ROLE" = "Kharej" ] && grep -qsE '^remote_addr = "\[' "$INSTALL_DIR"/kharej-*.toml 2>/dev/null; }; then
        ipv6_repair auto
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
        echo "4) Manage services (start/stop/restart/logs/edit/delete)"
        echo "5) System optimizer (BBR + buffers + MTU cap + DNS + ulimits)"
        echo "6) Install/repair Watchdog (auto-restart on dead/idle tunnel)"
        echo "7) Connection tools: 'i/o timeout' diagnosis, firewall, MTU / MSS fix"
        echo "8) Uninstall tunnel"
        echo "9) Exit"
        echo "10) Change the token (all tunnels on this server)"
        echo "11) Update the Backhaul binary to the latest OFFICIAL release"
        echo "12) IPv6 check + repair (after install: stable address, listener, firewall, probe, MSS)"
        echo "13) Port-forward check (IPv4 / IPv6 listeners, backend targets)"
        ask CHOICE "Select an option [1-13]: "
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
            10) change_token ;;
            11) update_backhaul ;;
            12) ipv6_repair ;;
            13) forward_check ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# run the menu only when executed (not when sourced, e.g. for testing)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
