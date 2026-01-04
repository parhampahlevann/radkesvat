#!/bin/bash

# Global Variables
TUNNEL_DIR="/etc/rtt"
CONFIG_DIR="$TUNNEL_DIR/config"
LOG_DIR="$TUNNEL_DIR/logs"
BACKUP_DIR="$TUNNEL_DIR/backup"

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
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    Advanced Reverse TLS Tunnel - Enhanced Edition        ║"
    echo "║     with TCPMUX, KCP, WebSocket Support                  ║"
    echo "║     By: Peyman - Github.com/Ptechgithub                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
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
            centos|rhel|fedora)
                if [ $ID = "centos" ] || [ $ID = "rhel" ]; then
                    package_manager="yum"
                else
                    package_manager="dnf"
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

# Install dependencies
check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"
    
    local dependencies=("wget" "curl" "unzip" "lsof" "iptables" "net-tools" "jq" "socat" "nmap" "screen")
    
    for dep in "${dependencies[@]}"; do
        if ! command -v $dep &> /dev/null; then
            echo -e "${YELLOW}Installing $dep...${NC}"
            $package_manager install -y $dep 2>/dev/null || {
                echo -e "${RED}Failed to install $dep${NC}"
                # Continue anyway
            }
        fi
    done
    
    # Install KCP if needed
    if ! command -v kcptun-server &> /dev/null; then
        install_kcp_tools
    fi
}

# Install KCP tools
install_kcp_tools() {
    echo -e "${YELLOW}Installing KCP tools...${NC}"
    arch=$(uname -m)
    case $arch in
        x86_64) kcp_arch="amd64" ;;
        aarch64|arm64) kcp_arch="arm64" ;;
        armv7l) kcp_arch="arm7" ;;
        *) kcp_arch="amd64" ;;
    esac
    
    wget -q "https://github.com/xtaci/kcptun/releases/latest/download/kcptun-linux-$kcp_arch.tar.gz" -O /tmp/kcptun.tar.gz
    tar -xzf /tmp/kcptun.tar.gz -C /usr/local/bin/
    chmod +x /usr/local/bin/kcptun-*
    rm -f /tmp/kcptun.tar.gz
}

# Check if service is installed
check_installed() {
    local service_name=$1
    if systemctl is-active --quiet $service_name 2>/dev/null || 
       systemctl is-enabled --quiet $service_name 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Get latest RTT version
get_latest_version() {
    local version=$(curl -s https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest | jq -r '.tag_name' | sed 's/V//')
    echo $version
}

# Install RTT
install_rtt() {
    local version=${1:-$(get_latest_version)}
    
    echo -e "${YELLOW}Installing RTT version $version...${NC}"
    
    # Stop any running RTT processes
    pkill -f RTT 2>/dev/null
    
    # Detect architecture
    arch=$(uname -m)
    case $arch in
        x86_64) rtt_arch="amd64" ;;
        aarch64|arm64) rtt_arch="arm64" ;;
        armv7l) rtt_arch="arm" ;;
        *) rtt_arch="amd64" ;;
    esac
    
    # Download
    wget -q "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_${rtt_arch}.zip" -O /tmp/rtt.zip
    
    if [ ! -f /tmp/rtt.zip ]; then
        echo -e "${RED}Failed to download RTT!${NC}"
        return 1
    fi
    
    # Extract and install
    unzip -o /tmp/rtt.zip -d /usr/local/bin/
    mv /usr/local/bin/RTT /usr/local/bin/rtt 2>/dev/null
    chmod +x /usr/local/bin/rtt /usr/local/bin/RTT 2>/dev/null
    
    # Create symlink
    ln -sf /usr/local/bin/rtt /usr/bin/rtt 2>/dev/null
    ln -sf /usr/local/bin/RTT /usr/bin/RTT 2>/dev/null
    
    rm -f /tmp/rtt.zip
    echo -e "${GREEN}RTT installed successfully!${NC}"
}

# Configure protocol-specific settings
configure_protocol() {
    local protocol=$1
    local config_file=$2
    
    case $protocol in
        "tcpmux")
            echo "--tcpmux:true --tcpmux-port:1" >> $config_file
            ;;
        "kcp")
            echo "--kcp:true --kcp-mtu:1350 --kcp-sndwnd:1024 --kcp-rcvwnd:1024 --kcp-mode:fast" >> $config_file
            ;;
        "websocket")
            echo "--websocket:true --websocket-path:/ws" >> $config_file
            ;;
        "multi")
            echo "--tcpmux:true --kcp:true --websocket:true" >> $config_file
            ;;
    esac
}

