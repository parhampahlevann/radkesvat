#!/bin/bash
# ==========================================================
# TCP Tunnel Optimizer & Auto-Recovery — v2 (Smart Edition)
# سازگار با Rathole / Backhaul / هر تانل مبتنی بر systemd
#
# چه فرقی با نسخه قبل داره؟
#  - سرویس تانل و آدرس سرور مقابل رو خودش از کانفیگ پیدا می‌کنه
#  - چک سلامت واقعی روی پورت TCP انجام میشه (نه فقط ping که
#    خیلی جاها ICMP بلاکه و گزارش غلط میده)
#  - MTU رو حدس نمی‌زنه، با تست واقعی path-MTU discovery پیدا می‌کنه
#  - جلوی «restart storm» رو با backoff نمایی می‌گیره
#  - لاگ‌ها rotate میشن تا دیسک پر نشه
#  - idempotent هست: چند بار اجرا کنی خراب نمی‌کنه
# ==========================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "لطفاً با sudo یا root اجرا کن."
  exit 1
fi

log()  { echo -e "\e[36m[*]\e[0m $1"; }
ok()   { echo -e "\e[32m[✔]\e[0m $1"; }
warn() { echo -e "\e[33m[⚠]\e[0m $1"; }
err()  { echo -e "\e[31m[✘]\e[0m $1"; }

echo "=============================================="
echo "  Tunnel Optimizer v2 — شروع"
echo "=============================================="

# ----------------------------------------------------------
# بخش ۰: تشخیص خودکار سرویس تانل (rathole/backhaul) و کانفیگش
# ----------------------------------------------------------
log "در حال جستجوی سرویس تانل ..."

DETECTED_SERVICE=""
for name in rathole backhaul; do
  if systemctl list-unit-files 2>/dev/null | grep -qi "^${name}"; then
    DETECTED_SERVICE=$(systemctl list-unit-files | grep -i "^${name}" | head -n1 | awk '{print $1}' | sed 's/\.service$//')
    break
  fi
done

if [ -n "$DETECTED_SERVICE" ]; then
  ok "سرویس پیدا شد: $DETECTED_SERVICE"
  read -rp "اسم سرویس رو تایید می‌کنی؟ [Enter برای تایید یا اسم درست رو بنویس]: " INPUT_SERVICE
  TUNNEL_SERVICE="${INPUT_SERVICE:-$DETECTED_SERVICE}"
else
  warn "سرویس‌شناسی خودکار چیزی پیدا نکرد."
  read -rp "اسم دقیق سرویس systemd تانلت رو وارد کن: " TUNNEL_SERVICE
fi

if ! systemctl list-unit-files | grep -q "^${TUNNEL_SERVICE}.service"; then
  err "سرویسی به اسم ${TUNNEL_SERVICE} در systemd پیدا نشد."
  err "اگه با nohup/screen اجراش می‌کنی، اول باید براش systemd unit بسازی. این اسکریپت بدون اون نمی‌تونه ری‌استارت خودکار انجام بده."
  exit 1
fi

# تلاش برای پیدا کردن کانفیگ و استخراج آدرس/پورت سرور مقابل
CONFIG_CANDIDATES=$(find /etc /opt /root -maxdepth 4 \( -iname "*rathole*" -o -iname "*backhaul*" \) \( -iname "*.toml" -o -iname "*.json" -o -iname "*.yaml" -o -iname "*.yml" -o -iname "*.conf" \) 2>/dev/null || true)

REMOTE_HOST=""
REMOTE_PORT=""

if [ -n "$CONFIG_CANDIDATES" ]; then
  log "فایل‌های کانفیگ پیدا شده:"
  echo "$CONFIG_CANDIDATES" | sed 's/^/    /'
  # الگوی رایج: remote_addr = "1.2.3.4:2333"  یا  "server": "1.2.3.4:2333"
  GUESS=$(grep -hoE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}' $CONFIG_CANDIDATES 2>/dev/null | head -n1 || true)
  if [ -n "$GUESS" ]; then
    REMOTE_HOST="${GUESS%%:*}"
    REMOTE_PORT="${GUESS##*:}"
    ok "حدس زده شد: $REMOTE_HOST:$REMOTE_PORT"
  fi
fi

read -rp "IP سرور مقابل [${REMOTE_HOST:-وارد کن}]: " INPUT_HOST
REMOTE_HOST="${INPUT_HOST:-$REMOTE_HOST}"
read -rp "پورت TCP تانل روی سرور مقابل [${REMOTE_PORT:-وارد کن}]: " INPUT_PORT
REMOTE_PORT="${INPUT_PORT:-$REMOTE_PORT}"

if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_PORT" ]; then
  err "بدون IP و پورت سرور مقابل نمی‌تونم چک سلامت واقعی انجام بدم."
  exit 1
fi

ok "هدف مانیتورینگ: ${REMOTE_HOST}:${REMOTE_PORT}  |  سرویس: ${TUNNEL_SERVICE}"

# ----------------------------------------------------------
# بخش ۱: بهینه‌سازی کرنل
# ----------------------------------------------------------
echo ""
log "[1/5] اعمال تنظیمات شبکه کرنل ..."

SYSCTL_FILE="/etc/sysctl.d/99-tunnel-optimizer.conf"

# بررسی این‌که ماژول BBR در دسترسه یا نه (بعضی کرنل‌های مینیمال ندارنش)
modprobe tcp_bbr 2>/dev/null || true
if [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ] && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  CC_ALGO="bbr"
  QDISC="fq"
  ok "BBR در دسترسه، ازش استفاده می‌کنیم."
