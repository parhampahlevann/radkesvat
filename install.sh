#!/bin/bash

# ==================================================
# Cloudflare LIVE IP Scanner with Menu
# TCP Latency Based (Real ping replacement)
# ==================================================

set -e

# Configuration
PARALLEL_JOBS=600
MAX_LATENCY=0.15   # seconds (0.15s ≈ 150ms)
TIMEOUT=2          # connection timeout in seconds
OUTPUT_FILE="cloudflare_live_ips.txt"

# Cloudflare IP Ranges (Complete List)
CLOUDFLARE_RANGES=(
    # IPv4 Ranges
    "104.16.0.0/12"
    "172.64.0.0/13"
    "131.0.72.0/22"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "190.93.240.0/20"
    "188.114.96.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    "162.158.0.0/15"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    
    # Additional Cloudflare ranges
    "104.20.0.0/14"
    "104.24.0.0/14"
    "104.28.0.0/13"
    "104.30.0.0/15"
    "104.31.0.0/16"
    "108.162.192.0/18"
    "141.101.64.0/18"
    "162.158.0.0/15"
    "172.64.0.0/13"
    "173.245.48.0/20"
    "188.114.96.0/20"
    "190.93.240.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    
    # Cloudflare Warp / 1.1.1.1 ranges
    "162.159.0.0/16"
    "162.159.36.0/22"
    "162.159.40.0/22"
    "162.159.44.0/22"
    "162.159.48.0/22"
    
    # Cloudflare Gateway ranges
    "165.225.0.0/17"
    "165.225.128.0/17"
    "165.225.206.0/23"
    "165.225.208.0/20"
    
    # IPv6 Ranges (optional - remove if you only want IPv4)
    "2400:cb00::/32"
    "2405:8100::/32"
    "2405:b500::/32"
    "2606:4700::/32"
    "2803:f800::/32"
    "2c0f:f248::/32"
    "2a06:98c0::/29"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to display menu
show_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    ${GREEN}☁️  Cloudflare LIVE IP Scanner${NC}         ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${YELLOW}▸ ${GREEN}[1]${NC} Scan ALL Cloudflare IPs"
    echo -e "${YELLOW}▸ ${GREEN}[2]${NC} Scan Cloudflare Level 3 IPs"
    echo -e "${YELLOW}▸ ${GREEN}[3]${NC} Scan Custom IP Range"
    echo -e "${YELLOW}▸ ${GREEN}[4]${NC} Show previous scan results"
    echo -e "${YELLOW}▸ ${GREEN}[5]${NC} Test specific IP"
    echo -e "${YELLOW}▸ ${GREEN}[6]${NC} Change settings"
    echo -e "${YELLOW}▸ ${GREEN}[7]${NC} Install/Update dependencies"
    echo -e "${YELLOW}▸ ${GREEN}[8]${NC} Show statistics"
    echo -e "${YELLOW}▸ ${RED}[0]${NC} Exit"
    echo
    echo -e "${BLUE}══════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Current:${NC} Jobs: ${PARALLEL_JOBS}, Max Latency: ${MAX_LATENCY}s, Timeout: ${TIMEOUT}s"
    echo -e "${BLUE}══════════════════════════════════════════════${NC}"
}

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}[*] Installing required packages...${NC}"
    sudo apt update -y
    sudo apt install -y ipcalc parallel curl bc jq netcat-openbsd
    
    # Check if parallel is installed correctly
    if ! command -v parallel &> /dev/null; then
        echo -e "${RED}[✗] parallel not installed, trying alternative...${NC}"
        sudo apt install -y moreutils  # provides parallel
    fi
    
    # Increase file descriptor limit
    ulimit -n 200000 2>/dev/null || echo -e "${YELLOW}[!] Could not increase file limit${NC}"
    
    # Check if bc is available for calculations
    if ! command -v bc &> /dev/null; then
        echo -e "${RED}[✗] bc not installed, installing...${NC}"
        sudo apt install -y bc
    fi
    
    echo -e "${GREEN}[✓] Dependencies installed successfully${NC}"
    sleep 2
}