# Performance optimization
optimize_performance() {
    echo -e "${YELLOW}Applying performance optimizations...${NC}"
    
    # TCP optimizations
    cat >> /etc/sysctl.conf << EOF
# TCP Optimizations for Tunnel
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.default_qdisc = fq
EOF
    
    sysctl -p 2>/dev/null
    
    # Increase file descriptors
    echo "* soft nofile 102400" >> /etc/security/limits.conf
    echo "* hard nofile 102400" >> /etc/security/limits.conf
    echo "root soft nofile 102400" >> /etc/security/limits.conf
    echo "root hard nofile 102400" >> /etc/security/limits.conf
}

# Generate service file
generate_service() {
    local service_name=$1
    local args=$2
    local type=$3
    
    cat > /etc/systemd/system/$service_name.service << EOF
[Unit]
Description=Advanced Reverse TLS Tunnel ($type)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="GODEBUG=netdns=go"
Environment="GOTRACEBACK=crash"
ExecStart=/usr/bin/rtt $args
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StartLimitInterval=0
LimitNOFILE=102400
LimitNPROC=102400
StandardOutput=append:$LOG_DIR/${service_name}.log
StandardError=append:$LOG_DIR/${service_name}.error.log

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$LOG_DIR $CONFIG_DIR

[Install]
WantedBy=multi-user.target
EOF
}

# Install multiport tunnel
install_multiport() {
    print_banner
    echo -e "${GREEN}=== Install Multiport Tunnel ===${NC}"
    
    if check_installed "tunnel.service"; then
        echo -e "${RED}Tunnel service is already installed!${NC}"
        return 1
    fi
    
    # Get configuration
    read -p "Which server? [1] Iran (internal) [2] Kharej (external): " server_choice
    
    # Get SNI
    read -p "Enter SNI (default: cloudflare.com): " sni
    sni=${sni:-cloudflare.com}
    
    # Get protocol
    echo -e "${CYAN}Select protocol:${NC}"
    echo "1) Standard TLS"
    echo "2) TCPMUX"
    echo "3) KCP"
    echo "4) WebSocket"
    echo "5) All protocols (Multi)"
    read -p "Choice (1-5): " protocol_choice
    
    case $protocol_choice in
        2) protocol="tcpmux" ;;
        3) protocol="kcp" ;;
        4) protocol="websocket" ;;
        5) protocol="multi" ;;
        *) protocol="standard" ;;
    esac
    
    # Common arguments
    common_args="--terminate:24 --log-level:info"
    
    if [ "$server_choice" = "2" ]; then
        # Kharej (external server)
        read -p "Enter Iran server IP: " iran_ip
        read -p "Enter password: " password
        
        args="--kharej --iran-ip:$iran_ip --iran-port:443 --toip:127.0.0.1 --toport:20000-30000"
        args="$args --password:$password --sni:$sni $common_args"
        
    elif [ "$server_choice" = "1" ]; then
        # Iran (internal server)
        read -p "Enter password: " password
        read -p "Enable fake upload? [y/N]: " fake_upload
        
        args="--iran --lport:20000-30000 --password:$password --sni:$sni $common_args"
        
        if [[ $fake_upload =~ ^[Yy]$ ]]; then
            read -p "Upload ratio (e.g., 5 for 5:1): " ratio
            args="$args --noise:$((ratio-1))"
        fi
    else
        echo -e "${RED}Invalid choice!${NC}"
        return 1
    fi
    
    # Add protocol configuration
    if [ "$protocol" != "standard" ]; then
        configure_protocol "$protocol" "$CONFIG_DIR/protocol.conf"
        protocol_args=$(cat "$CONFIG_DIR/protocol.conf")
        args="$args $protocol_args"
    fi
    
    # Performance optimizations
    args="$args --tcp-keepalive:30 --buffer-size:8192"
    
    echo -e "${YELLOW}Generated command: rtt $args${NC}"
    read -p "Proceed with installation? [Y/n]: " confirm
    
    if [[ ! $confirm =~ ^[Nn]$ ]]; then
        # Install RTT
        install_rtt
        
        # Generate service file
        generate_service "tunnel" "$args" "Multiport"
        
        # Optimize system
        optimize_performance
        
        # Start service
        systemctl daemon-reload
        systemctl enable tunnel.service
        systemctl start tunnel.service
        
        echo -e "${GREEN}Multiport tunnel installed successfully!${NC}"
        echo -e "${YELLOW}Protocol: $protocol${NC}"
        echo -e "${YELLOW}SNI: $sni${NC}"
    fi
}

