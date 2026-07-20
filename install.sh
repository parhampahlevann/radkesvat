#!/bin/bash
# ==========================================================
# TCP Tunnel Optimizer & Auto-Recovery — v2 (Smart Edition)
# Compatible with Rathole / Backhaul / any systemd-managed TCP tunnel
#
# What this does:
#  - Auto-detects the tunnel service and its config file
#  - Real TCP-port health checks (not just ICMP ping, which many
#    hosts block, causing false positives)
#  - Finds the real path MTU via binary-search probing instead of
#    guessing a fixed number
#  - Exponential backoff to prevent restart storms
#  - Log rotation so logs don't fill up the disk
#  - Idempotent: safe to run multiple times
# ==========================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  exit 1
fi

log()  { echo -e "\e[36m[*]\e[0m $1"; }
ok()   { echo -e "\e[32m[OK]\e[0m $1"; }
warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
err()  { echo -e "\e[31m[ERROR]\e[0m $1"; }

echo "=============================================="
echo "  Tunnel Optimizer v2 — starting"
echo "=============================================="

# ----------------------------------------------------------
# Step 0: Auto-detect the tunnel service (rathole/backhaul) and config
# ----------------------------------------------------------
log "Searching for the tunnel service ..."

DETECTED_SERVICE=""
for name in rathole backhaul; do
  if systemctl list-unit-files 2>/dev/null | grep -qi "^${name}"; then
    DETECTED_SERVICE=$(systemctl list-unit-files | grep -i "^${name}" | head -n1 | awk '{print $1}' | sed 's/\.service$//')
    break
  fi
done

if [ -n "$DETECTED_SERVICE" ]; then
  ok "Found service: $DETECTED_SERVICE"
  read -rp "Confirm service name [press Enter to accept, or type the correct name]: " INPUT_SERVICE
  TUNNEL_SERVICE="${INPUT_SERVICE:-$DETECTED_SERVICE}"
else
  warn "Auto-detection found nothing."
  read -rp "Enter the exact systemd service name for your tunnel: " TUNNEL_SERVICE
fi

if ! systemctl list-unit-files | grep -q "^${TUNNEL_SERVICE}.service"; then
  err "No service named ${TUNNEL_SERVICE} found in systemd."
  err "If you're running it with nohup/screen, you need a systemd unit first — auto-restart can't work without one."
  exit 1
fi

# Try to locate config and extract the remote endpoint
CONFIG_CANDIDATES=$(find /etc /opt /root -maxdepth 4 \( -iname "*rathole*" -o -iname "*backhaul*" \) \( -iname "*.toml" -o -iname "*.json" -o -iname "*.yaml" -o -iname "*.yml" -o -iname "*.conf" \) 2>/dev/null || true)

REMOTE_HOST=""
REMOTE_PORT=""

if [ -n "$CONFIG_CANDIDATES" ]; then
  log "Found config file(s):"
  echo "$CONFIG_CANDIDATES" | sed 's/^/    /'
  # Common pattern: remote_addr = "1.2.3.4:2333"  or  "server": "1.2.3.4:2333"
  GUESS=$(grep -hoE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}' $CONFIG_CANDIDATES 2>/dev/null | head -n1 || true)
  if [ -n "$GUESS" ]; then
    REMOTE_HOST="${GUESS%%:*}"
    REMOTE_PORT="${GUESS##*:}"
    ok "Guessed endpoint: $REMOTE_HOST:$REMOTE_PORT"
  fi
fi

read -rp "Remote server IP [${REMOTE_HOST:-enter it}]: " INPUT_HOST
REMOTE_HOST="${INPUT_HOST:-$REMOTE_HOST}"
read -rp "Remote tunnel TCP port [${REMOTE_PORT:-enter it}]: " INPUT_PORT
REMOTE_PORT="${INPUT_PORT:-$REMOTE_PORT}"

if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_PORT" ]; then
  err "Can't do real health checks without the remote host and port."
  exit 1
fi