# Function to generate IPs from CIDR
generate_ips() {
    local cidr=$1
    
    # Check if it's IPv6
    if [[ "$cidr" == *":"* ]]; then
        echo -e "${YELLOW}[!] Skipping IPv6 range: $cidr${NC}" >&2
        return
    fi
    
    # Using ipcalc to get IP range
    local network_info=$(ipcalc -n "$cidr" 2>/dev/null || echo "")
    if [ -z "$network_info" ]; then
        echo -e "${RED}[✗] Invalid CIDR: $cidr${NC}" >&2
        return
    fi
    
    # Extract network and broadcast addresses
    local network_addr=$(echo "$network_info" | grep '^Address:' | awk '{print $2}')
    local broadcast=$(ipcalc -b "$cidr" 2>/dev/null | grep '^Broadcast:' | awk '{print $2}')
    
    if [ -z "$network_addr" ] || [ -z "$broadcast" ]; then
        # Alternative method using simple calculation
        IFS=/ read -r base_ip prefix <<< "$cidr"
        IFS=. read -r i1 i2 i3 i4 <<< "$base_ip"
        
        local network=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
        local mask=$((0xffffffff << (32 - prefix)))
        local network_num=$((network & mask))
        local broadcast_num=$((network_num | (~mask & 0xffffffff)))
        
        # Convert back to IP
        local start_ip=$(printf "%d.%d.%d.%d\n" \
            $(( (network_num >> 24) & 0xff )) \
            $(( (network_num >> 16) & 0xff )) \
            $(( (network_num >> 8) & 0xff )) \
            $(( network_num & 0xff )))
            
        local end_ip=$(printf "%d.%d.%d.%d\n" \
            $(( (broadcast_num >> 24) & 0xff )) \
            $(( (broadcast_num >> 16) & 0xff )) \
            $(( (broadcast_num >> 8) & 0xff )) \
            $(( broadcast_num & 0xff )))
        
        # Generate all IPs in range (excluding network and broadcast)
        IFS=. read -r a b c d <<< "$start_ip"
        IFS=. read -r e f g h <<< "$end_ip"
        
        # Skip network and broadcast addresses
        local start_host=$((d + 1))
        local end_host=$((h - 1))
        
        for i in $(seq $start_host $end_host); do
            echo "$a.$b.$c.$i"
        done
    else
        # Use ipcalc output
        IFS=. read -r a b c d <<< "$network_addr"
        IFS=. read -r e f g h <<< "$broadcast"
        
        # Skip network and broadcast addresses
        local start_host=$((d + 1))
        local end_host=$((h - 1))
        
        for i in $(seq $start_host $end_host); do
            echo "$a.$b.$c.$i"
        done
    fi
}

