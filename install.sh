#!/bin/bash

# Advanced One-Click Installer for Radkesvat Tunnel
# Version: 2.0 Enhanced
# Author: Peyman
# GitHub: https://github.com/parhampahlevann/radkesvat

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

# Configuration
TUNNEL_DIR="/etc/radkesvat"
CONFIG_FILE="$TUNNEL_DIR/config.json"
LOG_FILE="$TUNNEL_DIR/install.log"
VERSION="2.0"
REPO_URL="https://github.com/parhampahlevann/radkesvat"

# Banner
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     Radkesvat Tunnel - One Click Installer               ║"
    echo "║     Advanced Reverse TLS Tunnel with Multi-Protocol      ║"
    echo "║     Version: $VERSION                                    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}📦 Repository: $REPO_URL${NC}"
    echo -e "${YELLOW}📅 Date: $(date)${NC}"
    echo ""
}

# Logging function
log_message() {
    local message="$1"
    local level="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case $level in
        "INFO") echo -e "${GREEN}[✓] $message${NC}" ;;
        "WARN") echo -e "${YELLOW}[!] $message${NC}" ;;
        "ERROR") echo -e "${RED}[✗] $message${NC}" ;;
        "STEP") echo -e "${BLUE}[→] $message${NC}" ;;
        *) echo -e "${WHITE}[*] $message${NC}" ;;
    esac
}

# Check root access
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "This script must be run as root" "ERROR"
        log_message "Use: sudo bash install.sh" "INFO"
        exit 1
    fi
    log_message "Root access confirmed" "INFO"
}

# Detect OS and architecture
detect_system() {
    log_message "Detecting system information..." "STEP"
    
    # OS detection
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
        OS_ID=$ID
    else
        OS=$(uname -s)
        OS_VERSION=$(uname -r)
    fi
    
    # Architecture detection
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        armv6l) ARCH="armv6" ;;
        i386|i686) ARCH="386" ;;
        *) ARCH="unknown" ;;
    esac
    
    # Package manager
    case $OS_ID in
        ubuntu|debian) PKG_MANAGER="apt-get" ;;
        centos|rhel|fedora|rocky|almalinux) 
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro) PKG_MANAGER="pacman" ;;
        opensuse*) PKG_MANAGER="zypper" ;;
        *) PKG_MANAGER="apt-get" ;;
    esac
    
    log_message "OS: $OS $OS_VERSION" "INFO"
    log_message "Architecture: $ARCH" "INFO"
    log_message "Package Manager: $PKG_MANAGER" "INFO"
}

# Install dependencies
install_dependencies() {
    log_message "Installing required dependencies..." "STEP"
    
    # Update package list
    $PKG_MANAGER update -y 2>>"$LOG_FILE"
    
    # Basic dependencies
    local basic_deps=("wget" "curl" "git" "unzip" "tar" "gzip" "lsof" "net-tools")
    
    for dep in "${basic_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log_message "Installing $dep..." "INFO"
            $PKG_MANAGER install -y "$dep" 2>>"$LOG_FILE"
        fi
    done
    
    # Additional tools for tunnel
    local extra_deps=("jq" "socat" "screen" "htop" "iftop" "nload")
    
    for extra in "${extra_deps[@]}"; do
        if ! command -v "$extra" &>/dev/null; then
            log_message "Installing $extra (optional)..." "INFO"
            $PKG_MANAGER install -y "$extra" 2>>"$LOG_FILE" || true
        fi
    done
    
    log_message "Dependencies installed successfully" "INFO"
}

# Create directory structure
create_directories() {
    log_message "Creating directory structure..." "STEP"
    
    mkdir -p "$TUNNEL_DIR" 2>>"$LOG_FILE"
    mkdir -p "$TUNNEL_DIR/logs" 2>>"$LOG_FILE"
    mkdir -p "$TUNNEL_DIR/configs" 2>>"$LOG_FILE"
    mkdir -p "$TUNNEL_DIR/backups" 2>>"$LOG_FILE"
    mkdir -p "$TUNNEL_DIR/scripts" 2>>"$LOG_FILE"
    
    chmod 700 "$TUNNEL_DIR"
    log_message "Directories created in $TUNNEL_DIR" "INFO"
}