ok "Monitoring target: ${REMOTE_HOST}:${REMOTE_PORT}  |  Service: ${TUNNEL_SERVICE}"

# ----------------------------------------------------------
# Step 1: Kernel network tuning
# ----------------------------------------------------------
echo ""
log "[1/5] Applying kernel network tuning ..."

SYSCTL_FILE="/etc/sysctl.d/99-tunnel-optimizer.conf"

# Check whether BBR is available (some minimal kernels lack it)
modprobe tcp_bbr 2>/dev/null || true
if [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ] && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  CC_ALGO="bbr"
  QDISC="fq"
  ok "BBR is available, using it."
else
  CC_ALGO="cubic"
  QDISC="fq_codel"
  warn "BBR not available, falling back to cubic + fq_codel."
fi

cat > "$SYSCTL_FILE" << EOF
# --- TCP keepalive: keeps the connection alive even during idle periods ---
net.ipv4.tcp_keepalive_time = 20
net.ipv4.tcp_keepalive_intvl = 8
net.ipv4.tcp_keepalive_probes = 5

# --- Prevents throughput collapse after idle (a common cause of tunnel drops) ---
net.ipv4.tcp_slow_start_after_idle = 0

# --- Faster cleanup of half-closed connections ---
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1

# --- Larger network buffers for VPN traffic ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# --- Modern congestion control and queueing ---
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC_ALGO}

# --- Faster recovery on link drops instead of long hangs ---
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 6

# --- Path MTU discovery, to avoid packet drops from fragmentation ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# --- More open files and ports for concurrent connections ---
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535

# --- IPv6 keepalive too, in case the tunnel runs over v6 ---
net.ipv6.conf.all.disable_ipv6 = 0
EOF

sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "Some values may need an extra kernel module — that's fine."

# Only configure nf_conntrack if the module is actually loaded (otherwise sysctl errors out)
if lsmod | grep -q nf_conntrack || modprobe nf_conntrack 2>/dev/null; then
  cat >> "$SYSCTL_FILE" << 'EOF'
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  ok "conntrack tuning added as well."
fi

ok "Kernel tuning applied (congestion control: ${CC_ALGO})."

# ----------------------------------------------------------
# Step 2: Find the real MTU via path-MTU testing (not a guess)
# ----------------------------------------------------------
echo ""
log "[2/5] Testing real path MTU to ${REMOTE_HOST} ..."

IFACE=$(ip route get "$REMOTE_HOST" 2>/dev/null | grep -oP 'dev \K[^ ]+' | head -n1)
if [ -z "$IFACE" ]; then
  IFACE=$(ip route | awk '/default/ {print $5; exit}')
fi

find_mtu() {
  local low=1200 high=1500 size=1500 best=1200
  while [ $((high - low)) -gt 10 ]; do
    size=$(( (low + high) / 2 ))
    payload=$((size - 28))
    if ping -c 1 -W 1 -M do -s "$payload" "$REMOTE_HOST" > /dev/null 2>&1; then
      best=$size
      low=$size
    else
      high=$size
    fi
  done
  echo "$best"
}

if [ -n "$IFACE" ]; then
  DETECTED_MTU=$(find_mtu || echo "1420")
  if [ "$DETECTED_MTU" -lt 1200 ]; then
    DETECTED_MTU=1420
    warn "MTU test gave an unreasonable result, using safe default 1420."
  fi
  ip link set dev "$IFACE" mtu "$DETECTED_MTU" 2>/dev/null && \
    ok "Real path MTU: ${DETECTED_MTU} — applied on $IFACE." || \
    warn "Couldn't set MTU automatically, run manually: ip link set dev $IFACE mtu $DETECTED_MTU"
else
  warn "No network interface found, skipping this step."
fi

# ----------------------------------------------------------
# Step 3: Smart watchdog with real TCP checks + exponential backoff
# ----------------------------------------------------------
echo ""
log "[3/5] Installing the smart watchdog ..."