# Function to test single IP
test_single_ip() {
    echo -e "${YELLOW}[?] Enter IP address to test:${NC}"
    read -r test_ip
    
    # Validate IP format
    if [[ ! $test_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}[✗] Invalid IPv4 address format${NC}"
        return
    fi
    
    echo -e "${BLUE}[*] Testing IP: $test_ip${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────${NC}"
    
    # Test with curl (HTTPS)
    echo -e "${YELLOW}[1] HTTPS Test:${NC}"
    https_latency=$(timeout $TIMEOUT curl -o /dev/null -s \
        --connect-timeout $TIMEOUT \
        -w "DNS: %{time_namelookup}s | Connect: %{time_connect}s | SSL: %{time_appconnect}s | Total: %{time_total}s" \
        "https://$test_ip" 2>/dev/null || echo "HTTPS Connection failed")
    
    echo -e "   $https_latency"
    
    # Test with curl (HTTP)
    echo -e "${YELLOW}[2] HTTP Test:${NC}"
    http_latency=$(timeout $TIMEOUT curl -o /dev/null -s \
        --connect-timeout $TIMEOUT \
        -w "DNS: %{time_namelookup}s | Connect: %{time_connect}s | Total: %{time_total}s" \
        "http://$test_ip" 2>/dev/null || echo "HTTP Connection failed")
    
    echo -e "   $http_latency"
    
    # Simple port test
    echo -e "${YELLOW}[3] Port 80 Test:${NC}"
    if timeout $TIMEOUT bash -c "echo > /dev/tcp/$test_ip/80" 2>/dev/null; then
        echo -e "   ${GREEN}Port 80 is open${NC}"
    else
        echo -e "   ${RED}Port 80 is closed${NC}"
    fi
    
    echo -e "${CYAN}──────────────────────────────────────────────${NC}"
}

# Function to scan IPs
scan_ips() {
    local scan_type=$1
    local total_ips=0
    
    echo -e "${YELLOW}[*] Preparing IP list...${NC}"
    
    # Create temporary file for IPs
    local temp_ip_file=$(mktemp)
    
    case $scan_type in
        "all")
            for cidr in "${CLOUDFLARE_RANGES[@]}"; do
                generate_ips "$cidr" >> "$temp_ip_file"
            done
            ;;
        "level3")
            # Scan only main Level 3 ranges
            for cidr in "${CLOUDFLARE_RANGES[@]:0:15}"; do
                generate_ips "$cidr" >> "$temp_ip_file"
            done
            ;;
        "custom")
            echo -e "${YELLOW}[?] Enter CIDR range (e.g., 104.16.0.0/13):${NC}"
            read -r custom_cidr
            generate_ips "$custom_cidr" >> "$temp_ip_file"
            ;;
    esac
    
    total_ips=$(wc -l < "$temp_ip_file" 2>/dev/null || echo "0")
    
    if [ "$total_ips" -eq "0" ] 2>/dev/null || [ -z "$total_ips" ]; then
        echo -e "${RED}[✗] No IPs generated. Check your CIDR ranges.${NC}"
        rm -f "$temp_ip_file"
        return
    fi
    
    echo -e "${GREEN}[✓] Generated $total_ips IPs${NC}"
    echo -e "${YELLOW}[*] Starting scan with $PARALLEL_JOBS parallel jobs...${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}IP ADDRESS            LATENCY     STATUS${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────${NC}"
    
    # Clear output file
    > "$OUTPUT_FILE"
    
    # Scan IPs
    local found_ips=0
    
    cat "$temp_ip_file" | parallel --progress --bar --jobs $PARALLEL_JOBS '
        ip={}
        timeout='"$TIMEOUT"' curl -o /dev/null -s \
            --connect-timeout '"$TIMEOUT"' \
            -w "%{http_code} %{time_connect}" \
            "http://$ip" 2>/dev/null | {
            read -r http_code latency
            
            if [ -n "$latency" ] && [ "$latency" != "0" ]; then
                latency_ms=$(echo "$latency * 1000" | bc -l 2>/dev/null | awk "{printf \"%.0f\", \$1}")
                
                if [ $(echo "$latency <= '"$MAX_LATENCY"'" | bc -l 2>/dev/null) -eq 1 ]; then
                    if [ "$http_code" = "000" ] || [ -z "$http_code" ]; then
                        status="NO RESPONSE"
                    else
                        status="HTTP $http_code"
                    fi
                    
                    printf "%-20s %-11s %s\n" "$ip" "${latency_ms}ms" "$status"
                    echo "$ip $latency_ms" >> "'"$OUTPUT_FILE"'.tmp"
                fi
            fi
        }
    ' 2>/dev/null
    
    # Sort results by latency
    if [ -f "${OUTPUT_FILE}.tmp" ]; then
        sort -n -k2 "${OUTPUT_FILE}.tmp" | awk '{printf "%-20s %-11s %s\n", $1, $2"ms", "LIVE"}' > "$OUTPUT_FILE"
        found_ips=$(wc -l < "$OUTPUT_FILE")
        rm -f "${OUTPUT_FILE}.tmp"
    fi
    
    # Cleanup
    rm -f "$temp_ip_file"
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[✓] Scan completed!${NC}"
    echo -e "${YELLOW}[*] Total IPs scanned: $total_ips${NC}"
    echo -e "${GREEN}[✓] Live IPs found: $found_ips${NC}"
    echo -e "${YELLOW}[*] Results saved to: $OUTPUT_FILE${NC}"
}