# Download and install RTT
install_rtt() {
    log_message "Downloading Reverse TLS Tunnel..." "STEP"
    
    local version="7.1"  # Default version
    local download_url=""
    
    # Determine download URL based on architecture
    case $ARCH in
        amd64)
            download_url="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V7.1/v7.1_linux_amd64.zip"
            ;;
        arm64)
            download_url="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V7.1/v7.1_linux_arm64.zip"
            ;;
        armv7)
            download_url="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V7.1/v7.1_linux_arm.zip"
            ;;
        *)
            log_message "Unsupported architecture: $ARCH" "ERROR"
            exit 1
            ;;
    esac
    
    # Download RTT
    log_message "Downloading from: $download_url" "INFO"
    wget -q --show-progress -O /tmp/rtt.zip "$download_url" 2>>"$LOG_FILE"
    
    if [ $? -ne 0 ]; then
        log_message "Failed to download RTT" "ERROR"
        exit 1
    fi
    
    # Extract and install
    log_message "Extracting files..." "INFO"
    unzip -o /tmp/rtt.zip -d /usr/local/bin/ 2>>"$LOG_FILE"
    
    # Make executable
    chmod +x /usr/local/bin/RTT 2>>"$LOG_FILE"
    ln -sf /usr/local/bin/RTT /usr/bin/rtt 2>>"$LOG_FILE"
    ln -sf /usr/local/bin/RTT /usr/bin/radkesvat 2>>"$LOG_FILE"
    
    # Cleanup
    rm -f /tmp/rtt.zip 2>>"$LOG_FILE"
    
    # Verify installation
    if command -v rtt &>/dev/null; then
        local installed_version=$(rtt -v 2>&1 | grep -o 'version="[^"]*"' | cut -d'"' -f2)
        log_message "RTT installed successfully! Version: $installed_version" "INFO"
    else
        log_message "RTT installation failed" "ERROR"
        exit 1
    fi
}