# Install load balancer
install_loadbalancer() {
    print_banner
    echo -e "${GREEN}=== Install Load Balancer ===${NC}"
    
    if check_installed "lbtunnel.service"; then
        echo -e "${RED}Load balancer is already installed!${NC}"
        return 1
    fi
    
    # Get configuration
    read -p "Which server? [1] Iran [2] Kharej: " server_choice
    read -p "Enter SNI (default: google.com): " sni
    sni=${sni:-google.com}
    
    # Get protocol
    echo "Select protocol:"
    echo "1) Standard"
    echo "2) TCPMUX"
    echo "3) KCP"
    echo "4) WebSocket"
    read -p "Choice: " protocol_choice
    
    case $protocol_choice in
        2) protocol="tcpmux" ;;
        3) protocol="kcp" ;;
        4) protocol="websocket" ;;
        *) protocol="standard" ;;
    esac
    
    if [ "$server_choice" = "2" ]; then
        # Kharej server
        read -p "Is this main VPN server? [y/N]: " is_main
        read -p "Iran IP: " iran_ip
        read -p "Password: " password
        
        args="--kharej --iran-ip:$iran_ip --iran-port:443"
        
        if [[ $is_main =~ ^[Yy]$ ]]; then
            args="$args --toip:127.0.0.1 --toport:10000-15000"
        else
            read -p "Main server IP: " main_ip
            args="$args --toip:$main_ip --toport:10000-15000"
        fi
        
        args="$args --password:$password --sni:$sni --terminate:24"
        
    elif [ "$server_choice" = "1" ]; then
        # Iran server
        read -p "Password: " password
        
        args="--iran --lport:10000-15000 --password:$password --sni:$sni --terminate:24"
        
        # Add peers
        echo "Enter peer IPs (type 'done' when finished):"
        while true; do
            read -p "Peer IP: " peer_ip
            [ "$peer_ip" = "done" ] && break
            args="$args --peer:$peer_ip"
        done
    fi
    
    # Add protocol
    if [ "$protocol" != "standard" ]; then
        configure_protocol "$protocol" "$CONFIG_DIR/lb_protocol.conf"
        protocol_args=$(cat "$CONFIG_DIR/lb_protocol.conf")
        args="$args $protocol_args"
    fi
    
    echo -e "${YELLOW}Generated command: rtt $args${NC}"
    read -p "Proceed? [Y/n]: " confirm
    
    if [[ ! $confirm =~ ^[Nn]$ ]]; then
        install_rtt
        generate_service "lbtunnel" "$args" "LoadBalancer"
        
        systemctl daemon-reload
        systemctl enable lbtunnel.service
        systemctl start lbtunnel.service
        
        echo -e "${GREEN}Load balancer installed!${NC}"
    fi
}

