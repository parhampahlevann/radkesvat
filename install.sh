#!/bin/bash

# ==========================================
# Cloudflare Ultra Fast IP Scanner (Ubuntu)
# Single-file installer + runner
# ==========================================

set -e

OUTPUT="cloudflare_alive_ips.txt"
MAX_PING=150
PARALLEL_JOBS=500

CLOUDFLARE_RANGES=(
"103.21.244.0/22"
"103.22.200.0/22"
"103.31.4.0/22"
"104.16.0.0/13"
"104.24.0.0/14"
"108.162.192.0/18"
"131.0.72.0/22"
"141.101.64.0/18"
"162.158.0.0/15"
"172.64.0.0/13"
"173.245.48.0/20"
"188.114.96.0/20"
"190.93.240.0/20"
"197.234.240.0/22"
"198.41.128.0/17"
)

clear
echo "=========================================="
echo " Cloudflare Ultra Fast IP Scanner (50x)"
echo "=========================================="
echo

# -------- Install dependencies ----------
echo "[*] Installing required packages..."
sudo apt update -y
sudo apt install -y fping netcat-openbsd ipcalc parallel

# Increase file descriptor limit
ulimit -n 100000 || true

echo "[✓] Dependencies installed"
echo

# -------- Generate IP list ----------
generate_ips() {
  for cidr in "${CLOUDFLARE_RANGES[@]}"; do
    ipcalc "$cidr" | awk '
      /HostMin/ {min=$2}
      /HostMax/ {max=$2}
      END {
        split(min,a,".")
        split(max,b,".")
        for (i=a[4]; i<=b[4]; i++)
          print a[1]"."a[2]"."a[3]"."i
      }'
  done
}

# -------- Scan ----------
echo "[*] Starting Cloudflare scan"
echo "[*] Parallel jobs : $PARALLEL_JOBS"
echo "[*] Max ping      : ${MAX_PING} ms"
echo "[*] Output file   : $OUTPUT"
echo

> "$OUTPUT"

export OUTPUT MAX_PING

generate_ips | \
fping -a -q -c1 -t300 2>/dev/null | \
parallel -j "$PARALLEL_JOBS" '
  ip={}
  
  # TCP 443 check
  timeout 1 nc -z "$ip" 443 >/dev/null 2>&1 || exit
  
  # Ping latency check
  p=$(ping -c1 -W1 "$ip" 2>/dev/null | grep time= | awk -F"time=" "{print \$2}" | cut -d" " -f1)
  [ -z "$p" ] && exit
  
  pi=${p%.*}
  if [ "$pi" -le "'"$MAX_PING"'" ]; then
    echo "$ip ping=${p}ms" >> "'"$OUTPUT"'"
    echo "[OK] $ip  ${p}ms"
  fi
'

echo
echo "=========================================="
echo "[✓] Scan completed successfully"
echo "[✓] Healthy Cloudflare IPs saved in:"
echo "    $OUTPUT"
echo "=========================================="
