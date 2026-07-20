#!/bin/bash
# ==========================================================
# Universal Connection Stabilizer v3
# Works on any server, with any tunnel/VPN software (or none).
# Doesn't need to know what tunnel you're running.
#
# Usage:
#   sudo ./stabilizer.sh install                       # kernel tuning only
#   sudo ./stabilizer.sh install --service NAME         # + watchdog for a
#                                                          specific systemd
#                                                          service
#   sudo ./stabilizer.sh install --service NAME \
#                                --target HOST --port PORT
#                                                        # + real TCP health
#                                                          checks against a
#                                                          remote endpoint
#   sudo ./stabilizer.sh status                          # verify everything
#   sudo ./stabilizer.sh uninstall                       # revert all changes
# ==========================================================

set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-stabilizer.conf"
WATCHDOG_SCRIPT="/usr/local/bin/conn-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/conn-watchdog.service"
STATE_FILE="/etc/stabilizer.state"
LOGROTATE_FILE="/etc/logrotate.d/conn-watchdog"

log()  { echo -e "\e[36m[*]\e[0m $1"; }
ok()   { echo -e "\e[32m[OK]\e[0m $1"; }
warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
err()  { echo -e "\e[31m[FAIL]\e[0m $1"; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "Run this as root or with sudo."
    exit 1
  fi
}

# ==========================================================
# INSTALL
# ==========================================================
do_install() {
  require_root

  SERVICE=""
  TARGET=""
  PORT=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --service) SERVICE="$2"; shift 2 ;;
      --target)  TARGET="$2"; shift 2 ;;
      --port)    PORT="$2"; shift 2 ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  echo "=============================================="
  echo "  Universal Connection Stabilizer — installing"
  echo "=============================================="

  # ------------------------------------------------------
  # 1. Kernel / network tuning — always applied, tunnel-agnostic
  # ------------------------------------------------------
  log "[1/4] Applying kernel network tuning ..."

  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC_ALGO="bbr"; QDISC="fq"
    ok "BBR available, using it."
  else
    CC_ALGO="cubic"; QDISC="fq_codel"
    warn "BBR not available, falling back to cubic + fq_codel."
  fi

  cat > "$SYSCTL_FILE" << EOF
# Keepalive: keeps idle connections from silently dying
net.ipv4.tcp_keepalive_time = 20
net.ipv4.tcp_keepalive_intvl = 8
net.ipv4.tcp_keepalive_probes = 5

# Prevents throughput collapse after idle periods
net.ipv4.tcp_slow_start_after_idle = 0

# Faster cleanup of half-closed sockets
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1

# Larger buffers for tunneled/VPN traffic
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Modern congestion control
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC_ALGO}

# Faster recovery on link drops
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 6