# Change SNI dynamically
change_sni() {
    echo -e "${GREEN}=== Change SNI ===${NC}"
    
    # Check installed services
    services=()
    [ -f /etc/systemd/system/tunnel.service ] && services+=("tunnel.service")
    [ -f /etc/systemd/system/lbtunnel.service ] && services+=("lbtunnel.service")
    [ -f /etc/systemd/system/custom_tunnel.service ] && services+=("custom_tunnel.service")
    
    if [ ${#services[@]} -eq 0 ]; then
        echo -e "${RED}No tunnel services found!${NC}"
        return 1
    fi
    
    echo "Available services:"
    for i in "${!services[@]}"; do
        echo "$((i+1))) ${services[$i]}"
    done
    
    read -p "Select service: " service_choice
    service=${services[$((service_choice-1))]}
    
    if [ -z "$service" ]; then
        echo -e "${RED}Invalid selection!${NC}"
        return 1
    fi
    
    read -p "Enter new SNI: " new_sni
    [ -z "$new_sni" ] && new_sni="cloudflare.com"
    
    # Backup current service
    cp "/etc/systemd/system/$service" "$BACKUP_DIR/$service.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Update SNI in service file
    sed -i "s/--sni:[^ ]*/--sni:$new_sni/g" "/etc/systemd/system/$service"
    
    # Reload and restart
    systemctl daemon-reload
    systemctl restart $service
    
    echo -e "${GREEN}SNI changed to $new_sni for $service${NC}"
}

# Update RTT
update_rtt() {
    echo -e "${GREEN}=== Update RTT ===${NC}"
    
    # Get current version
    if command -v rtt &> /dev/null; then
        current_version=$(rtt -v 2>&1 | grep -oE 'version="[0-9.]+"' | cut -d'"' -f2)
        echo -e "Current version: ${YELLOW}$current_version${NC}"
    else
        echo -e "${YELLOW}RTT not found, installing fresh...${NC}"
    fi
    
    # Get latest version
    latest_version=$(get_latest_version)
    echo -e "Latest version: ${GREEN}$latest_version${NC}"
    
    if [ "$current_version" = "$latest_version" ]; then
        echo -e "${YELLOW}Already on latest version!${NC}"
        return 0
    fi
    
    read -p "Update to v$latest_version? [Y/n]: " confirm
    if [[ ! $confirm =~ ^[Nn]$ ]]; then
        # Stop services
        systemctl stop tunnel.service 2>/dev/null
        systemctl stop lbtunnel.service 2>/dev/null
        systemctl stop custom_tunnel.service 2>/dev/null
        
        # Install new version
        install_rtt $latest_version
        
        # Restart services
        systemctl start tunnel.service 2>/dev/null
        systemctl start lbtunnel.service 2>/dev/null
        systemctl start custom_tunnel.service 2>/dev/null
        
        echo -e "${GREEN}RTT updated successfully!${NC}"
    fi
}

# Show tunnel status
show_status() {
    echo -e "${CYAN}=== Tunnel Status ===${NC}"
    
    # Check services
    declare -A services
    services=(
        ["tunnel.service"]="Multiport Tunnel"
        ["lbtunnel.service"]="Load Balancer"
        ["custom_tunnel.service"]="Custom Tunnel"
    )
    
    for service in "${!services[@]}"; do
        if systemctl is-active --quiet $service 2>/dev/null; then
            status="${GREEN}[RUNNING]${NC}"
        elif systemctl is-enabled --quiet $service 2>/dev/null; then
            status="${YELLOW}[STOPPED]${NC}"
        else
            status="${RED}[NOT INSTALLED]${NC}"
        fi
        
        echo -e "${services[$service]}: $status"
        
        # Show listening ports if running
        if systemctl is-active --quiet $service; then
            ports=$(ss -tulpn | grep rtt | awk '{print $5}' | cut -d':' -f2 | sort -nu | head -5)
            [ -n "$ports" ] && echo -e "  Ports: ${YELLOW}$ports${NC}"
        fi
    done
    
    # Show system info
    echo -e "\n${CYAN}=== System Info ===${NC}"
    echo -e "CPU Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo -e "Memory: $(free -h | awk '/^Mem:/ {print $3"/"$2}')"
    
    # Show RTT version
    if command -v rtt &> /dev/null; then
        version=$(rtt -v 2>&1 | grep -oE 'version="[0-9.]+"' | cut -d'"' -f2)
        echo -e "RTT Version: ${GREEN}$version${NC}"
    fi
}

# Monitor tunnel
monitor_tunnel() {
    echo -e "${GREEN}=== Real-time Tunnel Monitor ===${NC}"
    echo "Press Ctrl+C to exit"
    echo ""
    
    while true; do
        clear
        show_status
        echo -e "\n${YELLOW}Connections:${NC}"
        netstat -tn | grep ESTABLISHED | grep -E ':443|:80' | head -10
        sleep 2
    done
}

# Main menu
main_menu() {
    while true; do
        print_banner
        show_status
        
        echo -e "\n${PURPLE}=== Main Menu ===${NC}"
        echo -e "${GREEN}1) Install Multiport Tunnel${NC}"
        echo -e "${GREEN}2) Install Load Balancer${NC}"
        echo -e "${GREEN}3) Install Custom Tunnel${NC}"
        echo -e "${RED}4) Uninstall Services${NC}"
        echo -e "${CYAN}5) Start/Stop Services${NC}"
        echo -e "${CYAN}6) Change SNI${NC}"
        echo -e "${YELLOW}7) Update RTT${NC}"
        echo -e "${YELLOW}8) Performance Tune${NC}"
        echo -e "${BLUE}9) Real-time Monitor${NC}"
        echo -e "${WHITE}0) Exit${NC}"
        
        echo -e "\n${PURPLE}Protocol Support:${NC} TCPMUX | KCP | WebSocket | Multi"
        
        read -p "Select option: " choice
        
        case $choice in
            1) install_multiport ;;
            2) install_loadbalancer ;;
            3) install_custom_tunnel ;;
            4) uninstall_menu ;;
            5) service_control_menu ;;
            6) change_sni ;;
            7) update_rtt ;;
            8) optimize_performance ;;
            9) monitor_tunnel ;;
            0) 
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Service control menu
service_control_menu() {
    echo -e "${CYAN}=== Service Control ===${NC}"
    
    declare -A services
    services=(
        [1]="tunnel.service"
        [2]="lbtunnel.service"
        [3]="custom_tunnel.service"
    )
    
    echo "1) Multiport Tunnel"
    echo "2) Load Balancer"
    echo "3) Custom Tunnel"
    echo "4) All Services"
    
    read -p "Select service: " svc_choice
    read -p "Action: [1] Start [2] Stop [3] Restart: " action
    
    case $action in
        1) cmd="start" ;;
        2) cmd="stop" ;;
        3) cmd="restart" ;;
        *) cmd="status" ;;
    esac
    
    if [ "$svc_choice" = "4" ]; then
        for svc in "${services[@]}"; do
            systemctl $cmd $svc 2>/dev/null
            echo -e "${GREEN}$cmd $svc${NC}"
        done
    else
        svc=${services[$svc_choice]}
        if [ -n "$svc" ]; then
            systemctl $cmd $svc
            echo -e "${GREEN}$cmd $svc${NC}"
        fi
    fi
}

