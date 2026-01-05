#!/bin/bash

# Global Variables
TUNNEL_DIR="/etc/rtt"
CONFIG_DIR="$TUNNEL_DIR/config"
LOG_DIR="$TUNNEL_DIR/logs"
BACKUP_DIR="$TUNNEL_DIR/backup"
SCRIPT_VERSION="3.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

# Banner
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║    Advanced Reverse TLS Tunnel - Professional Edition        ║"
    echo "║     Version: $SCRIPT_VERSION                                  ║"
    echo "║     By: Peyman - Github.com/Ptechgithub                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Initialize directories
init_dirs() {
    mkdir -p $TUNNEL_DIR $CONFIG_DIR $LOG_DIR $BACKUP_DIR
    chmod 700 $TUNNEL_DIR
}

# Check root access
root_access() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script requires root access. Please run as root.${NC}"
        exit 1
    fi
}

# Detect distribution
detect_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu|debian)
                package_manager="apt-get"
                ;;
            centos|rhel|fedora|almalinux|rocky)
                if [ $ID = "centos" ] || [ $ID = "rhel" ]; then
                    package_manager="yum"
                elif [ $ID = "fedora" ]; then
                    package_manager="dnf"
                else
                    package_manager="yum"
                fi
                ;;
            *)
                echo -e "${RED}Unsupported distribution: $ID${NC}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}Cannot detect distribution!${NC}"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"
    
    local deps=("wget" "curl" "unzip" "lsof" "iptables" "net-tools")
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            echo -e "${YELLOW}Installing $dep...${NC}"
            $package_manager install -y $dep >/dev/null 2>&1 || {
                echo -e "${YELLOW}Failed to install $dep, continuing...${NC}"
            }
        fi
    done
}

# Get latest RTT version
get_latest_version() {
    local version=$(curl -s --connect-timeout 5 https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest | grep -oP '"tag_name": "\K[^"]+' | sed 's/V//')
    if [ -z "$version" ]; then
        version="7.0.1"  # Fallback version
    fi
    echo $version
}

# Install RTT with verification
install_rtt() {
    local version=${1:-$(get_latest_version)}
    
    echo -e "${YELLOW}Installing RTT version $version...${NC}"
    
    # Kill any existing RTT processes
    pkill -9 -f "rtt" 2>/dev/null || true
    pkill -9 -f "RTT" 2>/dev/null || true
    
    # Detect architecture
    arch=$(uname -m)
    case $arch in
        x86_64) rtt_arch="amd64" ;;
        aarch64|arm64) rtt_arch="arm64" ;;
        armv7l) rtt_arch="arm" ;;
        *) rtt_arch="amd64" ;;
    esac
    
    # Download RTT
    echo -e "${YELLOW}Downloading RTT...${NC}"
    wget -q --timeout=30 "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_${rtt_arch}.zip" -O /tmp/rtt.zip
    
    if [ ! -s /tmp/rtt.zip ]; then
        echo -e "${RED}Download failed! Trying alternative URL...${NC}"
        wget -q "https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/v${version}_linux_${rtt_arch}.zip" -O /tmp/rtt.zip
    fi
    
    if [ ! -s /tmp/rtt.zip ]; then
        echo -e "${RED}Failed to download RTT!${NC}"
        return 1
    fi
    
    # Extract
    echo -e "${YELLOW}Extracting...${NC}"
    unzip -o /tmp/rtt.zip -d /tmp/rtt_extract/ >/dev/null 2>&1
    
    # Find binary
    local binary_path=$(find /tmp/rtt_extract/ -type f -name "RTT" -o -name "rtt" | head -1)
    
    if [ -z "$binary_path" ]; then
        echo -e "${RED}RTT binary not found!${NC}"
        return 1
    fi
    
    # Install
    cp "$binary_path" /usr/local/bin/rtt
    chmod +x /usr/local/bin/rtt
    
    # Create symlink
    ln -sf /usr/local/bin/rtt /usr/bin/rtt 2>/dev/null
    
    # Verify
    if /usr/local/bin/rtt --version >/dev/null 2>&1; then
        echo -e "${GREEN}RTT installed successfully!${NC}"
        /usr/local/bin/rtt --version
    else
        echo -e "${RED}RTT installation failed!${NC}"
        return 1
    fi
    
    # Cleanup
    rm -rf /tmp/rtt.zip /tmp/rtt_extract/
    
    return 0
}