# Path MTU discovery — avoids drops from fragmentation
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# Headroom for many concurrent connections
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535
EOF

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "Some values may need an extra module — that's fine."

  if lsmod | grep -q nf_conntrack || modprobe nf_conntrack 2>/dev/null; then
    cat >> "$SYSCTL_FILE" << 'EOF'
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  fi

  ok "Kernel tuning applied (congestion control: ${CC_ALGO})."

  # ------------------------------------------------------
  # 2. MTU probing — generic, uses target if given, else the default gateway
  # ------------------------------------------------------
  echo ""
  log "[2/4] Testing path MTU ..."

  PROBE_HOST="${TARGET:-}"
  if [ -z "$PROBE_HOST" ]; then
    PROBE_HOST=$(ip route | awk '/default/ {print $3; exit}')
  fi

  IFACE=$(ip route | awk '/default/ {print $5; exit}')

  find_mtu() {
    local low=1200 high=1500 size best=1200
    while [ $((high - low)) -gt 10 ]; do
      size=$(( (low + high) / 2 ))
      payload=$((size - 28))
      if ping -c 1 -W 1 -M do -s "$payload" "$PROBE_HOST" > /dev/null 2>&1; then
        best=$size; low=$size
      else
        high=$size
      fi
    done
    echo "$best"
  }

  if [ -n "$PROBE_HOST" ] && [ -n "$IFACE" ]; then
    DETECTED_MTU=$(find_mtu || echo "1420")
    [ "$DETECTED_MTU" -lt 1200 ] && DETECTED_MTU=1420
    ip link set dev "$IFACE" mtu "$DETECTED_MTU" 2>/dev/null && \
      ok "MTU set to ${DETECTED_MTU} on $IFACE (probed against ${PROBE_HOST})." || \
      warn "Could not set MTU automatically. Run manually: ip link set dev $IFACE mtu $DETECTED_MTU"
  else
    warn "No probe target or interface found, skipping MTU step."
    DETECTED_MTU="skipped"
  fi

  # ------------------------------------------------------
  # 3. Optional watchdog — only if a service was specified
  # ------------------------------------------------------
  echo ""
  if [ -n "$SERVICE" ]; then
    log "[3/4] Installing watchdog for service '${SERVICE}' ..."

    if ! systemctl list-unit-files | grep -q "^${SERVICE}.service"; then
      err "No systemd service named '${SERVICE}' found. Skipping watchdog."
      SERVICE=""
    else
      cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
# Generic connection watchdog. Health check depends on what was configured:
#  - if TARGET+PORT given: real TCP connect check
#  - if only TARGET given: ICMP ping check
#  - if nothing given: just checks the service is 'active' in systemd
SERVICE="${SERVICE}"
TARGET="${TARGET}"
PORT="${PORT}"
FAIL_COUNT=0
MAX_FAIL=3
BACKOFF=5
MAX_BACKOFF=300

check_health() {
  if [ -n "\$TARGET" ] && [ -n "\$PORT" ]; then
    timeout 3 bash -c "echo > /dev/tcp/\${TARGET}/\${PORT}" 2>/dev/null
  elif [ -n "\$TARGET" ]; then
    ping -c 1 -W 2 "\$TARGET" > /dev/null 2>&1
  else
    systemctl is-active --quiet "\$SERVICE"
  fi
}

while true; do
  if check_health; then
    [ "\$FAIL_COUNT" -gt 0 ] && logger -t conn-watchdog "recovered, resetting counter"
    FAIL_COUNT=0
    BACKOFF=5
  else
    FAIL_COUNT=\$((FAIL_COUNT + 1))
    logger -t conn-watchdog "health check failed (\$FAIL_COUNT/\$MAX_FAIL)"
  fi

  if [ "\$FAIL_COUNT" -ge "\$MAX_FAIL" ]; then
    logger -t conn-watchdog "restarting \$SERVICE (backoff: \${BACKOFF}s)"
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
Description=Generic Connection Watchdog for ${SERVICE}
After=network-online.target ${SERVICE}.service
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

      # Auto-restart at the systemd level for the target service too
      OVERRIDE_DIR="/etc/systemd/system/${SERVICE}.service.d"
      mkdir -p "$OVERRIDE_DIR"
      cat > "${OVERRIDE_DIR}/override.conf" << 'EOF'
[Service]
Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=1048576
EOF

      systemctl daemon-reload
      systemctl enable --now conn-watchdog.service
      systemctl restart "$SERVICE" 2>/dev/null || true
      ok "Watchdog installed and watching '${SERVICE}'."
    fi
  else
    log "[3/4] No --service given, skipping watchdog (kernel tuning still applies system-wide)."
  fi

  # ------------------------------------------------------
  # 4. Save state for the status/uninstall commands
  # ------------------------------------------------------
  echo ""
  log "[4/4] Saving install state ..."
  cat > "$STATE_FILE" << EOF