# Function to show previous results
show_results() {
    if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
        local total_ips=$(wc -l < "$OUTPUT_FILE")
        echo -e "${GREEN}[✓] Previous scan results ($total_ips IPs):${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════${NC}"
        head -20 "$OUTPUT_FILE"
        
        if [ "$total_ips" -gt 20 ]; then
            echo -e "${YELLOW}[...] and $((total_ips - 20)) more IPs${NC}"
        fi
        
        echo -e "${CYAN}══════════════════════════════════════════════${NC}"
        
        # Show best 5 IPs
        echo -e "${YELLOW}[🏆] Top 5 fastest IPs:${NC}"
        head -5 "$OUTPUT_FILE" | awk '{print "   " $0}'
        
        # Show statistics
        if command -v awk &> /dev/null; then
            local avg_latency=$(awk '{sum+=$2; count++} END{if(count>0) print sum/count}' "$OUTPUT_FILE" 2>/dev/null)
            if [ -n "$avg_latency" ]; then
                echo -e "${YELLOW}[📊] Average latency: ${avg_latency%.*}ms${NC}"
            fi
        fi
    else
        echo -e "${RED}[✗] No previous scan results found${NC}"
    fi
}

# Function to show statistics
show_statistics() {
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}📈 SCANNER STATISTICS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    # Count total IPs in all ranges
    local total_possible_ips=0
    for cidr in "${CLOUDFLARE_RANGES[@]}"; do
        if [[ ! "$cidr" == *":"* ]]; then  # Skip IPv6
            local prefix=${cidr#*/}
            local ips_in_range=$((2**(32-prefix) - 2))
            total_possible_ips=$((total_possible_ips + ips_in_range))
        fi
    done
    
    echo -e "${YELLOW}Total Cloudflare Ranges:${NC} ${#CLOUDFLARE_RANGES[@]}"
    echo -e "${YELLOW}Total Possible IPv4 IPs:${NC} $(printf "%'d" $total_possible_ips)"
    echo -e "${YELLOW}Current Settings:${NC}"
    echo -e "  • Parallel Jobs: $PARALLEL_JOBS"
    echo -e "  • Max Latency: ${MAX_LATENCY}s ($(echo "$MAX_LATENCY * 1000" | bc | awk '{printf "%.0f", $1}')ms)"
    echo -e "  • Timeout: ${TIMEOUT}s"
    
    if [ -f "$OUTPUT_FILE" ]; then
        local found_ips=$(wc -l < "$OUTPUT_FILE" 2>/dev/null || echo "0")
        echo -e "${YELLOW}Last Scan Results:${NC}"
        echo -e "  • Live IPs Found: $found_ips"
        
        if [ "$found_ips" -gt 0 ]; then
            local best_ip=$(head -1 "$OUTPUT_FILE" | awk '{print $1}')
            local best_latency=$(head -1 "$OUTPUT_FILE" | awk '{print $2}')
            echo -e "  • Best IP: $best_ip ($best_latency)"
        fi
    fi
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# Function to change settings
change_settings() {
    while true; do
        clear
        echo -e "${CYAN}══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}⚙️  CHANGE SETTINGS${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════${NC}"
        echo
        echo -e "${GREEN}[1]${NC} Parallel Jobs: $PARALLEL_JOBS"
        echo -e "${GREEN}[2]${NC} Max Latency: ${MAX_LATENCY}s ($(echo "$MAX_LATENCY * 1000" | bc | awk '{printf "%.0f", $1}')ms)"
        echo -e "${GREEN}[3]${NC} Timeout: ${TIMEOUT}s"
        echo -e "${GREEN}[4]${NC} Output File: $OUTPUT_FILE"
        echo -e "${RED}[0]${NC} Back to main menu"
        echo
        echo -e "${CYAN}══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}[?] Select option to change:${NC}"
        read -r setting_choice
        
        case $setting_choice in
            1)
                echo -e "${YELLOW}[?] Enter new value for parallel jobs (10-1000):${NC}"
                read -r new_jobs
                if [[ "$new_jobs" =~ ^[0-9]+$ ]] && [ "$new_jobs" -ge 10 ] && [ "$new_jobs" -le 1000 ]; then
                    PARALLEL_JOBS=$new_jobs
                    echo -e "${GREEN}[✓] Parallel jobs set to: $PARALLEL_JOBS${NC}"
                else
                    echo -e "${RED}[✗] Invalid value. Must be between 10 and 1000${NC}"
                fi
                ;;
            2)
                echo -e "${YELLOW}[?] Enter new max latency in seconds (0.01-1.0):${NC}"
                read -r new_latency
                if [[ "$new_latency" =~ ^[0-9]*\.?[0-9]+$ ]] && \
                   [ $(echo "$new_latency >= 0.01" | bc -l 2>/dev/null) -eq 1 ] && \
                   [ $(echo "$new_latency <= 1.0" | bc -l 2>/dev/null) -eq 1 ]; then
                    MAX_LATENCY=$new_latency
                    echo -e "${GREEN}[✓] Max latency set to: ${MAX_LATENCY}s${NC}"
                else
                    echo -e "${RED}[✗] Invalid value. Must be between 0.01 and 1.0 seconds${NC}"
                fi
                ;;
            3)
                echo -e "${YELLOW}[?] Enter new timeout in seconds (1-10):${NC}"
                read -r new_timeout
                if [[ "$new_timeout" =~ ^[0-9]+$ ]] && [ "$new_timeout" -ge 1 ] && [ "$new_timeout" -le 10 ]; then
                    TIMEOUT=$new_timeout
                    echo -e "${GREEN}[✓] Timeout set to: ${TIMEOUT}s${NC}"
                else
                    echo -e "${RED}[✗] Invalid value. Must be between 1 and 10 seconds${NC}"
                fi
                ;;
            4)
                echo -e "${YELLOW}[?] Enter new output filename:${NC}"
                read -r new_output
                if [ -n "$new_output" ]; then
                    OUTPUT_FILE="$new_output"
                    echo -e "${GREEN}[✓] Output file set to: $OUTPUT_FILE${NC}"
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}[✗] Invalid option${NC}"
                ;;
        esac
        
        sleep 1
    done
}

