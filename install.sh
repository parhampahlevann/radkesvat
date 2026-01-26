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

# Cloudflare IP Ranges
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display menu
show_menu() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${GREEN}    Cloudflare LIVE IP Scanner${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo
    echo -e "${YELLOW}[1]${NC} Scan Cloudflare IPs (Level 3)"
    echo -e "${YELLOW}[2]${NC} Scan Cloudflare IPs (Custom Range)"
    echo -e "${YELLOW}[3]${NC} Show previous scan results"
    echo -e "${YELLOW}[4]${NC} Test specific IP"
    echo -e "${YELLOW}[5]${NC} Change settings"
    echo -e "${YELLOW}[6]${NC} Install dependencies"
    echo -e "${YELLOW}[0]${NC} Exit"
    echo
    echo -e "${BLUE}==============================================${NC}"
}

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}[*] Installing required packages...${NC}"
    sudo apt update -y
    sudo apt install -y ipcalc parallel curl bc
    # Increase file descriptor limit
    ulimit -n 200000 2>/dev/null || true
    echo -e "${GREEN}[✓] Dependencies installed successfully${NC}"
    sleep 2
}

# Function to generate IPs from CIDR
generate_ips() {
    local cidr=$1
    ipcalc -n "$cidr" 2>/dev/null | grep -E '^Address|^Network' | awk '{print $2}' | head -1 | while read network
    do
        ipcalc -b "$cidr" 2>/dev/null | grep -E '^HostMin|^HostMax' | awk '{print $2}' | {
            read min_ip
            read max_ip
            IFS=. read a b c d <<< "$min_ip"
            IFS=. read e f g h <<< "$max_ip"
            
            for i in $(seq $d $h); do
                echo "$a.$b.$c.$i"
            done
        }
    done
}

# Function to test single IP
test_single_ip() {
    echo -e "${YELLOW}Enter IP address to test:${NC}"
    read -r test_ip
    echo -e "${BLUE}Testing IP: $test_ip${NC}"
    
    # Validate IP format
    if ! [[ $test_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}[✗] Invalid IP address format${NC}"
        return
    fi
    
    # Test with curl
    latency=$(curl -o /dev/null -s \
        --connect-timeout $TIMEOUT \
        -w "%{time_connect}" \
        "https://$test_ip" 2>/dev/null || echo "failed")
    
    if [ "$latency" != "failed" ] && [ -n "$latency" ]; then
        latency_ms=$(echo "$latency * 1000" | bc -l 2>/dev/null | awk '{printf "%.0f", $1}')
        echo -e "${GREEN}[✓] IP: $test_ip - Latency: ${latency_ms}ms${NC}"
    else
        echo -e "${RED}[✗] IP: $test_ip - Connection failed${NC}"
    fi
}

# Function to scan IPs
scan_ips() {
    local range_type=$1
    
    echo -e "${YELLOW}[*] Starting scan...${NC}"
    echo -e "${BLUE}IP ADDRESS            TCP LATENCY${NC}"
    echo -e "${BLUE}----------------------------------------------${NC}"
    
    # Prepare IP list
    if [ "$range_type" == "level3" ]; then
        # Generate all Cloudflare IPs
        for cidr in "${CLOUDFLARE_RANGES[@]}"; do
            generate_ips "$cidr"
        done
    elif [ "$range_type" == "custom" ]; then
        echo -e "${YELLOW}Enter CIDR range (e.g., 104.16.0.0/13):${NC}"
        read -r custom_cidr
        generate_ips "$custom_cidr"
    fi | parallel -j $PARALLEL_JOBS --line-buffer '
        ip={}
        latency=$(curl -o /dev/null -s \
            --connect-timeout '"$TIMEOUT"' \
            -w "%{time_connect}" \
            "https://$ip" 2>/dev/null || echo "failed")
        
        if [ "$latency" != "failed" ] && [ -n "$latency" ]; then
            latency_ms=$(echo "$latency * 1000" | bc -l 2>/dev/null)
            if [ $(echo "$latency <= '"$MAX_LATENCY"'" | bc -l 2>/dev/null) -eq 1 ]; then
                printf "%-20s %.0f ms\n" "$ip" "$latency_ms"
            fi
        fi
    ' | tee "$OUTPUT_FILE"
    
    echo -e "${GREEN}[✓] Scan completed. Results saved to: $OUTPUT_FILE${NC}"
}

# Function to show previous results
show_results() {
    if [ -f "$OUTPUT_FILE" ]; then
        echo -e "${YELLOW}Previous scan results:${NC}"
        echo -e "${BLUE}==============================================${NC}"
        cat "$OUTPUT_FILE"
        echo -e "${BLUE}==============================================${NC}"
        echo -e "${GREEN}Total IPs found: $(wc -l < "$OUTPUT_FILE")${NC}"
    else
        echo -e "${RED}[✗] No previous scan results found${NC}"
    fi
}

# Function to change settings
change_settings() {
    echo -e "${YELLOW}Current settings:${NC}"
    echo "1. Parallel jobs: $PARALLEL_JOBS"
    echo "2. Max latency: $MAX_LATENCY seconds ($(echo "$MAX_LATENCY * 1000" | bc -l | awk '{printf "%.0f", $1}') ms)"
    echo "3. Timeout: $TIMEOUT seconds"
    echo
    echo -e "${YELLOW}Enter setting number to change (1-3):${NC}"
    read -r setting_choice
    
    case $setting_choice in
        1)
            echo -e "${YELLOW}Enter new value for parallel jobs:${NC}"
            read -r PARALLEL_JOBS
            ;;
        2)
            echo -e "${YELLOW}Enter new max latency in seconds (e.g., 0.1):${NC}"
            read -r MAX_LATENCY
            ;;
        3)
            echo -e "${YELLOW}Enter new timeout in seconds:${NC}"
            read -r TIMEOUT
            ;;
        *)
            echo -e "${RED}[✗] Invalid choice${NC}"
            ;;
    esac
}

# Main program
main() {
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then 
        echo -e "${RED}[!] Warning: Running as root is not recommended${NC}"
        sleep 2
    fi
    
    # Install dependencies on first run
    if ! command -v parallel &> /dev/null || ! command -v ipcalc &> /dev/null; then
        install_dependencies
    fi
    
    while true; do
        show_menu
        echo -e "${YELLOW}Select option:${NC}"
        read -r choice
        
        case $choice in
            1)
                scan_ips "level3"
                ;;
            2)
                scan_ips "custom"
                ;;
            3)
                show_results
                ;;
            4)
                test_single_ip
                ;;
            5)
                change_settings
                ;;
            6)
                install_dependencies
                ;;
            0)
                echo -e "${GREEN}[✓] Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[✗] Invalid option${NC}"
                ;;
        esac
        
        echo
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r
    done
}

# Run main function
main "$@"