# Configure firewall
configure_firewall() {
    log_message "Configuring firewall rules..." "STEP"
    
    # Detect firewall type
    if command -v ufw &>/dev/null; then
        # UFW (Ubuntu)
        ufw allow 22/tcp comment "SSH"
        ufw allow 443/tcp comment "Tunnel SSL"
        ufw allow 80/tcp comment "Tunnel HTTP"
        ufw allow 20000:30000/tcp comment "Tunnel Port Range"
        ufw --force enable 2>>"$LOG_FILE"
        log_message "UFW firewall configured" "INFO"
        
    elif command -v firewall-cmd &>/dev/null; then
        # FirewallD (CentOS/Fedora)
        firewall-cmd --permanent --add-port=22/tcp
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=20000-30000/tcp
        firewall-cmd --reload 2>>"$LOG_FILE"
        log_message "FirewallD configured" "INFO"
        
    elif command -v iptables &>/dev/null; then
        # iptables
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 20000:30000 -j ACCEPT
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        log_message "iptables configured" "INFO"
    fi
    
    # Save iptables rules for persistence
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables 2>/dev/null
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# Optimize system settings
optimize_system() {
    log_message "Optimizing system settings for tunnel..." "STEP"
    
    # Create sysctl optimization file
    cat > /etc/sysctl.d/99-radkesvat-optimize.conf << EOF
# Radkesvat Tunnel Optimizations
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
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152
EOF
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-radkesvat-optimize.conf 2>>"$LOG_FILE"
    
    # Increase file limits
    cat > /etc/security/limits.d/99-radkesvat.conf << EOF
* soft nofile 102400
* hard nofile 102400
root soft nofile 102400
root hard nofile 102400
EOF
    
    # Increase system limits
    echo "DefaultLimitNOFILE=102400" >> /etc/systemd/system.conf
    echo "DefaultLimitNPROC=102400" >> /etc/systemd/system.conf
    
    log_message "System optimizations applied" "INFO"
}

# Create management script
create_management_script() {
    log_message "Creating management scripts..." "STEP"
    
    # Main management script
    cat > /usr/local/bin/radkesvat-manager << 'EOF'
#!/bin/bash

# Radkesvat Tunnel Manager
# Version: 2.0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="/etc/radkesvat"
LOG_DIR="$CONFIG_DIR/logs"

show_menu() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════╗"
    echo "║      Radkesvat Tunnel Manager        ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${GREEN}1) Start Tunnel${NC}"
    echo -e "${GREEN}2) Stop Tunnel${NC}"
    echo -e "${GREEN}3) Restart Tunnel${NC}"
    echo -e "${GREEN}4) Check Status${NC}"
    echo -e "${YELLOW}5) View Logs${NC}"
    echo -e "${YELLOW}6) Edit Configuration${NC}"
    echo -e "${BLUE}7) Update Tunnel${NC}"
    echo -e "${RED}8) Uninstall${NC}"
    echo -e "${RED}0) Exit${NC}"
    echo ""
}

check_status() {
    if pgrep -x "RTT" >/dev/null; then
        echo -e "${GREEN}[✓] Tunnel is running${NC}"
        ss -tulpn | grep RTT
    else
        echo -e "${RED}[✗] Tunnel is not running${NC}"
    fi
}

case "$1" in
    start)
        systemctl start radkesvat-tunnel 2>/dev/null || echo "Starting tunnel..."
        ;;
    stop)
        systemctl stop radkesvat-tunnel 2>/dev/null || pkill -f RTT
        ;;
    restart)
        systemctl restart radkesvat-tunnel 2>/dev/null || (pkill -f RTT && sleep 2 && echo "Restarting...")
        ;;
    status)
        check_status
        ;;
    logs)
        tail -f $LOG_DIR/tunnel.log
        ;;
    *)
        while true; do
            show_menu
            read -p "Select option: " choice
            
            case $choice in
                1)
                    echo "Starting tunnel..."
                    systemctl start radkesvat-tunnel 2>/dev/null || nohup rtt &
                    sleep 2
                    check_status
                    ;;
                2)
                    echo "Stopping tunnel..."
                    systemctl stop radkesvat-tunnel 2>/dev/null || pkill -f RTT
                    sleep 1
                    check_status
                    ;;
                3)
                    echo "Restarting tunnel..."
                    systemctl restart radkesvat-tunnel 2>/dev/null || (pkill -f RTT && sleep 2 && nohup rtt &)
                    sleep 2
                    check_status
                    ;;
                4)
                    check_status
                    ;;
                5)
                    tail -50 $LOG_DIR/tunnel.log
                    read -p "Press Enter to continue..."
                    ;;
                6)
                    nano $CONFIG_DIR/config.json 2>/dev/null || vi $CONFIG_DIR/config.json
                    ;;
                7)
                    echo "Updating tunnel..."
                    bash <(curl -sL https://raw.githubusercontent.com/parhampahlevann/radkesvat/main/install.sh)
                    ;;
                8)
                    read -p "Are you sure? (y/N): " confirm
                    if [[ $confirm == "y" || $confirm == "Y" ]]; then
                        /etc/radkesvat/scripts/uninstall.sh
                    fi
                    ;;
                0)
                    echo "Goodbye!"
                    exit 0
                    ;;
                *)
                    echo "Invalid option!"
                    ;;
            esac
            
            read -p "Press Enter to continue..."
        done
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/radkesvat-manager
    ln -sf /usr/local/bin/radkesvat-manager /usr/bin/radkesvat-mgr
    
    # Create uninstall script
    cat > "$TUNNEL_DIR/scripts/uninstall.sh" << 'EOF'
#!/bin/bash

# Radkesvat Tunnel Uninstaller

echo "Uninstalling Radkesvat Tunnel..."
echo ""

# Stop services
systemctl stop radkesvat-tunnel 2>/dev/null
systemctl disable radkesvat-tunnel 2>/dev/null

# Remove systemd service
rm -f /etc/systemd/system/radkesvat-tunnel.service

# Remove binaries
rm -f /usr/local/bin/RTT
rm -f /usr/bin/rtt
rm -f /usr/bin/radkesvat
rm -f /usr/local/bin/radkesvat-manager
rm -f /usr/bin/radkesvat-mgr

# Remove config directory (ask for confirmation)
read -p "Remove configuration directory (/etc/radkesvat)? (y/N): " remove_config
if [[ $remove_config == "y" || $remove_config == "Y" ]]; then
    rm -rf /etc/radkesvat
    echo "Configuration directory removed."
fi

# Reload systemd
systemctl daemon-reload
systemctl reset-failed

echo ""
echo "Radkesvat Tunnel has been uninstalled!"
echo "Some log files may remain in /var/log/"
EOF
    
    chmod +x "$TUNNEL_DIR/scripts/uninstall.sh"
    
    log_message "Management scripts created" "INFO"
}