# Main program
main() {
    # Clear screen
    clear
    
    # Show welcome message
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║   ☁️  Cloudflare IP Scanner v2.0           ║"
    echo "║   Author: Cloudflare Scanner Team          ║"
    echo "║   Date: $(date +'%Y-%m-%d %H:%M:%S')                 ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check dependencies
    if ! command -v curl &> /dev/null || ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}[!] Some dependencies are missing${NC}"
        install_dependencies
    fi
    
    # Check if running as root (fixed error)
    if [ -n "$EUID" ] && [ "$EUID" -eq 0 ] 2>/dev/null; then 
        echo -e "${RED}[!] Warning: Running as root is not recommended${NC}"
        echo -e "${YELLOW}[*] Consider running as normal user${NC}"
        sleep 2
    fi
    
    # Main loop
    while true; do
        show_menu
        echo -e "${YELLOW}[?] Select option:${NC}"
        read -r choice
        
        case $choice in
            1)
                echo -e "${GREEN}[1] Scanning ALL Cloudflare IPs...${NC}"
                scan_ips "all"
                ;;
            2)
                echo -e "${GREEN}[2] Scanning Level 3 IPs...${NC}"
                scan_ips "level3"
                ;;
            3)
                echo -e "${GREEN}[3] Scanning custom range...${NC}"
                scan_ips "custom"
                ;;
            4)
                show_results
                ;;
            5)
                test_single_ip
                ;;
            6)
                change_settings
                ;;
            7)
                install_dependencies
                ;;
            8)
                show_statistics
                ;;
            0)
                echo -e "${GREEN}[✓] Thank you for using Cloudflare IP Scanner${NC}"
                echo -e "${CYAN}[*] Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[✗] Invalid option. Please try again.${NC}"
                ;;
        esac
        
        echo
        echo -e "${YELLOW}[*] Press Enter to continue...${NC}"
        read -r
    done
}

# Trap Ctrl+C
trap 'echo -e "\n${RED}[!] Interrupted. Exiting...${NC}"; exit 1' INT

# Run main function
main "$@"