WATCHDOG_SCRIPT="/usr/local/bin/tunnel-watchdog.sh"
cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
# Tunnel watchdog: real TCP-port health check (not just ping)
# Uses exponential backoff to prevent restart storms

SERVICE="${TUNNEL_SERVICE}"
TARGET="${REMOTE_HOST}"
PORT="${REMOTE_PORT}"
FAIL_COUNT=0
MAX_FAIL=3
BACKOFF=5
MAX_BACKOFF=300

check_health() {
  timeout 3 bash -c "echo > /dev/tcp/\${TARGET}/\${PORT}" 2>/dev/null
}

while true; do
  if check_health; then
    if [ "\$FAIL_COUNT" -gt 0 ]; then
      logger -t tunnel-watchdog "connection recovered, resetting fail counter"
    fi
    FAIL_COUNT=0
    BACKOFF=5
  else
    FAIL_COUNT=\$((FAIL_COUNT + 1))
    logger -t tunnel-watchdog "health check failed (\$FAIL_COUNT/\$MAX_FAIL) -> \${TARGET}:\${PORT}"
  fi

  if [ "\$FAIL_COUNT" -ge "\$MAX_FAIL" ]; then
    logger -t tunnel-watchdog "restarting \$SERVICE (backoff: \${BACKOFF}s)"
    systemctl restart "\$SERVICE"
    FAIL_COUNT=0
    sleep "\$BACKOFF"
    # Exponential backoff up to a cap, to avoid a runaway restart loop
    BACKOFF=\$(( BACKOFF * 2 ))
    [ "\$BACKOFF" -gt "\$MAX_BACKOFF" ] && BACKOFF=\$MAX_BACKOFF
    continue
  fi

  sleep 8
done
EOF

chmod +x "$WATCHDOG_SCRIPT"

cat > /etc/systemd/system/tunnel-watchdog.service << EOF
[Unit]
Description=Smart Tunnel Watchdog (TCP health-check + auto restart)
After=network-online.target ${TUNNEL_SERVICE}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Log rotation, so syslog doesn't fill up with health-check entries
cat > /etc/logrotate.d/tunnel-watchdog << 'EOF'
/var/log/syslog {
  weekly
  rotate 4
  compress
  missingok
  notifempty
}
EOF

ok "Watchdog installed."

# ----------------------------------------------------------
# Step 4: Restart=always on the tunnel service itself (systemd level)
# ----------------------------------------------------------
echo ""
log "[4/5] Enabling systemd-level auto-restart for ${TUNNEL_SERVICE} ..."

OVERRIDE_DIR="/etc/systemd/system/${TUNNEL_SERVICE}.service.d"
mkdir -p "$OVERRIDE_DIR"
cat > "${OVERRIDE_DIR}/override.conf" << 'EOF'
[Service]
Restart=always
RestartSec=3
StartLimitIntervalSec=0
# Raise open-file limit for many concurrent connections
LimitNOFILE=1048576
EOF

ok "override.conf created for ${TUNNEL_SERVICE}."

# ----------------------------------------------------------
# Step 5: Final activation
# ----------------------------------------------------------
echo ""
log "[5/5] Enabling services ..."

systemctl daemon-reload
systemctl enable --now tunnel-watchdog.service
systemctl restart "$TUNNEL_SERVICE"

echo ""
echo "=============================================="
ok "Optimization complete"
echo "=============================================="
echo ""
echo "Useful commands to check status:"
echo "  journalctl -u tunnel-watchdog -f       # live watchdog log"
echo "  systemctl status ${TUNNEL_SERVICE}     # tunnel service status"
echo "  sysctl net.ipv4.tcp_congestion_control # check active algorithm"
echo ""
echo "To fully undo these changes:"
echo "  systemctl disable --now tunnel-watchdog"
echo "  rm ${SYSCTL_FILE} ${WATCHDOG_SCRIPT} ${OVERRIDE_DIR}/override.conf"
echo "  systemctl daemon-reload && sysctl --system"