# Test RTT command
test_rtt_command() {
    local args=$1
    local service_name=$2
    
    echo -e "${YELLOW}Testing RTT command...${NC}"
    
    # Run RTT in test mode (timeout after 5 seconds)
    timeout 5 /usr/local/bin/rtt $args --log-level:debug > $LOG_DIR/test_${service_name}.log 2>&1 &
    local pid=$!
    
    sleep 3
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ RTT command test passed${NC}"
        kill $pid 2>/dev/null
        return 0
    else
        echo -e "${RED}✗ RTT command test failed!${NC}"
        echo -e "${YELLOW}Check log: $LOG_DIR/test_${service_name}.log${NC}"
        cat $LOG_DIR/test_${service_name}.log
        return 1
    fi
}

# Generate service file
generate_service() {
    local service_name=$1
    local args=$2
    local type=$3
    
    # Stop if exists
    systemctl stop $service_name 2>/dev/null
    systemctl disable $service_name 2>/dev/null
    
    cat > /etc/systemd/system/$service_name.service << EOF
[Unit]
Description=RTT Tunnel ($type)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/rtt $args
Restart=always
RestartSec=3
StandardOutput=append:$LOG_DIR/${service_name}.log
StandardError=append:$LOG_DIR/${service_name}.error.log
LimitNOFILE=102400

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 /etc/systemd/system/$service_name.service
    echo -e "${GREEN}Service file created${NC}"
}

# Install multiport tunnel (FIXED VERSION)
install_multiport() {
    print_banner
    echo -e "${GREEN}=== Install Multiport Tunnel ===${NC}"
    
    # Ensure RTT is installed
    if ! command -v rtt &> /dev/null; then
        echo -e "${RED}RTT not found! Installing...${NC}"
        install_rtt
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to install RTT!${NC}"
            return 1
        fi
    fi
    
    # Server type
    echo -e "${CYAN}Select server type:${NC}"
    echo "1) Iran (internal server)"
    echo "2) Kharej (external server)"
    read -p "Choice [1/2]: " server_type
    
    # SNI
    read -p "Enter SNI (default: google.com): " sni
    sni=${sni:-google.com}
    
    # Password
    read -p "Enter password: " password
    if [ -z "$password" ]; then
        echo -e "${RED}Password is required!${NC}"
        return 1
    fi
    
    # Build command based on server type
    if [ "$server_type" = "1" ]; then
        # Iran server
        echo -e "${YELLOW}Configuring Iran server...${NC}"
        
        read -p "Local port range (default: 20000-20010): " port_range
        port_range=${port_range:-20000-20010}
        
        # Check ports
        echo -e "${YELLOW}Checking ports...${NC}"
        local start_port=$(echo $port_range | cut -d'-' -f1)
        local end_port=$(echo $port_range | cut -d'-' -f2)
        
        for port in $(seq $start_port $end_port); do
            if lsof -i :$port >/dev/null 2>&1; then
                echo -e "${RED}Port $port is already in use!${NC}"
                return 1
            fi
        done
        
        # Build command
        cmd="--iran --lport:$port_range --password:$password --sni:$sni --terminate:24 --log-level:info"
        
    elif [ "$server_type" = "2" ]; then
        # Kharej server
        echo -e "${YELLOW}Configuring Kharej server...${NC}"
        
        read -p "Iran server IP: " iran_ip
        if [ -z "$iran_ip" ]; then
            echo -e "${RED}Iran IP is required!${NC}"
            return 1
        fi
        
        read -p "Local port range (default: 20000-20010): " local_ports
        local_ports=${local_ports:-20000-20010}
        
        # Check ports
        echo -e "${YELLOW}Checking ports...${NC}"
        local start_port=$(echo $local_ports | cut -d'-' -f1)
        local end_port=$(echo $local_ports | cut -d'-' -f2)
        
        for port in $(seq $start_port $end_port); do
            if lsof -i :$port >/dev/null 2>&1; then
                echo -e "${RED}Port $port is already in use!${NC}"
                return 1
            fi
        done
        
        # Build command
        cmd="--kharej --iran-ip:$iran_ip --iran-port:443 --toip:127.0.0.1 --toport:$local_ports --password:$password --sni:$sni --terminate:24 --log-level:info"
        
    else
        echo -e "${RED}Invalid choice!${NC}"
        return 1
    fi
    
    # Test command
    echo -e "${YELLOW}Command: rtt $cmd${NC}"
    
    if ! test_rtt_command "$cmd" "tunnel"; then
        echo -e "${RED}RTT command test failed! Please check parameters.${NC}"
        return 1
    fi
    
    # Generate service
    generate_service "tunnel" "$cmd" "Multiport"
    
    # Enable and start
    systemctl daemon-reload
    systemctl enable tunnel.service
    
    echo -e "${YELLOW}Starting service...${NC}"
    systemctl start tunnel.service
    
    # Check status
    sleep 5
    
    if systemctl is-active --quiet tunnel.service; then
        echo -e "${GREEN}✓ Tunnel service started successfully!${NC}"
        
        # Show logs
        echo -e "${CYAN}=== Service Status ===${NC}"
        systemctl status tunnel.service --no-pager | head -20
        
        echo -e "${CYAN}=== Recent Logs ===${NC}"
        tail -10 $LOG_DIR/tunnel.log 2>/dev/null || echo "No logs yet"
        
    else
        echo -e "${RED}✗ Failed to start tunnel service!${NC}"
        echo -e "${YELLOW}Checking error logs...${NC}"
        journalctl -u tunnel.service -n 20 --no-pager
        tail -20 $LOG_DIR/tunnel.error.log 2>/dev/null || echo "No error log"
        return 1
    fi
    
    return 0
}