INSTALLED_AT=$(date -Iseconds)
SERVICE=${SERVICE}
TARGET=${TARGET}
PORT=${PORT}
IFACE=${IFACE:-}
MTU=${DETECTED_MTU:-}
CC_ALGO=${CC_ALGO}
EOF
  ok "State saved to ${STATE_FILE}."

  echo ""
  echo "=============================================="
  ok "Install complete. Run: sudo $0 status"
  echo "=============================================="
}

# ==========================================================
# STATUS
# ==========================================================
do_status() {
  echo "=============================================="
  echo "  Stabilizer Status Check"
  echo "=============================================="

  if [ ! -f "$STATE_FILE" ]; then
    err "Not installed (no ${STATE_FILE} found). Run: sudo $0 install"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_FILE"
  echo "Installed at : ${INSTALLED_AT:-unknown}"
  echo ""

  # sysctl check
  if [ -f "$SYSCTL_FILE" ]; then
    ok "sysctl config file present: $SYSCTL_FILE"
  else
    err "sysctl config file missing!"
  fi

  ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  if [ "$ACTIVE_CC" = "${CC_ALGO:-}" ]; then
    ok "Congestion control active: $ACTIVE_CC"
  else
    warn "Congestion control is '$ACTIVE_CC', expected '${CC_ALGO:-unknown}'."
  fi

  ACTIVE_KEEPALIVE=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "unknown")
  echo "TCP keepalive time      : ${ACTIVE_KEEPALIVE}s"

  # MTU check
  if [ -n "${IFACE:-}" ]; then
    CURRENT_MTU=$(ip link show "$IFACE" 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "unknown")
    echo "Interface $IFACE MTU     : $CURRENT_MTU (target was: ${MTU:-n/a})"
  fi

  echo ""

  # Watchdog check
  if [ -n "${SERVICE:-}" ]; then
    echo "--- Watchdog for service: $SERVICE ---"
    if systemctl is-active --quiet conn-watchdog.service; then
      ok "conn-watchdog.service is running."
    else
      err "conn-watchdog.service is NOT running."
    fi

    if systemctl is-active --quiet "$SERVICE"; then
      ok "$SERVICE is active."
    else
      err "$SERVICE is NOT active."
    fi

    if [ -f "/etc/systemd/system/${SERVICE}.service.d/override.conf" ]; then
      ok "Auto-restart override present for $SERVICE."
    else
      warn "No auto-restart override found for $SERVICE."
    fi

    echo ""
    echo "Last 5 watchdog log lines:"
    journalctl -t conn-watchdog -n 5 --no-pager 2>/dev/null || echo "  (no logs yet)"
  else
    echo "No watchdog was configured (kernel tuning only)."
  fi

  echo ""
  echo "=============================================="
  echo "  Status check complete"
  echo "=============================================="
}

# ==========================================================
# UNINSTALL
# ==========================================================
do_uninstall() {
  require_root

  if [ ! -f "$STATE_FILE" ]; then
    err "Nothing to uninstall — ${STATE_FILE} not found."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_FILE"

  log "Reverting changes ..."

  systemctl disable --now conn-watchdog.service 2>/dev/null || true
  rm -f "$WATCHDOG_SCRIPT" "$WATCHDOG_SERVICE" "$LOGROTATE_FILE"

  if [ -n "${SERVICE:-}" ] && [ -f "/etc/systemd/system/${SERVICE}.service.d/override.conf" ]; then
    rm -f "/etc/systemd/system/${SERVICE}.service.d/override.conf"
  fi

  rm -f "$SYSCTL_FILE"
  sysctl --system >/dev/null 2>&1 || true

  rm -f "$STATE_FILE"
  systemctl daemon-reload

  ok "All changes reverted."
}

# ==========================================================
# ENTRY POINT
# ==========================================================
case "${1:-}" in
  install)   shift; do_install "$@" ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
  *)
    echo "Usage:"
    echo "  sudo $0 install [--service NAME] [--target HOST] [--port PORT]"
    echo "  sudo $0 status"
    echo "  sudo $0 uninstall"
    exit 1
    ;;
esac
