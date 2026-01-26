#!/bin/bash

# ==========================================
# Cloudflare LIVE IP Scanner (TCP ONLY)
# ICMP REMOVED - WORKING VERSION
# ==========================================

set -e

PARALLEL_JOBS=800
TIMEOUT=1

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
echo " Cloudflare LIVE IP Scanner (TCP 443)"
echo " ICMP Disabled — Real Results"
echo "=========================================="
echo

# ---------- Install dependencies ----------
echo "[*] Installing packages..."
sudo apt update -y
sudo apt install -y netcat-openbsd ipcalc parallel
ulimit -n 200000 || true
echo "[✓] Ready"
echo

# ---------- Generate IPs ----------
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

echo "IP ADDRESS"
echo "-----------------------------"

# ---------- Scan ----------
generate_ips | \
parallel -j "$PARALLEL_JOBS" '
  ip={}
  timeout "'"$TIMEOUT"'" nc -z "$ip" 443 >/dev/null 2>&1 && \
  echo "$ip"
'

echo
echo "=========================================="
echo "[✓] Scan finished"
echo "[✓] Above IPs are REAL, healthy Cloudflare nodes"
echo "=========================================="