# Simple tunnel installation (MINIMAL VERSION)
install_simple_tunnel() {
    echo -e "${GREEN}=== Simple Tunnel Installation ===${NC}"
    
    # Install RTT if needed
    if ! command -v rtt &> /dev/null; then
        install_rtt
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Server type
    echo -e "${CYAN}Select server type:${NC}"
    echo "1) Iran (internal)"
    echo "2) Kharej (external)"
    read -p "Choice: " server_type
    
    if [ "$server_type" = "1" ]; then
        # Iran
        read -p "Password: " password
        read -p "SNI (default: google.com): " sni
        sni=${sni:-google.com}
        
        cmd="--iran --lport:443 --password:$password --sni:$sni --log-level:debug"
        
    elif [ "$server_type" = "2" ]; then
        # Kharej
        read -p "Iran IP: " iran_ip
        read -p "Password: " password
        read -p "SNI (default: google.com): " sni
        sni=${sni:-google.com}
        
        cmd="--kharej --iran-ip:$iran_ip --iran-port:443 --toip:127.0.0.1 --toport:8080 --password:$password --sni:$sni --log-level:debug"
    else
        echo -e "${RED}Invalid choice!${NC}"
        return 1
    fi
    
    # Test command
    echo -e "${YELLOW}Testing: rtt $cmd${NC}"
    timeout 10 /usr/local/bin/rtt $cmd &
    local pid=$!
    sleep 5
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Test successful! Killing test process...${NC}"
        kill $pid 2>/dev/null
        
        # Install service
        generate_service "simple_tunnel" "$cmd" "Simple"
        
        systemctl daemon-reload
        systemctl enable simple_tunnel.service
        systemctl start simple_tunnel.service
        
        sleep 3
        
        if systemctl is-active --quiet simple_tunnel.service; then
            echo -e "${GREEN}✓ Simple tunnel installed and running!${NC}"
            systemctl status simple_tunnel.service --no-pager | head -15
        else
            echo -e "${RED}✗ Service failed to start${NC}"
            journalctl -u simple_tunnel.service -n 20 --no-pager
        fi
    else
        echo -e "${RED}✗ Command test failed!${NC}"
        return 1
    fi
}

