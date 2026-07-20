#!/bin/bash
# ==========================================================
# NetFix — One-Click Connection Stabilizer with Menu
# Auto-detects everything. No questions asked.
# ==========================================================
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-netfix.conf"
WATCHDOG_SCRIPT="/usr/local/bin/netfix-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/netfix-watchdog.service"
LOGROTATE_FILE="/etc/logrotate.d/netfix-watchdog"
STATE_FILE="/etc/netfix.state"

C_RESET="\e[0m"; C_CYAN="\e[36m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RED="\e[31m"; C_BOLD="\e[1m"

log()  { echo -e "${C_CYAN}[*]${C_RESET} $1"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
err()  { echo -e "${C_RED}[FAIL]${C_RESET} $1"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "Run as root or with sudo."
    exit 1
  fi
}

# ----------------------------------------------------------
# Auto-detect the busiest outbound tunnel-like connection and
# the systemd service that owns it — zero prompts.
# ----------------------------------------------------------
autodetect() {
  DETECTED_SERVICE=""
  DETECTED_TARGET=""
  DETECTED_PORT=""

  local top_conn
  top_conn=$(ss -tnp 2>/dev/null | awk '/ESTAB/ {print $4}' | grep -v '^127\.' | sort | uniq -c | sort -rn | head -n1 || true)

  if [ -n "$top_conn" ]; then
    local remote
    remote=$(echo "$top_conn" | awk '{print $2}')
    DETECTED_TARGET="${remote%:*}"
    DETECTED_PORT="${remote##*:}"

    local pid
    pid=$(ss -tnp 2>/dev/null | grep "$remote" | grep -oP 'pid=\K[0-9]+' | head -n1 || true)
    if [ -n "$pid" ]; then
      DETECTED_SERVICE=$(systemctl status "$pid" 2>/dev/null | grep -oP '\S+\.service' | head -n1 | sed 's/\.service$//' || true)
      if [ -z "$DETECTED_SERVICE" ]; then
        DETECTED_SERVICE=$(cat "/proc/${pid}/cgroup" 2>/dev/null | grep -oP '\S+\.service' | head -n1 | sed 's/\.service$//' || true)
      fi
    fi
  fi

  if [ -z "$DETECTED_SERVICE" ]; then
    for name in rathole backhaul xray v2ray sing-box wireguard wg-quick openvpn gost frp ssh; do
      local match
      match=$(systemctl list-unit-files 2>/dev/null | grep -i "^${name}" | head -n1 | awk '{print $1}' | sed 's/\.service$//' || true)
      if [ -n "$match" ]; then
        DETECTED_SERVICE="$match"
        break
      fi
    done
  fi
}

# ----------------------------------------------------------
# INSTALL — fully automatic, no prompts
# ----------------------------------------------------------
do_install() {
  require_root
  echo "=============================================="
  echo "  NetFix — installing (auto mode)"
  echo "=============================================="

  autodetect
  if [ -n "$DETECTED_SERVICE" ]; then
    ok "Detected tunnel service: $DETECTED_SERVICE"
  else
    warn "No tunnel service detected — will apply kernel tuning only."
  fi
  if [ -n "$DETECTED_TARGET" ]; then
    ok "Detected remote endpoint: ${DETECTED_TARGET}:${DETECTED_PORT}"
  fi

  log "Applying kernel network tuning ..."
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC_ALGO="bbr"; QDISC="fq"
  else
    CC_ALGO="cubic"; QDISC="fq_codel"
  fi

  cat > "$SYSCTL_FILE" << EOF
net.ipv4.tcp_keepalive_time = 20
net.ipv4.tcp_keepalive_intvl = 8
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC_ALGO}
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 6
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

  if lsmod | grep -q nf_conntrack || modprobe nf_conntrack 2>/dev/null; then
    cat >> "$SYSCTL_FILE" << 'EOF'
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  fi
  ok "Kernel tuning applied (${CC_ALGO})."

  log "Probing path MTU ..."
  PROBE_HOST="${DETECTED_TARGET:-$(ip route | awk '/default/ {print $3; exit}')}"
  IFACE=$(ip route | awk '/default/ {print $5; exit}')
  MTU_RESULT="skipped"
  if [ -n "$PROBE_HOST" ] && [ -n "$IFACE" ]; then
    low=1200; high=1500; best=1200
    while [ $((high - low)) -gt 10 ]; do
      size=$(( (low + high) / 2 ))
      payload=$((size - 28))
      if ping -c 1 -W 1 -M do -s "$payload" "$PROBE_HOST" > /dev/null 2>&1; then
        best=$size; low=$size
      else
        high=$size
      fi
    done
    [ "$best" -lt 1200 ] && best=1420
    ip link set dev "$IFACE" mtu "$best" 2>/dev/null && MTU_RESULT="$best"
    ok "MTU set to ${MTU_RESULT} on $IFACE."
  else
    warn "Could not determine a probe target/interface, skipping MTU."
  fi

  if [ -n "$DETECTED_SERVICE" ] && systemctl list-unit-files | grep -q "^${DETECTED_SERVICE}.service"; then
    log "Installing watchdog for ${DETECTED_SERVICE} ..."

    cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
SERVICE="${DETECTED_SERVICE}"
TARGET="${DETECTED_TARGET}"
PORT="${DETECTED_PORT}"
FAIL_COUNT=0
MAX_FAIL=3
BACKOFF=5
MAX_BACKOFF=300

check_health() {
  if [ -n "\$TARGET" ] && [ -n "\$PORT" ]; then
    timeout 3 bash -c "echo > /dev/tcp/\${TARGET}/\${PORT}" 2>/dev/null
  else
    systemctl is-active --quiet "\$SERVICE"
  fi
}

while true; do
  if check_health; then
    [ "\$FAIL_COUNT" -gt 0 ] && logger -t netfix-watchdog "recovered"
    FAIL_COUNT=0
    BACKOFF=5
  else
    FAIL_COUNT=\$((FAIL_COUNT + 1))
    logger -t netfix-watchdog "health check failed (\$FAIL_COUNT/\$MAX_FAIL)"
  fi
  if [ "\$FAIL_COUNT" -ge "\$MAX_FAIL" ]; then
    logger -t netfix-watchdog "restarting \$SERVICE (backoff \${BACKOFF}s)"
    systemctl restart "\$SERVICE"
    FAIL_COUNT=0
    sleep "\$BACKOFF"
    BACKOFF=\$(( BACKOFF * 2 ))
    [ "\$BACKOFF" -gt "\$MAX_BACKOFF" ] && BACKOFF=\$MAX_BACKOFF
    continue
  fi
  sleep 8
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_SERVICE" << EOF
[Unit]
Description=NetFix Watchdog for ${DETECTED_SERVICE}
After=network-online.target ${DETECTED_SERVICE}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > "$LOGROTATE_FILE" << 'EOF'
/var/log/syslog {
  weekly
  rotate 4
  compress
  missingok
  notifempty
}
EOF

    OVERRIDE_DIR="/etc/systemd/system/${DETECTED_SERVICE}.service.d"
    mkdir -p "$OVERRIDE_DIR"
    cat > "${OVERRIDE_DIR}/override.conf" << 'EOF'
[Service]
Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=1048576
EOF

    systemctl daemon-reload
    systemctl enable --now netfix-watchdog.service
    ok "Watchdog running for ${DETECTED_SERVICE}."
  else
    warn "Skipping watchdog — no active tunnel service found to attach to."
  fi

  cat > "$STATE_FILE" << EOF
INSTALLED_AT=$(date -Iseconds)
SERVICE=${DETECTED_SERVICE}
TARGET=${DETECTED_TARGET}
PORT=${DETECTED_PORT}
IFACE=${IFACE:-}
MTU=${MTU_RESULT}
CC_ALGO=${CC_ALGO}
EOF

  echo ""
  echo "=============================================="
  ok "Install complete."
  echo "=============================================="
}

# ----------------------------------------------------------
# STATUS
# ----------------------------------------------------------
do_status() {
  echo "=============================================="
  echo "  NetFix — Status"
  echo "=============================================="

  if [ ! -f "$STATE_FILE" ]; then
    err "Not installed yet."
    return
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  echo "Installed at        : ${INSTALLED_AT:-unknown}"

  [ -f "$SYSCTL_FILE" ] && ok "sysctl config present" || err "sysctl config missing"

  ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  if [ "$ACTIVE_CC" = "${CC_ALGO:-}" ]; then
    ok "Congestion control  : $ACTIVE_CC"
  else
    warn "Congestion control  : $ACTIVE_CC (expected ${CC_ALGO:-unknown})"
  fi

  if [ -n "${IFACE:-}" ]; then
    CURRENT_MTU=$(ip link show "$IFACE" 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "unknown")
    echo "MTU on $IFACE        : $CURRENT_MTU (set to: ${MTU:-n/a})"
  fi

  echo ""
  if [ -n "${SERVICE:-}" ]; then
    echo "Watched service      : $SERVICE"
    systemctl is-active --quiet netfix-watchdog.service && ok "netfix-watchdog is running" || err "netfix-watchdog is NOT running"
    systemctl is-active --quiet "$SERVICE" && ok "$SERVICE is active" || err "$SERVICE is NOT active"
    [ -f "/etc/systemd/system/${SERVICE}.service.d/override.conf" ] && ok "auto-restart override present" || warn "no auto-restart override"
    echo ""
    echo "Last 5 watchdog log lines:"
    journalctl -t netfix-watchdog -n 5 --no-pager 2>/dev/null || echo "  (no logs yet)"
  else
    echo "No service is being watched (kernel tuning only)."
  fi
  echo "=============================================="
}

# ----------------------------------------------------------
# UNINSTALL
# ----------------------------------------------------------
do_uninstall() {
  require_root
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  systemctl disable --now netfix-watchdog.service 2>/dev/null || true
  rm -f "$WATCHDOG_SCRIPT" "$WATCHDOG_SERVICE" "$LOGROTATE_FILE" "$SYSCTL_FILE" "$STATE_FILE"

  if [ -n "${SERVICE:-}" ] && [ -f "/etc/systemd/system/${SERVICE}.service.d/override.conf" ]; then
    rm -f "/etc/systemd/system/${SERVICE}.service.d/override.conf"
  fi

  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true
  ok "Uninstalled. Everything reverted."
}

# ----------------------------------------------------------
# MENU
# ----------------------------------------------------------
show_menu() {
  clear
  echo -e "${C_BOLD}=================================================${C_RESET}"
  echo -e "${C_BOLD}         NetFix — Connection Stabilizer${C_RESET}"
  echo -e "${C_BOLD}=================================================${C_RESET}"
  echo ""
  if [ -f "$STATE_FILE" ]; then
    echo -e "  Status: ${C_GREEN}Installed${C_RESET}"
  else
    echo -e "  Status: ${C_YELLOW}Not installed${C_RESET}"
  fi
  echo ""
  echo "  1) Install / Fix Now  (fully automatic)"
  echo "  2) Show Status"
  echo "  3) Uninstall"
  echo "  4) Exit"
  echo ""
  read -rp "  Select an option [1-4]: " choice
  case "$choice" in
    1) do_install; read -rp $'\nPress Enter to return to menu...' _; show_menu ;;
    2) do_status; read -rp $'\nPress Enter to return to menu...' _; show_menu ;;
    3) do_uninstall; read -rp $'\nPress Enter to return to menu...' _; show_menu ;;
    4) exit 0 ;;
    *) show_menu ;;
  esac
}

# ----------------------------------------------------------
# ENTRY POINT — supports both menu and direct CLI args
# ----------------------------------------------------------
case "${1:-menu}" in
  install)   do_install ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
  menu)      show_menu ;;
  *)
    echo "Usage: sudo $0 [install|status|uninstall|menu]"
    exit 1
    ;;
esac
