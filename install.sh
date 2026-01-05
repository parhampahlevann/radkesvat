#!/bin/bash

# Global Variables
TUNNEL_DIR="/etc/rtt"
CONFIG_DIR="$TUNNEL_DIR/config"
LOG_DIR="$TUNNEL_DIR/logs"
BACKUP_DIR="$TUNNEL_DIR/backup"
SCRIPT_VERSION="2.1"

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
    touch $LOG_DIR/install.log
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
                update_cmd="apt-get update"
                ;;
            centos|rhel|fedora|almalinux|rocky)
                if [ $ID = "centos" ] || [ $ID = "rhel" ]; then
                    package_manager="yum"
                elif [ $ID = "fedora" ]; then
                    package_manager="dnf"
                else
                    package_manager="yum"
                fi
                update_cmd="$package_manager check-update"
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

# Check and install dependencies
check_dependencies() {
    echo -e "${YELLOW}Checking and installing dependencies...${NC}"
    
    # Update package list
    eval $update_cmd >/dev/null 2>&1
    
    local dependencies=("wget" "curl" "unzip" "lsof" "iptables" "net-tools" "jq" "socat" "screen")
    
    for dep in "${dependencies[@]}"; do
        if ! command -v $dep &> /dev/null; then
            echo -e "${YELLOW}Installing $dep...${NC}"
            $package_manager install -y $dep 2>&1 | tee -a $LOG_DIR/install.log
            if [ $? -ne 0 ]; then
                echo -e "${YELLOW}Failed to install $dep, trying alternative...${NC}"
                # Try alternative package names
                case $dep in
                    "net-tools")
                        $package_manager install -y net-tools iproute2 2>/dev/null || true
                        ;;
                    "jq")
                        wget -q https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-amd64 -O /usr/bin/jq
                        chmod +x /usr/bin/jq
                        ;;
                esac
            fi
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
    if [ -f /tmp/kcptun.tar.gz ]; then
        tar -xzf /tmp/kcptun.tar.gz -C /usr/local/bin/
        chmod +x /usr/local/bin/kcptun-*
        echo -e "${GREEN}KCP tools installed successfully${NC}"
    else
        echo -e "${YELLOW}Warning: Failed to download KCP tools${NC}"
    fi
    rm -f /tmp/kcptun.tar.gz
}

# Check if service is installed
check_installed() {
    local service_name=$1
    if systemctl is-enabled --quiet $service_name 2>/dev/null || [ -f "/etc/systemd/system/$service_name.service" ]; then
        return 0
    else
        return 1
    fi
}

# Get latest RTT version
get_latest_version() {
    local version=$(curl -s --connect-timeout 10 https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest | jq -r '.tag_name' | sed 's/V//' 2>/dev/null)
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        # Fallback to known version
        version="7.0.1"
    fi
    echo $version
}

# Install RTT with verification
install_rtt() {
    local version=${1:-$(get_latest_version)}
    
    echo -e "${YELLOW}Installing RTT version $version...${NC}"
    
    # Stop any running RTT processes
    pkill -f "rtt" 2>/dev/null || true
    pkill -f "RTT" 2>/dev/null || true
    sleep 2
    
    # Detect architecture
    arch=$(uname -m)
    case $arch in
        x86_64) rtt_arch="amd64" ;;
        aarch64|arm64) rtt_arch="arm64" ;;
        armv7l) rtt_arch="arm" ;;
        *) rtt_arch="amd64" ;;
    esac
    
    # Clean previous installations
    rm -f /usr/local/bin/rtt /usr/local/bin/RTT /usr/bin/rtt /usr/bin/RTT
    
    # Download RTT
    echo -e "${YELLOW}Downloading RTT v$version for $rtt_arch...${NC}"
    
    # Try multiple URLs
    local download_urls=(
        "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_${rtt_arch}.zip"
        "https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/v${version}_linux_${rtt_arch}.zip"
    )
    
    local download_success=0
    for url in "${download_urls[@]}"; do
        echo -e "${YELLOW}Trying: $url${NC}"
        if wget -q --timeout=30 --tries=3 "$url" -O /tmp/rtt.zip; then
            download_success=1
            break
        fi
    done
    
    if [ $download_success -eq 0 ]; then
        echo -e "${RED}Failed to download RTT!${NC}"
        echo -e "${YELLOW}Please check:${NC}"
        echo -e "1. Internet connection"
        echo -e "2. GitHub access"
        echo -e "3. Version availability"
        return 1
    fi
    
    # Verify download
    if [ ! -f /tmp/rtt.zip ] || [ ! -s /tmp/rtt.zip ]; then
        echo -e "${RED}Downloaded file is empty or corrupted!${NC}"
        return 1
    fi
    
    # Extract
    echo -e "${YELLOW}Extracting files...${NC}"
    unzip -o /tmp/rtt.zip -d /tmp/rtt_extract/ 2>&1 | tee -a $LOG_DIR/install.log
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to extract RTT!${NC}"
        return 1
    fi
    
    # Find and install binary
    local binary_found=0
    for binary in /tmp/rtt_extract/RTT /tmp/rtt_extract/rtt /tmp/rtt_extract/*/RTT /tmp/rtt_extract/*/rtt; do
        if [ -f "$binary" ] && [ -x "$binary" ]; then
            cp "$binary" /usr/local/bin/rtt
            chmod +x /usr/local/bin/rtt
            binary_found=1
            break
        fi
    done
    
    if [ $binary_found -eq 0 ]; then
        echo -e "${RED}RTT binary not found in extracted files!${NC}"
        ls -la /tmp/rtt_extract/
        return 1
    fi
    
    # Create symlinks
    ln -sf /usr/local/bin/rtt /usr/bin/rtt 2>/dev/null
    ln -sf /usr/local/bin/rtt /usr/bin/RTT 2>/dev/null
    
    # Cleanup
    rm -rf /tmp/rtt_extract /tmp/rtt.zip
    
    # Verify installation
    echo -e "${YELLOW}Verifying installation...${NC}"
    if /usr/local/bin/rtt --version 2>&1 | grep -q "version"; then
        local installed_version=$(/usr/local/bin/rtt --version 2>&1 | grep -oE 'version="[0-9.]+"' | cut -d'"' -f2)
        echo -e "${GREEN}RTT v$installed_version installed successfully!${NC}"
        return 0
    else
        echo -e "${RED}RTT installation verification failed!${NC}"
        echo -e "${YELLOW}Debug info:${NC}"
        /usr/local/bin/rtt --version
        return 1
    fi
}