# Fix existing tunnel
fix_tunnel() {
    echo -e "${RED}=== Fix Tunnel Service ===${NC}"
    
    # Check existing service
    if [ ! -f /etc/systemd/system/tunnel.service ]; then
        echo -e "${RED}No tunnel service found!${NC}"
        return 1
    fi
    
    # Stop service
    systemctl stop tunnel.service 2>/dev/null
    
    # Backup
    cp /etc/systemd/system/tunnel.service $BACKUP_DIR/tunnel.service.backup.$(date +%s)
    
    # Get current command
    current_cmd=$(grep ExecStart /etc/systemd/system/tunnel.service | sed 's/ExecStart=.*rtt //')
    
    echo -e "${YELLOW}Current command: $current_cmd${NC}"
    
    # Test current command
    echo -e "${YELLOW}Testing current command...${NC}"
    timeout 5 /usr/local/bin/rtt $current_cmd >/dev/null 2>&1 &
    local pid=$!
    sleep 3
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Current command works!${NC}"
        kill $pid 2>/dev/null
        
        # Just restart service
        systemctl daemon-reload
        systemctl start tunnel.service
        sleep 2
        
        if systemctl is-active --quiet tunnel.service; then
            echo -e "${GREEN}✓ Service fixed!${NC}"
        else
            echo -e "${RED}✗ Still failing. Check logs...${NC}"
            journalctl -u tunnel.service -n 30 --no-pager
        fi
        
    else
        echo -e "${RED}✗ Current command fails!${NC}"
        
        # Try to fix common issues
        echo -e "${YELLOW}Attempting to fix...${NC}"
        
        # Remove problematic options
        fixed_cmd=$(echo $current_cmd | sed 's/--terminate:[0-9]*//g' | sed 's/--log-level:[^ ]*//g')
        fixed_cmd="$fixed_cmd --log-level:debug"
        
        echo -e "${YELLOW}Fixed command: $fixed_cmd${NC}"
        
        # Test fixed command
        timeout 5 /usr/local/bin/rtt $fixed_cmd >/dev/null 2>&1 &
        local pid2=$!
        sleep 3
        
        if ps -p $pid2 >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Fixed command works!${NC}"
            kill $pid2 2>/dev/null
            
            # Update service
            sed -i "s|ExecStart=.*|ExecStart=/usr/local/bin/rtt $fixed_cmd|" /etc/systemd/system/tunnel.service
            systemctl daemon-reload
            systemctl start tunnel.service
            
            sleep 2
            
            if systemctl is-active --quiet tunnel.service; then
                echo -e "${GREEN}✓ Service fixed with new command!${NC}"
            else
                echo -e "${RED}✗ Still failing...${NC}"
            fi
        else
            echo -e "${RED}✗ Could not fix automatically.${NC}"
        fi
    fi
}

# View logs
view_logs() {
    echo -e "${CYAN}=== View Logs ===${NC}"
    
    echo "1) tunnel.service"
    echo "2) simple_tunnel.service"
    echo "3) All RTT logs"
    echo "4) System journal"
    
    read -p "Choice: " choice
    
    case $choice in
        1)
            echo -e "${YELLOW}=== tunnel.service logs ===${NC}"
            tail -50 $LOG_DIR/tunnel.log 2>/dev/null || echo "No log file"
            echo -e "\n${YELLOW}=== Error logs ===${NC}"
            tail -20 $LOG_DIR/tunnel.error.log 2>/dev/null || echo "No error log"
            ;;
        2)
            echo -e "${YELLOW}=== simple_tunnel.service logs ===${NC}"
            tail -50 $LOG_DIR/simple_tunnel.log 2>/dev/null || echo "No log file"
            ;;
        3)
            echo -e "${YELLOW}=== All RTT logs ===${NC}"
            grep -r "RTT\|rtt" /var/log/ 2>/dev/null | tail -50 || echo "No RTT logs"
            ;;
        4)
            echo -e "${YELLOW}=== System journal for tunnel services ===${NC}"
            journalctl -u tunnel.service -u simple_tunnel.service -n 50 --no-pager
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            ;;
    esac
}

# Manual RTT command
manual_command() {
    echo -e "${GREEN}=== Manual RTT Command ===${NC}"
    
    if ! command -v rtt &> /dev/null; then
        install_rtt
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    echo -e "${YELLOW}Example Iran server:${NC}"
    echo "  rtt --iran --lport:443 --password:YOUR_PASS --sni:google.com --log-level:debug"
    echo ""
    echo -e "${YELLOW}Example Kharej server:${NC}"
    echo "  rtt --kharej --iran-ip:IRAN_IP --iran-port:443 --toip:127.0.0.1 --toport:8080 --password:YOUR_PASS --sni:google.com --log-level:debug"
    echo ""
    
    read -p "Enter full RTT command: " cmd
    
    if [ -z "$cmd" ]; then
        echo -e "${RED}No command entered!${NC}"
        return 1
    fi
    
    # Test command
    echo -e "${YELLOW}Testing command...${NC}"
    timeout 10 /usr/local/bin/rtt $cmd &
    local pid=$!
    sleep 5
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Command works!${NC}"
        kill $pid 2>/dev/null
        
        read -p "Create service with this command? [y/N]: " create_service
        if [[ $create_service =~ ^[Yy]$ ]]; then
            read -p "Service name (default: custom_tunnel): " service_name
            service_name=${service_name:-custom_tunnel}
            
            generate_service "$service_name" "$cmd" "Custom"
            
            systemctl daemon-reload
            systemctl enable $service_name.service
            systemctl start $service_name.service
            
            sleep 2
            
            if systemctl is-active --quiet $service_name.service; then
                echo -e "${GREEN}✓ Service created and running!${NC}"
            else
                echo -e "${RED}✗ Service failed to start${NC}"
                journalctl -u $service_name.service -n 20 --no-pager
            fi
        fi
    else
        echo -e "${RED}✗ Command failed!${NC}"
    fi
}