# Uninstall menu
uninstall_menu() {
    echo -e "${RED}=== Uninstall ===${NC}"
    echo "1) Uninstall Multiport"
    echo "2) Uninstall Load Balancer"
    echo "3) Uninstall Custom"
    echo "4) Uninstall All"
    
    read -p "Select: " choice
    
    case $choice in
        1) 
            systemctl stop tunnel.service 2>/dev/null
            systemctl disable tunnel.service 2>/dev/null
            rm -f /etc/systemd/system/tunnel.service
            ;;
        2)
            systemctl stop lbtunnel.service 2>/dev/null
            systemctl disable lbtunnel.service 2>/dev/null
            rm -f /etc/systemd/system/lbtunnel.service
            ;;
        3)
            systemctl stop custom_tunnel.service 2>/dev/null
            systemctl disable custom_tunnel.service 2>/dev/null
            rm -f /etc/systemd/system/custom_tunnel.service
            ;;
        4)
            for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
                systemctl stop $svc 2>/dev/null
                systemctl disable $svc 2>/dev/null
                rm -f /etc/systemd/system/$svc
            done
            rm -rf $TUNNEL_DIR
            ;;
    esac
    
    systemctl daemon-reload
    echo -e "${GREEN}Uninstall completed!${NC}"
}

# Install custom tunnel
install_custom_tunnel() {
    echo -e "${GREEN}=== Custom Tunnel Setup ===${NC}"
    
    read -p "Enter full RTT command (with all args): " custom_args
    
    if [ -z "$custom_args" ]; then
        echo -e "${RED}No arguments provided!${NC}"
        return 1
    fi
    
    # Extract SNI from args for logging
    sni=$(echo $custom_args | grep -oE '--sni:[^ ]+' | cut -d':' -f2)
    [ -z "$sni" ] && sni="custom"
    
    # Generate service
    generate_service "custom_tunnel" "$custom_args" "Custom"
    
    systemctl daemon-reload
    systemctl enable custom_tunnel.service
    systemctl start custom_tunnel.service
    
    echo -e "${GREEN}Custom tunnel installed with SNI: $sni${NC}"
}

# Initial setup
init_setup() {
    root_access
    detect_distribution
    check_dependencies
    init_dirs
}

# Main execution
if [ "$0" = "$BASH_SOURCE" ]; then
    init_setup
    main_menu
fi