# Check if ports are available
check_ports() {
    local ports=$1
    local service_name=$2
    
    echo -e "${YELLOW}Checking port availability for $service_name...${NC}"
    
    # Parse port range
    local start_port end_port
    if [[ $ports =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start_port=${BASH_REMATCH[1]}
        end_port=${BASH_REMATCH[2]}
    elif [[ $ports =~ ^([0-9]+)$ ]]; then
        start_port=$ports
        end_port=$ports
    else
        echo -e "${RED}Invalid port format: $ports${NC}"
        return 1
    fi
    
    # Check each port
    for port in $(seq $start_port $end_port); do
        if lsof -i :$port >/dev/null 2>&1; then
            local process=$(lsof -i :$port | awk 'NR==2 {print $1}')
            echo -e "${RED}Port $port is already in use by $process!${NC}"
            echo -e "${YELLOW}Run 'lsof -i :$port' for details${NC}"
            return 1
        fi
        
        # Check if port is valid
        if [ $port -lt 1 ] || [ $port -gt 65535 ]; then
            echo -e "${RED}Invalid port number: $port${NC}"
            return 1
        fi
    done
    
    echo -e "${GREEN}Ports $ports are available${NC}"
    return 0
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
            echo "--websocket:true --websocket-path:/ws --websocket-host:\$sni" >> $config_file
            ;;
        "multi")
            echo "--tcpmux:true --kcp:true --websocket:true" >> $config_file
            ;;
    esac
}

# Performance optimization
optimize_performance() {
    echo -e "${YELLOW}Applying performance optimizations...${NC}"
    
    # Backup current sysctl
    cp /etc/sysctl.conf $BACKUP_DIR/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null
    
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
    
    sysctl -p >/dev/null 2>&1
    
    # Increase file descriptors
    if ! grep -q "nofile 102400" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << EOF

* soft nofile 102400
* hard nofile 102400
root soft nofile 102400
root hard nofile 102400
EOF
    fi
    
    # Apply changes for current session
    ulimit -n 102400
    
    echo -e "${GREEN}Performance optimizations applied!${NC}"
}

# Generate service file
generate_service() {
    local service_name=$1
    local args=$2
    local type=$3
    
    # Stop if service already exists and is running
    if systemctl is-active --quiet $service_name 2>/dev/null; then
        echo -e "${YELLOW}Stopping existing $service_name...${NC}"
        systemctl stop $service_name
        sleep 2
    fi
    
    # Remove old service file
    rm -f /etc/systemd/system/$service_name.service
    
    # Create new service file
    cat > /etc/systemd/system/$service_name.service << EOF
[Unit]
Description=Reverse TLS Tunnel ($type)
After=network.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="GODEBUG=netdns=go"
ExecStart=/usr/local/bin/rtt $args
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
TimeoutSec=30
StartLimitBurst=5
LimitNOFILE=102400
LimitNPROC=102400

# Logging
StandardOutput=append:$LOG_DIR/${service_name}.log
StandardError=append:$LOG_DIR/${service_name}.error.log

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=$LOG_DIR $CONFIG_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    # Set correct permissions
    chmod 644 /etc/systemd/system/$service_name.service
    
    echo -e "${GREEN}Service file created: /etc/systemd/system/$service_name.service${NC}"
}

# Install multiport tunnel
install_multiport() {
    print_banner
    echo -e "${GREEN}=== Install Multiport Tunnel ===${NC}"
    
    # Check if RTT is installed
    if ! command -v rtt &> /dev/null; then
        echo -e "${RED}RTT is not installed! Installing first...${NC}"
        install_rtt
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to install RTT! Aborting.${NC}"
            return 1
        fi
    fi
    
    if check_installed "tunnel.service"; then
        echo -e "${RED}Tunnel service is already installed!${NC}"
        read -p "Do you want to reinstall? [y/N]: " reinstall
        if [[ ! $reinstall =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # Get configuration
    echo -e "${CYAN}Which server are you setting up?${NC}"
    echo "1) Iran (internal server)"
    echo "2) Kharej (external server)"
    read -p "Choice [1/2]: " server_choice
    
    # Get SNI
    read -p "Enter SNI (default: cloudflare.com): " sni
    sni=${sni:-cloudflare.com}
    echo -e "${YELLOW}Using SNI: $sni${NC}"
    
    # Get protocol
    echo -e "${CYAN}Select protocol:${NC}"
    echo "1) Standard TLS (recommended)"
    echo "2) TCPMUX"
    echo "3) KCP"
    echo "4) WebSocket"
    echo "5) All protocols (Multi)"
    read -p "Choice [1-5]: " protocol_choice
    
    case $protocol_choice in
        2) protocol="tcpmux" ;;
        3) protocol="kcp" ;;
        4) protocol="websocket" ;;
        5) protocol="multi" ;;
        *) protocol="standard" ;;
    esac
    echo -e "${YELLOW}Selected protocol: $protocol${NC}"
    
    # Common arguments
    common_args="--terminate:24 --log-level:info --tcp-keepalive:30 --buffer-size:8192"
    
    if [ "$server_choice" = "2" ]; then
        # Kharej (external server)
        echo -e "${GREEN}Configuring Kharej server...${NC}"
        
        read -p "Enter Iran server IP: " iran_ip
        if [ -z "$iran_ip" ]; then
            echo -e "${RED}Iran IP is required!${NC}"
            return 1
        fi
        
        # Validate IP
        if [[ ! $iran_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}Invalid IP address format!${NC}"
            return 1
        fi
        
        read -p "Enter password (min 8 chars): " password
        if [ -z "$password" ] || [ ${#password} -lt 8 ]; then
            echo -e "${RED}Password must be at least 8 characters!${NC}"
            return 1
        fi
        
        # Define port range
        local_port_range="20000-25000"
        
        # Check ports
        check_ports "$local_port_range" "tunnel" || return 1
        
        # Build arguments
        args="--kharej --iran-ip:$iran_ip --iran-port:443 --toip:127.0.0.1 --toport:$local_port_range"
        args="$args --password:$password --sni:$sni $common_args"
        
    elif [ "$server_choice" = "1" ]; then
        # Iran (internal server)
        echo -e "${GREEN}Configuring Iran server...${NC}"
        
        read -p "Enter password (min 8 chars): " password
        if [ -z "$password" ] || [ ${#password} -lt 8 ]; then
            echo -e "${RED}Password must be at least 8 characters!${NC}"
            return 1
        fi
        
        # Define port range
        listen_port_range="20000-25000"
        
        # Check ports
        check_ports "$listen_port_range" "tunnel" || return 1
        
        # Build arguments
        args="--iran --lport:$listen_port_range --password:$password --sni:$sni $common_args"
        
        read -p "Enable fake upload? [y/N]: " fake_upload
        if [[ $fake_upload =~ ^[Yy]$ ]]; then
            read -p "Upload ratio (e.g., 5 for 5:1): " ratio
            if [[ $ratio =~ ^[0-9]+$ ]] && [ $ratio -gt 1 ]; then
                args="$args --noise:$((ratio-1))"
                echo -e "${YELLOW}Fake upload enabled with ratio $ratio:1${NC}"
            fi
        fi
    else
        echo -e "${RED}Invalid choice!${NC}"
        return 1
    fi
    
    # Add protocol configuration
    if [ "$protocol" != "standard" ]; then
        echo -e "${YELLOW}Configuring $protocol protocol...${NC}"
        config_file="$CONFIG_DIR/tunnel_${protocol}.conf"
        echo "# Protocol config for $protocol" > $config_file
        configure_protocol "$protocol" "$config_file"
        protocol_args=$(cat "$config_file" | grep -v "^#")
        args="$args $protocol_args"
    fi
    
    echo -e "${CYAN}Generated configuration:${NC}"
    echo -e "${YELLOW}rtt $args${NC}"
    echo ""
    
    read -p "Proceed with installation? [Y/n]: " confirm
    if [[ $confirm =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Installation cancelled${NC}"
        return 0
    fi
    
    # Install RTT if not already installed
    if ! command -v rtt &> /dev/null; then
        install_rtt
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Generate service file
    generate_service "tunnel" "$args" "Multiport"
    
    # Optimize system
    optimize_performance
    
    # Start service
    systemctl daemon-reload
    systemctl enable tunnel.service
    
    echo -e "${YELLOW}Starting tunnel service...${NC}"
    systemctl start tunnel.service
    
    # Check if service started successfully
    sleep 3
    if systemctl is-active --quiet tunnel.service; then
        echo -e "${GREEN}Tunnel service started successfully!${NC}"
        
        # Show service status
        echo -e "\n${CYAN}Service Status:${NC}"
        systemctl status tunnel.service --no-pager -l
        
        echo -e "\n${GREEN}Installation completed successfully!${NC}"
        echo -e "${YELLOW}Server Type: ${server_choice} (1=Iran, 2=Kharej)${NC}"
        echo -e "${YELLOW}Protocol: $protocol${NC}"
        echo -e "${YELLOW}SNI: $sni${NC}"
        echo -e "${YELLOW}Logs: $LOG_DIR/tunnel.log${NC}"
    else
        echo -e "${RED}Failed to start tunnel service!${NC}"
        echo -e "${YELLOW}Checking logs...${NC}"
        journalctl -u tunnel.service -n 20 --no-pager
        return 1
    fi
}

# Install load balancer
install_loadbalancer() {
    print_banner
    echo -e "${GREEN}=== Install Load Balancer ===${NC}"
    
    if check_installed "lbtunnel.service"; then
        echo -e "${RED}Load balancer is already installed!${NC}"
        read -p "Do you want to reinstall? [y/N]: " reinstall
        if [[ ! $reinstall =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # Get configuration
    echo -e "${CYAN}Which server are you setting up?${NC}"
    echo "1) Iran (internal)"
    echo "2) Kharej (external)"
    read -p "Choice [1/2]: " server_choice
    
    read -p "Enter SNI (default: cloudflare.com): " sni
    sni=${sni:-cloudflare.com}
    
    # Get protocol
    echo "Select protocol:"
    echo "1) Standard TLS"
    echo "2) TCPMUX"
    echo "3) KCP"
    echo "4) WebSocket"
    read -p "Choice [1-4]: " protocol_choice
    
    case $protocol_choice in
        2) protocol="tcpmux" ;;
        3) protocol="kcp" ;;
        4) protocol="websocket" ;;
        *) protocol="standard" ;;
    esac
    
    if [ "$server_choice" = "2" ]; then
        # Kharej server
        read -p "Is this main VPN server? [y/N]: " is_main
        read -p "Iran server IP: " iran_ip
        
        if [ -z "$iran_ip" ]; then
            echo -e "${RED}Iran IP is required!${NC}"
            return 1
        fi
        
        read -p "Password: " password
        if [ -z "$password" ]; then
            echo -e "${RED}Password is required!${NC}"
            return 1
        fi
        
        args="--kharej --iran-ip:$iran_ip --iran-port:443"
        
        if [[ $is_main =~ ^[Yy]$ ]]; then
            local_port_range="10000-11000"
            check_ports "$local_port_range" "lbtunnel" || return 1
            args="$args --toip:127.0.0.1 --toport:$local_port_range"
        else
            read -p "Main server IP: " main_ip
            if [ -z "$main_ip" ]; then
                echo -e "${RED}Main server IP is required!${NC}"
                return 1
            fi
            args="$args --toip:$main_ip --toport:10000-11000"
        fi
        
        args="$args --password:$password --sni:$sni --terminate:24 --log-level:info"
        
    elif [ "$server_choice" = "1" ]; then
        # Iran server
        read -p "Password: " password
        if [ -z "$password" ]; then
            echo -e "${RED}Password is required!${NC}"
            return 1
        fi
        
        listen_port_range="10000-11000"
        check_ports "$listen_port_range" "lbtunnel" || return 1
        
        args="--iran --lport:$listen_port_range --password:$password --sni:$sni --terminate:24 --log-level:info"
        
        # Add peers
        echo "Enter peer IPs (one per line, type 'done' when finished):"
        local peer_count=0
        while true; do
            read -p "Peer IP (or 'done'): " peer_ip
            [ "$peer_ip" = "done" ] && break
            
            if [[ $peer_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                args="$args --peer:$peer_ip"
                ((peer_count++))
                echo -e "${GREEN}Added peer: $peer_ip${NC}"
            else
                echo -e "${RED}Invalid IP address!${NC}"
            fi
        done
        
        if [ $peer_count -eq 0 ]; then
            echo -e "${YELLOW}No peers added. Load balancer will work in single mode.${NC}"
        fi
    else
        echo -e "${RED}Invalid choice!${NC}"
        return 1
    fi
    
    # Add protocol
    if [ "$protocol" != "standard" ]; then
        config_file="$CONFIG_DIR/lbtunnel_${protocol}.conf"
        echo "# Protocol config for $protocol" > $config_file
        configure_protocol "$protocol" "$config_file"
        protocol_args=$(cat "$config_file" | grep -v "^#")
        args="$args $protocol_args"
    fi
    
    echo -e "${CYAN}Generated configuration:${NC}"
    echo -e "${YELLOW}rtt $args${NC}"
    echo ""
    
    read -p "Proceed with installation? [Y/n]: " confirm
    if [[ $confirm =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Installation cancelled${NC}"
        return 0
    fi
    
    # Install RTT if needed
    if ! command -v rtt &> /dev/null; then
        install_rtt
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Generate service file
    generate_service "lbtunnel" "$args" "LoadBalancer"
    
    # Start service
    systemctl daemon-reload
    systemctl enable lbtunnel.service
    
    echo -e "${YELLOW}Starting load balancer service...${NC}"
    systemctl start lbtunnel.service
    
    # Check if service started successfully
    sleep 3
    if systemctl is-active --quiet lbtunnel.service; then
        echo -e "${GREEN}Load balancer started successfully!${NC}"
        echo -e "\n${CYAN}Service Status:${NC}"
        systemctl status lbtunnel.service --no-pager -l
        
        echo -e "\n${GREEN}Installation completed!${NC}"
        echo -e "${YELLOW}Protocol: $protocol${NC}"
        echo -e "${YELLOW}Logs: $LOG_DIR/lbtunnel.log${NC}"
    else
        echo -e "${RED}Failed to start load balancer!${NC}"
        journalctl -u lbtunnel.service -n 20 --no-pager
        return 1
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
    
    read -p "Select service [1-${#services[@]}]: " service_choice
    if [[ ! $service_choice =~ ^[0-9]+$ ]] || [ $service_choice -lt 1 ] || [ $service_choice -gt ${#services[@]} ]; then
        echo -e "${RED}Invalid selection!${NC}"
        return 1
    fi
    
    service=${services[$((service_choice-1))]}
    
    read -p "Enter new SNI: " new_sni
    [ -z "$new_sni" ] && new_sni="cloudflare.com"
    
    # Backup current service
    backup_file="$BACKUP_DIR/$service.backup.$(date +%Y%m%d_%H%M%S)"
    cp "/etc/systemd/system/$service" "$backup_file"
    echo -e "${GREEN}Backup created: $backup_file${NC}"
    
    # Update SNI in service file
    if grep -q "--sni:" "/etc/systemd/system/$service"; then
        sed -i "s/--sni:[^ ]*/--sni:$new_sni/g" "/etc/systemd/system/$service"
        echo -e "${YELLOW}SNI updated in service file${NC}"
    else
        echo -e "${RED}SNI parameter not found in service file!${NC}"
        return 1
    fi
    
    # Reload and restart
    systemctl daemon-reload
    systemctl restart $service
    
    sleep 2
    
    if systemctl is-active --quiet $service; then
        echo -e "${GREEN}SNI successfully changed to $new_sni for $service${NC}"
        echo -e "${YELLOW}Service restarted and running${NC}"
    else
        echo -e "${RED}Service failed to start after SNI change!${NC}"
        echo -e "${YELLOW}Restoring backup...${NC}"
        cp "$backup_file" "/etc/systemd/system/$service"
        systemctl daemon-reload
        systemctl restart $service
        return 1
    fi
}

# Update RTT
update_rtt() {
    echo -e "${GREEN}=== Update RTT ===${NC}"
    
    # Get current version
    local current_version="Unknown"
    if command -v rtt &> /dev/null; then
        current_version=$(rtt --version 2>&1 | grep -oE 'version="[0-9.]+"' | cut -d'"' -f2)
        echo -e "Current version: ${YELLOW}$current_version${NC}"
    else
        echo -e "${YELLOW}RTT not found, will install fresh...${NC}"
    fi
    
    # Get latest version
    echo -e "${YELLOW}Checking for latest version...${NC}"
    latest_version=$(get_latest_version)
    echo -e "Latest version: ${GREEN}$latest_version${NC}"
    
    if [ "$current_version" = "$latest_version" ]; then
        echo -e "${YELLOW}Already on latest version!${NC}"
        return 0
    fi
    
    read -p "Update to v$latest_version? [Y/n]: " confirm
    if [[ $confirm =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Update cancelled${NC}"
        return 0
    fi
    
    # Backup current services status
    echo -e "${YELLOW}Backing up current services status...${NC}"
    
    declare -A service_status
    for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            service_status[$svc]="active"
            echo -e "${YELLOW}Stopping $svc...${NC}"
            systemctl stop $svc
        else
            service_status[$svc]="inactive"
        fi
    done
    
    # Install new version
    install_rtt $latest_version
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to update RTT!${NC}"
        return 1
    fi
    
    # Restart services that were running
    echo -e "${YELLOW}Restarting services...${NC}"
    for svc in "${!service_status[@]}"; do
        if [ "${service_status[$svc]}" = "active" ]; then
            echo -e "${YELLOW}Starting $svc...${NC}"
            systemctl start $svc
            
            sleep 2
            if systemctl is-active --quiet $svc; then
                echo -e "${GREEN}$svc restarted successfully${NC}"
            else
                echo -e "${RED}Failed to restart $svc${NC}"
                journalctl -u $svc -n 10 --no-pager
            fi
        fi
    done
    
    echo -e "${GREEN}RTT updated successfully to v$latest_version!${NC}"
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
    
    local any_service_installed=0
    
    for service in "${!services[@]}"; do
        if [ -f "/etc/systemd/system/$service" ]; then
            any_service_installed=1
            if systemctl is-active --quiet $service 2>/dev/null; then
                status="${GREEN}● RUNNING${NC}"
                
                # Show listening ports
                local ports=$(ss -tulpn 2>/dev/null | grep rtt | awk '{print $5}' | cut -d':' -f2 | sort -nu | head -5 | tr '\n' ',')
                if [ -n "$ports" ]; then
                    ports=" Ports: ${YELLOW}${ports%,}${NC}"
                else
                    ports=""
                fi
                
                # Show uptime
                local uptime=$(systemctl status $service 2>/dev/null | grep -oP 'Active: .*?since \K.*' | head -1)
                if [ -n "$uptime" ]; then
                    uptime=" Uptime: ${YELLOW}$uptime${NC}"
                else
                    uptime=""
                fi
                
            elif systemctl is-enabled --quiet $service 2>/dev/null; then
                status="${YELLOW}○ STOPPED${NC}"
                ports=""
                uptime=""
            else
                status="${RED}× NOT ENABLED${NC}"
                ports=""
                uptime=""
            fi
            
            echo -e "${services[$service]}: $status$ports$uptime"
        fi
    done
    
    if [ $any_service_installed -eq 0 ]; then
        echo -e "${YELLOW}No tunnel services installed${NC}"
    fi
    
    # Show system info
    echo -e "\n${CYAN}=== System Info ===${NC}"
    
    # CPU Load
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    echo -e "CPU Load: ${YELLOW}$load${NC}"
    
    # Memory
    local mem=$(free -h | awk '/^Mem:/ {print $3"/"$2 " (" $3/$2*100 "%" ")"}')
    echo -e "Memory: ${YELLOW}$mem${NC}"
    
    # RTT version
    if command -v rtt &> /dev/null; then
        local version=$(rtt --version 2>&1 | grep -oE 'version="[0-9.]+"' | cut -d'"' -f2)
        echo -e "RTT Version: ${GREEN}$version${NC}"
    else
        echo -e "RTT: ${RED}Not installed${NC}"
    fi
    
    # Active connections
    local connections=$(ss -tn 2>/dev/null | grep -c ESTABLISHED)
    echo -e "Active Connections: ${YELLOW}$connections${NC}"
}

# Monitor tunnel in real-time
monitor_tunnel() {
    echo -e "${GREEN}=== Real-time Tunnel Monitor ===${NC}"
    echo "Press Ctrl+C to exit"
    echo ""
    
    trap 'echo -e "\n${YELLOW}Monitor stopped${NC}"; return 0' INT
    
    local update_interval=2
    
    while true; do
        clear
        print_banner
        
        # Show status
        echo -e "${CYAN}Last update: $(date '+%H:%M:%S')${NC}\n"
        
        # Service status
        declare -A services
        services=(
            ["tunnel.service"]="Multiport"
            ["lbtunnel.service"]="LoadBalancer"
            ["custom_tunnel.service"]="Custom"
        )
        
        echo -e "${PURPLE}Service Status:${NC}"
        for service in "${!services[@]}"; do
            if systemctl is-active --quiet $service 2>/dev/null; then
                # Get PID and memory usage
                local pid=$(systemctl show $service --property=MainPID | cut -d'=' -f2)
                local mem=""
                if [ "$pid" -ne 0 ]; then
                    mem=$(ps -p $pid -o rss= 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
                fi
                
                # Get connections count
                local conn_count=$(ss -tnp 2>/dev/null | grep "pid=$pid" | grep -c ESTABLISHED)
                
                echo -e "  ${GREEN}✓${NC} ${services[$service]} (PID: $pid, Mem: ${mem:-N/A}, Conns: $conn_count)"
            elif [ -f "/etc/systemd/system/$service" ]; then
                echo -e "  ${YELLOW}●${NC} ${services[$service]} (Stopped)"
            fi
        done
        
        # Network connections
        echo -e "\n${PURPLE}Recent Connections:${NC}"
        ss -tnp 2>/dev/null | grep -E 'ESTABLISHED.*rtt|ESTABLISHED.*RTT' | head -10 | while read line; do
            local conn_info=$(echo "$line" | awk '{print $5, $6}')
            echo -e "  ${YELLOW}→${NC} $conn_info"
        done
        
        # Resource usage
        echo -e "\n${PURPLE}System Resources:${NC}"
        echo -n "CPU: "
        top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%s%% used", 100-$1}'
        echo ""
        
        local mem_used=$(free -m | awk '/^Mem:/ {printf "%.1f%%", $3/$2*100}')
        echo -e "Memory: ${mem_used} used"
        
        # RTT processes
        local rtt_procs=$(pgrep -c rtt)
        echo -e "RTT Processes: $rtt_procs"
        
        sleep $update_interval
    done
}

# Debug and troubleshooting
debug_tunnel() {
    echo -e "${RED}=== Debug & Troubleshooting ===${NC}"
    
    # 1. Check RTT installation
    echo -e "\n${CYAN}1. RTT Installation Check:${NC}"
    if command -v rtt &> /dev/null; then
        echo -e "${GREEN}✓ RTT found at: $(which rtt)${NC}"
        rtt --version
    else
        echo -e "${RED}✗ RTT not found!${NC}"
    fi
    
    # 2. Check service files
    echo -e "\n${CYAN}2. Service Files:${NC}"
    for service in tunnel lbtunnel custom_tunnel; do
        if [ -f "/etc/systemd/system/${service}.service" ]; then
            echo -e "${GREEN}✓ ${service}.service exists${NC}"
            echo "  Command: $(grep ExecStart /etc/systemd/system/${service}.service)"
        else
            echo -e "${YELLOW}○ ${service}.service not found${NC}"
        fi
    done
    
    # 3. Service status
    echo -e "\n${CYAN}3. Service Status:${NC}"
    for service in tunnel lbtunnel custom_tunnel; do
        if systemctl is-enabled ${service}.service 2>/dev/null; then
            echo -n "${service}: "
            if systemctl is-active ${service}.service; then
                echo -e "${GREEN}ACTIVE${NC}"
                
                # Show logs
                echo -e "  Last 5 log lines:"
                tail -5 $LOG_DIR/${service}.log 2>/dev/null || echo "    No log file"
            else
                echo -e "${RED}INACTIVE${NC}"
                
                # Show error logs
                echo -e "  Last 5 error lines:"
                tail -5 $LOG_DIR/${service}.error.log 2>/dev/null || echo "    No error log"
            fi
        fi
    done
    
    # 4. Network check
    echo -e "\n${CYAN}4. Network Status:${NC}"
    
    # Listening ports
    echo -e "Listening ports (RTT related):"
    ss -tulpn 2>/dev/null | grep -E 'rtt|RTT' || echo "  None"
    
    # Active connections
    echo -e "\nActive RTT connections:"
    ss -tnp 2>/dev/null | grep -E 'rtt|RTT' | head -5 || echo "  None"
    
    # 5. System logs
    echo -e "\n${CYAN}5. System Journal (last 10 lines):${NC}"
    journalctl -u tunnel.service -u lbtunnel.service -n 10 --no-pager 2>/dev/null || echo "  No journal entries"
    
    # 6. Port conflicts
    echo -e "\n${CYAN}6. Port Conflict Check:${NC}"
    for port_range in "20000-25000" "10000-11000" "443"; do
        if [[ $port_range =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            for port in $(seq $start $end); do
                if lsof -i :$port >/dev/null 2>&1; then
                    local process=$(lsof -i :$port | awk 'NR==2 {print $1}')
                    echo -e "${RED}  Port $port in use by $process${NC}"
                    break
                fi
            done
        fi
    done
    
    echo -e "\n${GREEN}Debug check completed!${NC}"
    echo -e "${YELLOW}Check the logs in $LOG_DIR/ for more details${NC}"
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
    echo "5) Check Service Logs"
    
    read -p "Select option [1-5]: " svc_choice
    
    if [ "$svc_choice" = "5" ]; then
        # Show logs
        echo "Select service to view logs:"
        echo "1) tunnel.service"
        echo "2) lbtunnel.service"
        echo "3) custom_tunnel.service"
        read -p "Choice [1-3]: " log_choice
        
        case $log_choice in
            1) service="tunnel" ;;
            2) service="lbtunnel" ;;
            3) service="custom_tunnel" ;;
            *) return 1 ;;
        esac
        
        echo -e "${CYAN}=== Last 50 lines of $service.log ===${NC}"
        tail -50 $LOG_DIR/${service}.log 2>/dev/null || echo "No log file found"
        
        echo -e "\n${CYAN}=== Error log ===${NC}"
        tail -20 $LOG_DIR/${service}.error.log 2>/dev/null || echo "No error log found"
        
        return 0
    fi
    
    read -p "Action: [1] Start [2] Stop [3] Restart [4] Status: " action
    
    case $action in
        1) cmd="start" ;;
        2) cmd="stop" ;;
        3) cmd="restart" ;;
        4) cmd="status" ;;
        *) 
            echo -e "${RED}Invalid action!${NC}"
            return 1
            ;;
    esac
    
    if [ "$svc_choice" = "4" ]; then
        for svc in "${services[@]}"; do
            if [ -f "/etc/systemd/system/$svc" ]; then
                echo -e "\n${YELLOW}$cmd $svc...${NC}"
                systemctl $cmd $svc 2>&1 | tail -5
            fi
        done
    else
        svc=${services[$svc_choice]}
        if [ -n "$svc" ] && [ -f "/etc/systemd/system/$svc" ]; then
            echo -e "${YELLOW}$cmd $svc...${NC}"
            if [ "$cmd" = "status" ]; then
                systemctl $cmd $svc --no-pager -l
            else
                systemctl $cmd $svc
                sleep 2
                systemctl status $svc --no-pager -l | head -20
            fi
        else
            echo -e "${RED}Service not found!${NC}"
        fi
    fi
}

# Uninstall services
uninstall_menu() {
    echo -e "${RED}=== Uninstall ===${NC}"
    echo "1) Uninstall Multiport Tunnel"
    echo "2) Uninstall Load Balancer"
    echo "3) Uninstall Custom Tunnel"
    echo "4) Uninstall All Services"
    echo "5) Uninstall RTT Binary Only"
    
    read -p "Select option [1-5]: " choice
    
    case $choice in
        1) 
            echo -e "${YELLOW}Uninstalling Multiport Tunnel...${NC}"
            systemctl stop tunnel.service 2>/dev/null
            systemctl disable tunnel.service 2>/dev/null
            rm -f /etc/systemd/system/tunnel.service
            echo -e "${GREEN}Multiport Tunnel uninstalled!${NC}"
            ;;
        2)
            echo -e "${YELLOW}Uninstalling Load Balancer...${NC}"
            systemctl stop lbtunnel.service 2>/dev/null
            systemctl disable lbtunnel.service 2>/dev/null
            rm -f /etc/systemd/system/lbtunnel.service
            echo -e "${GREEN}Load Balancer uninstalled!${NC}"
            ;;
        3)
            echo -e "${YELLOW}Uninstalling Custom Tunnel...${NC}"
            systemctl stop custom_tunnel.service 2>/dev/null
            systemctl disable custom_tunnel.service 2>/dev/null
            rm -f /etc/systemd/system/custom_tunnel.service
            echo -e "${GREEN}Custom Tunnel uninstalled!${NC}"
            ;;
        4)
            echo -e "${YELLOW}Uninstalling all services...${NC}"
            for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
                systemctl stop $svc 2>/dev/null
                systemctl disable $svc 2>/dev/null
                rm -f /etc/systemd/system/$svc
            done
            rm -rf $TUNNEL_DIR
            echo -e "${GREEN}All services uninstalled!${NC}"
            ;;
        5)
            echo -e "${YELLOW}Uninstalling RTT binary...${NC}"
            rm -f /usr/local/bin/rtt /usr/local/bin/RTT
            rm -f /usr/bin/rtt /usr/bin/RTT
            echo -e "${GREEN}RTT binary uninstalled!${NC}"
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            return 1
            ;;
    esac
    
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null
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
    local sni=$(echo $custom_args | grep -oE '--sni:[^ ]+' | cut -d':' -f2)
    [ -z "$sni" ] && sni="custom"
    
    # Extract ports for checking
    local port=$(echo $custom_args | grep -oE '--lport:[0-9-]+' | cut -d':' -f2)
    if [ -n "$port" ]; then
        check_ports "$port" "custom_tunnel" || return 1
    fi
    
    echo -e "${CYAN}Configuration:${NC}"
    echo -e "${YELLOW}rtt $custom_args${NC}"
    echo ""
    
    read -p "Proceed with installation? [Y/n]: " confirm
    if [[ $confirm =~ ^[Nn]$ ]]; then
        return 0
    fi
    
    # Install RTT if needed
    if ! command -v rtt &> /dev/null; then
        install_rtt
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    # Generate service file
    generate_service "custom_tunnel" "$custom_args" "Custom"
    
    # Start service
    systemctl daemon-reload
    systemctl enable custom_tunnel.service
    
    echo -e "${YELLOW}Starting custom tunnel...${NC}"
    systemctl start custom_tunnel.service
    
    sleep 3
    
    if systemctl is-active --quiet custom_tunnel.service; then
        echo -e "${GREEN}Custom tunnel installed successfully!${NC}"
        echo -e "${YELLOW}SNI: $sni${NC}"
        echo -e "${YELLOW}Logs: $LOG_DIR/custom_tunnel.log${NC}"
        
        echo -e "\n${CYAN}Service Status:${NC}"
        systemctl status custom_tunnel.service --no-pager -l | head -30
    else
        echo -e "${RED}Failed to start custom tunnel!${NC}"
        journalctl -u custom_tunnel.service -n 20 --no-pager
        return 1
    fi
}

# Installation test
test_installation() {
    echo -e "${GREEN}=== Test Installation ===${NC}"
    
    # Test RTT binary
    if command -v rtt &> /dev/null; then
        echo -e "${GREEN}✓ RTT binary test passed${NC}"
        rtt --version
    else
        echo -e "${RED}✗ RTT binary not found!${NC}"
    fi
    
    # Test ports
    echo -e "\n${YELLOW}Testing common ports...${NC}"
    for port in 443 80 20000 10000; do
        if lsof -i :$port >/dev/null 2>&1; then
            echo -e "${RED}✗ Port $port is in use${NC}"
        else
            echo -e "${GREEN}✓ Port $port is available${NC}"
        fi
    done
    
    # Test internet connectivity
    echo -e "\n${YELLOW}Testing internet connectivity...${NC}"
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Internet connectivity OK${NC}"
    else
        echo -e "${RED}✗ No internet connectivity${NC}"
    fi
    
    # Test GitHub access
    echo -e "\n${YELLOW}Testing GitHub access...${NC}"
    if curl -s --connect-timeout 5 https://github.com >/dev/null; then
        echo -e "${GREEN}✓ GitHub access OK${NC}"
    else
        echo -e "${RED}✗ Cannot access GitHub${NC}"
    fi
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
        echo -e "${CYAN}5) Service Control${NC}"
        echo -e "${CYAN}6) Change SNI${NC}"
        echo -e "${YELLOW}7) Update RTT${NC}"
        echo -e "${YELLOW}8) Performance Optimization${NC}"
        echo -e "${BLUE}9) Real-time Monitor${NC}"
        echo -e "${PURPLE}10) Debug & Troubleshoot${NC}"
        echo -e "${WHITE}11) Test Installation${NC}"
        echo -e "${WHITE}0) Exit${NC}"
        
        echo -e "\n${PURPLE}Protocol Support:${NC} TLS | TCPMUX | KCP | WebSocket"
        
        read -p "Select option [0-11]: " choice
        
        case $choice in
            1) 
                install_multiport
                read -p "Press Enter to continue..."
                ;;
            2) 
                install_loadbalancer
                read -p "Press Enter to continue..."
                ;;
            3) 
                install_custom_tunnel
                read -p "Press Enter to continue..."
                ;;
            4) 
                uninstall_menu
                read -p "Press Enter to continue..."
                ;;
            5) 
                service_control_menu
                read -p "Press Enter to continue..."
                ;;
            6) 
                change_sni
                read -p "Press Enter to continue..."
                ;;
            7) 
                update_rtt
                read -p "Press Enter to continue..."
                ;;
            8) 
                optimize_performance
                read -p "Press Enter to continue..."
                ;;
            9) 
                monitor_tunnel
                ;;
            10) 
                debug_tunnel
                read -p "Press Enter to continue..."
                ;;
            11) 
                test_installation
                read -p "Press Enter to continue..."
                ;;
            0) 
                echo -e "${GREEN}Goodbye!${NC}"
                echo -e "${YELLOW}For support visit: https://github.com/Ptechgithub${NC}"
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

# Main execution
if [ "$0" = "$BASH_SOURCE" ]; then
    init_setup
    main_menu
fi