# Create systemd service
create_systemd_service() {
    log_message "Creating systemd service..." "STEP"
    
    cat > /etc/systemd/system/radkesvat-tunnel.service << EOF
[Unit]
Description=Radkesvat Reverse TLS Tunnel
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/rtt --iran --lport:20000-30000 --sni:cloudflare.com --password:defaultpass --terminate:24
Restart=always
RestartSec=5
StartLimitInterval=0
LimitNOFILE=102400
LimitNPROC=102400
StandardOutput=append:/etc/radkesvat/logs/tunnel.log
StandardError=append:/etc/radkesvat/logs/tunnel-error.log

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc/radkesvat

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    systemctl enable radkesvat-tunnel.service 2>>"$LOG_FILE"
    
    log_message "Systemd service created and enabled" "INFO"
}

# Create configuration file
create_configuration() {
    log_message "Creating configuration file..." "STEP"
    
    cat > "$CONFIG_FILE" << EOF
{
    "version": "$VERSION",
    "install_date": "$(date)",
    "system": {
        "os": "$OS",
        "arch": "$ARCH",
        "package_manager": "$PKG_MANAGER"
    },
    "tunnel": {
        "default_sni": "cloudflare.com",
        "port_range": "20000-30000",
        "terminate_time": 24,
        "protocols": ["tls", "tcp", "kcp", "websocket"],
        "log_level": "info"
    },
    "paths": {
        "config_dir": "$TUNNEL_DIR",
        "log_dir": "$TUNNEL_DIR/logs",
        "backup_dir": "$TUNNEL_DIR/backups"
    }
}
EOF
    
    log_message "Configuration file created: $CONFIG_FILE" "INFO"
}

# Post-installation instructions
show_instructions() {
    log_message "Installation completed successfully!" "INFO"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}🎉 Radkesvat Tunnel Installation Complete!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}📁 Installation Directory:${NC} $TUNNEL_DIR"
    echo -e "${CYAN}📝 Configuration File:${NC} $CONFIG_FILE"
    echo -e "${CYAN}📊 Log Files:${NC} $TUNNEL_DIR/logs/"
    echo ""
    echo -e "${YELLOW}🚀 Available Commands:${NC}"
    echo -e "  ${GREEN}radkesvat-manager${NC}   - Launch management menu"
    echo -e "  ${GREEN}radkesvat-mgr${NC}       - Shortcut for manager"
    echo -e "  ${GREEN}rtt${NC}                 - Run tunnel directly"
    echo ""
    echo -e "${BLUE}📖 Quick Start:${NC}"
    echo -e "  1. Edit configuration: ${GREEN}nano $CONFIG_FILE${NC}"
    echo -e "  2. Start tunnel: ${GREEN}systemctl start radkesvat-tunnel${NC}"
    echo -e "  3. Check status: ${GREEN}systemctl status radkesvat-tunnel${NC}"
    echo ""
    echo -e "${PURPLE}🔗 Documentation:${NC}"
    echo -e "  GitHub: https://github.com/parhampahlevann/radkesvat"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    
    # Save installation info
    echo "Installation completed on: $(date)" >> "$TUNNEL_DIR/install.info"
    echo "Version: $VERSION" >> "$TUNNEL_DIR/install.info"
    echo "OS: $OS $OS_VERSION" >> "$TUNNEL_DIR/install.info"
    echo "Architecture: $ARCH" >> "$TUNNEL_DIR/install.info"
}

# Main installation function
main_installation() {
    print_banner
    
    log_message "Starting Radkesvat Tunnel installation..." "STEP"
    log_message "Version: $VERSION" "INFO"
    log_message "Log file: $LOG_FILE" "INFO"
    
    # Step-by-step installation
    check_root
    detect_system
    install_dependencies
    create_directories
    install_rtt
    configure_firewall
    optimize_system
    create_management_script
    create_systemd_service
    create_configuration
    
    # Start the service
    log_message "Starting tunnel service..." "STEP"
    systemctl start radkesvat-tunnel.service 2>>"$LOG_FILE"
    
    # Show completion message
    show_instructions
    
    log_message "Installation process completed" "INFO"
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    
    # Run main installation
    main_installation
fi