else
  CC_ALGO="cubic"
  QDISC="fq_codel"
  warn "BBR در دسترس نیست، روی cubic + fq_codel می‌مونیم."
fi

cat > "$SYSCTL_FILE" << EOF
# --- TCP Keepalive: کانکشن رو زنده نگه می‌داره حتی موقع بی‌کاری ---
net.ipv4.tcp_keepalive_time = 20
net.ipv4.tcp_keepalive_intvl = 8
net.ipv4.tcp_keepalive_probes = 5

# --- جلوگیری از افت throughput بعد از idle (خیلی از قطعی‌های تانل از همینه) ---
net.ipv4.tcp_slow_start_after_idle = 0

# --- کاهش زمان اتصالات نیمه‌بسته ---
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1

# --- بافر شبکه بزرگ‌تر برای ترافیک VPN ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# --- کنترل ازدحام و صف‌بندی مدرن ---
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC_ALGO}

# --- ریکاوری سریع‌تر در صورت افت لینک، به جای هنگ‌کردن طولانی ---
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 6

# --- Path MTU Discovery فعال، برای جلوگیری از drop شدن پکت به خاطر fragmentation ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# --- فایل‌ها و پورت‌های بیشتر برای اتصالات همزمان ---
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535

# --- IPv6 keepalive هم اگه تانل روی v6 باشه ---
net.ipv6.conf.all.disable_ipv6 = 0
EOF

sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "بعضی مقادیر شاید نیاز به ماژول اضافه داشته باشن، مشکلی نیست."

# nf_conntrack فقط اگه ماژولش لود شده باشه تنظیم کن (وگرنه sysctl ارور میده)
if lsmod | grep -q nf_conntrack || modprobe nf_conntrack 2>/dev/null; then
  cat >> "$SYSCTL_FILE" << 'EOF'
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  ok "تنظیمات conntrack هم اضافه شد."
fi

ok "تنظیمات کرنل اعمال شد (congestion control: ${CC_ALGO})."

# ----------------------------------------------------------
# بخش ۲: پیدا کردن MTU واقعی با تست path-MTU (نه حدس)
# ----------------------------------------------------------
echo ""
log "[2/5] تست واقعی MTU مسیر به سمت ${REMOTE_HOST} ..."

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
    warn "تست MTU نتیجه غیرمنطقی داد، مقدار پیش‌فرض امن 1420 استفاده میشه."
  fi
  ip link set dev "$IFACE" mtu "$DETECTED_MTU" 2>/dev/null && \
    ok "MTU واقعی مسیر: ${DETECTED_MTU} — روی $IFACE اعمال شد." || \
    warn "نتونستم MTU رو ست کنم، دستی بزن: ip link set dev $IFACE mtu $DETECTED_MTU"
else
  warn "اینترفیس شبکه پیدا نشد، این مرحله رد شد."
fi

# ----------------------------------------------------------
# بخش ۳: واچ‌داگ هوشمند با چک TCP واقعی + backoff نمایی
# ----------------------------------------------------------
echo ""
log "[3/5] نصب واچ‌داگ هوشمند ..."

WATCHDOG_SCRIPT="/usr/local/bin/tunnel-watchdog.sh"
cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
# واچ‌داگ تانل: چک سلامت واقعی روی پورت TCP (نه فقط ping)
# با backoff نمایی جلوی restart storm رو می‌گیره

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
    # افزایش نمایی backoff تا سقف مشخص، جلوی loop دیوونه‌وار رو می‌گیره
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

# لاگ روتیشن، تا journal یا syslog با لاگ‌های ping/health پر نشه
cat > /etc/logrotate.d/tunnel-watchdog << 'EOF'
/var/log/syslog {
  weekly
  rotate 4
  compress
  missingok
  notifempty
}
EOF

ok "واچ‌داگ نصب شد."

# ----------------------------------------------------------
# بخش ۴: Restart=always روی خود سرویس تانل (سطح systemd)
# ----------------------------------------------------------
echo ""
log "[4/5] فعال‌سازی ری‌استارت خودکار در سطح systemd برای ${TUNNEL_SERVICE} ..."

OVERRIDE_DIR="/etc/systemd/system/${TUNNEL_SERVICE}.service.d"
mkdir -p "$OVERRIDE_DIR"
cat > "${OVERRIDE_DIR}/override.conf" << 'EOF'
[Service]
Restart=always
RestartSec=3
StartLimitIntervalSec=0
# باز کردن سقف فایل‌های باز برای اتصالات زیاد
LimitNOFILE=1048576
EOF

ok "override.conf برای ${TUNNEL_SERVICE} ساخته شد."

# ----------------------------------------------------------
# بخش ۵: فعال‌سازی نهایی
# ----------------------------------------------------------
echo ""
log "[5/5] فعال‌سازی سرویس‌ها ..."

systemctl daemon-reload
systemctl enable --now tunnel-watchdog.service
systemctl restart "$TUNNEL_SERVICE"

echo ""
echo "=============================================="
ok "بهینه‌سازی کامل شد"
echo "=============================================="
echo ""
echo "دستورات مفید برای بررسی:"
echo "  journalctl -u tunnel-watchdog -f       # لاگ زنده واچ‌داگ"
echo "  systemctl status ${TUNNEL_SERVICE}     # وضعیت خود تانل"
echo "  sysctl net.ipv4.tcp_congestion_control # چک الگوریتم فعال"
echo ""
echo "برای برداشتن کامل تغییرات:"
echo "  systemctl disable --now tunnel-watchdog"
echo "  rm ${SYSCTL_FILE} ${WATCHDOG_SCRIPT} ${OVERRIDE_DIR}/override.conf"
echo "  systemctl daemon-reload && sysctl --system"