# Clean reinstall
clean_reinstall() {
    echo -e "${RED}=== Clean Reinstall ===${NC}"
    
    # Stop all services
    systemctl stop tunnel.service 2>/dev/null
    systemctl stop simple_tunnel.service 2>/dev/null
    systemctl stop custom_tunnel.service 2>/dev/null
    
    # Remove services
    rm -f /etc/systemd/system/tunnel.service
    rm -f /etc/systemd/system/simple_tunnel.service
    rm -f /etc/systemd/system/custom_tunnel.service
    
    # Remove RTT
    rm -f /usr/local/bin/rtt /usr/bin/rtt
    
    # Clear logs
    rm -rf $LOG_DIR/*
    
    systemctl daemon-reload
    
    echo -e "${GREEN}Cleaned all RTT installations.${NC}"
    echo -e "${YELLOW}You can now install fresh.${NC}"
}

# Check system status
check_system() {
    echo -e "${CYAN}=== System Status ===${NC}"
    
    # RTT
    if command -v rtt &> /dev/null; then
        echo -e "${GREEN}✓ RTT installed: $(rtt --version 2>&1 | head -1)${NC}"
    else
        echo -e "${RED}✗ RTT not installed${NC}"
    fi
    
    # Services
    echo -e "\n${YELLOW}Services:${NC}"
    for svc in tunnel simple_tunnel custom_tunnel; do
        if systemctl is-enabled ${svc}.service 2>/dev/null; then
            if systemctl is-active ${svc}.service 2>/dev/null; then
                echo -e "  ${GREEN}✓ $svc: RUNNING${NC}"
            else
                echo -e "  ${RED}✗ $svc: STOPPED${NC}"
            fi
        fi
    done
    
    # Ports
    echo -e "\n${YELLOW}Ports in use:${NC}"
    for port in 443 80 20000 8080; do
        if lsof -i :$port >/dev/null 2>&1; then
            process=$(lsof -i :$port | awk 'NR==2 {print $1}')
            echo -e "  ${RED}Port $port: Used by $process${NC}"
        else
            echo -e "  ${GREEN}Port $port: Available${NC}"
        fi
    done
    
    # Internet
    echo -e "\n${YELLOW}Internet connectivity:${NC}"
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Internet OK${NC}"
    else
        echo -e "  ${RED}✗ No internet${NC}"
    fi
}

# Main menu
main_menu() {
    while true; do
        print_banner
        
        echo -e "\n${PURPLE}=== Main Menu ===${NC}"
        echo -e "${GREEN}1) Install Multiport Tunnel${NC}"
        echo -e "${GREEN}2) Install Simple Tunnel${NC}"
        echo -e "${RED}3) Fix Existing Tunnel${NC}"
        echo -e "${CYAN}4) View Logs${NC}"
        echo -e "${CYAN}5) Manual RTT Command${NC}"
        echo -e "${YELLOW}6) Check System Status${NC}"
        echo -e "${RED}7) Clean Reinstall${NC}"
        echo -e "${WHITE}8) Update RTT${NC}"
        echo -e "${WHITE}0) Exit${NC}"
        
        read -p "Select option: " choice
        
        case $choice in
            1) 
                install_multiport
                read -p "Press Enter to continue..."
                ;;
            2) 
                install_simple_tunnel
                read -p "Press Enter to continue..."
                ;;
            3) 
                fix_tunnel
                read -p "Press Enter to continue..."
                ;;
            4) 
                view_logs
                read -p "Press Enter to continue..."
                ;;
            5) 
                manual_command
                read -p "Press Enter to continue..."
                ;;
            6) 
                check_system
                read -p "Press Enter to continue..."
                ;;
            7) 
                clean_reinstall
                read -p "Press Enter to continue..."
                ;;
            8) 
                install_rtt
                read -p "Press Enter to continue..."
                ;;
            0) 
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Initial setup
init_setup() {
    root_access
    detect_distribution
    init_dirs
    check_dependencies
}

# Trap Ctrl+C
trap 'echo -e "\n${RED}Exiting...${NC}"; exit 1' INT

# Start
if [ "$0" = "$BASH_SOURCE" ]; then
    init_setup
    main_menu
fi
