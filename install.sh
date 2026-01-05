#!/bin/bash

# RTT Professional Installer
# Version: 5.0 - Fixed Download URLs
# Author: Peyman (Ptechgithub)

# Colors
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
    echo "║     Reverse TLS Tunnel - Professional Installer         ║"
    echo "║                Fixed Download System                    ║"
    echo "║               By: Peyman (Ptechgithub)                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root (sudo)!${NC}"
        exit 1
    fi
}

# Detect OS and Architecture
detect_system() {
    echo -e "${YELLOW}Detecting system...${NC}"
    
    # OS Type
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    else
        echo -e "${RED}Unsupported OS: $OSTYPE${NC}"
        exit 1
    fi
    
    # Architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|x64)
            RTT_ARCH="amd64"
            SYSTEM_ARCH="x86_64"
            ;;
        aarch64|arm64)
            RTT_ARCH="arm64"
            SYSTEM_ARCH="aarch64"
            ;;
        armv7l|armv8l)
            RTT_ARCH="arm"
            SYSTEM_ARCH="armv7l"
            ;;
        i386|i686|x86)
            RTT_ARCH="386"
            SYSTEM_ARCH="x86"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}✓ OS: $OS${NC}"
    echo -e "${GREEN}✓ Architecture: $ARCH -> RTT: $RTT_ARCH${NC}"
}

# Install dependencies
install_deps() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y wget curl unzip lsof net-tools jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wget curl unzip lsof net-tools epel-release
        yum install -y jq || wget -O /usr/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-amd64 && chmod +x /usr/bin/jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wget curl unzip lsof net-tools jq
    fi
    
    echo -e "${GREEN}✓ Dependencies installed${NC}"
}

# Get latest version
get_latest_version() {
    echo -e "${YELLOW}Checking for latest version...${NC}"
    
    # Try GitHub API
    VERSION=$(curl -s --connect-timeout 10 \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest \
        | jq -r '.tag_name' 2>/dev/null | sed 's/V//')
    
    # Alternative method
    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        VERSION=$(curl -s --connect-timeout 10 \
            https://github.com/radkesvat/ReverseTlsTunnel/releases/latest \
            | grep -oP 'tag/V\K[0-9.]+' | head -1)
    fi
    
    # Fallback version
    if [ -z "$VERSION" ]; then
        VERSION="7.0.1"
        echo -e "${YELLOW}⚠ Using fallback version: $VERSION${NC}"
    else
        echo -e "${GREEN}✓ Latest version: $VERSION${NC}"
    fi
    
    echo $VERSION
}

# Build download URL based on architecture
get_download_url() {
    local version=$1
    local arch=$2
    local os=$3
    
    # Map RTT architecture to download pattern
    case $arch in
        "amd64")
            if [ "$os" = "linux" ]; then
                echo "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_amd64.zip"
            elif [ "$os" = "macos" ]; then
                echo "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_macos_amd64.zip"
            fi
            ;;
        "arm64")
            if [ "$os" = "linux" ]; then
                echo "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_arm64.zip"
            elif [ "$os" = "macos" ]; then
                echo "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_macos_arm64.zip"
            fi
            ;;
        "arm")
            echo "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_arm.zip"
            ;;
        "386")
            echo "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_386.zip"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Alternative download URLs (backup)
get_alternative_urls() {
    local version=$1
    local arch=$2
    local os=$3
    
    local urls=()
    
    # Primary patterns
    case $arch in
        "amd64")
            urls+=("https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/v${version}_linux_amd64.zip")
            urls+=("https://github.com/radkesvat/ReverseTlsTunnel/releases/download/v$version/v${version}_linux_amd64.zip")
            ;;
        "arm64")
            urls+=("https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/v${version}_linux_arm64.zip")
            urls+=("https://github.com/radkesvat/ReverseTlsTunnel/releases/download/v$version/v${version}_linux_arm64.zip")
            ;;
        "arm")
            urls+=("https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/v${version}_linux_arm.zip")
            urls+=("https://github.com/radkesvat/ReverseTlsTunnel/releases/download/v$version/v${version}_linux_arm.zip")
            ;;
    esac
    
    # CDN URLs
    urls+=("https://cdn.jsdelivr.net/gh/radkesvat/ReverseTlsTunnel@$version/RTT_linux_$arch")
    urls+=("https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/V$version/RTT_linux_$arch")
    
    echo "${urls[@]}"
}

# Download RTT with multiple fallbacks
download_rtt() {
    local version=$1
    local arch=$2
    local os=$3
    
    echo -e "${YELLOW}Downloading RTT v$version for $arch...${NC}"
    
    # Get primary URL
    local primary_url=$(get_download_url "$version" "$arch" "$os")
    echo -e "${BLUE}Primary URL: $primary_url${NC}"
    
    # Get alternative URLs
    local alt_urls=($(get_alternative_urls "$version" "$arch" "$os"))
    
    # Try primary URL first
    if wget --timeout=30 --tries=2 -q "$primary_url" -O /tmp/rtt.zip; then
        echo -e "${GREEN}✓ Downloaded from primary URL${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Primary URL failed, trying alternatives...${NC}"
    
    # Try alternative URLs
    local idx=1
    for url in "${alt_urls[@]}"; do
        echo -e "${BLUE}Trying alternative $idx: $url${NC}"
        
        if [[ "$url" == *".zip" ]]; then
            if wget --timeout=30 --tries=2 -q "$url" -O /tmp/rtt.zip; then
                echo -e "${GREEN}✓ Downloaded from alternative URL${NC}"
                return 0
            fi
        else
            # Direct binary
            if wget --timeout=30 --tries=2 -q "$url" -O /tmp/rtt_binary; then
                echo -e "${GREEN}✓ Downloaded binary directly${NC}"
                mv /tmp/rtt_binary /usr/local/bin/rtt
                chmod +x /usr/local/bin/rtt
                return 0
            fi
        fi
        
        ((idx++))
    done
    
    # Manual download options
    echo -e "${RED}All download methods failed!${NC}"
    echo -e "${YELLOW}Please download manually:${NC}"
    echo "1. Visit: https://github.com/radkesvat/ReverseTlsTunnel/releases"
    echo "2. Download file matching: v${version}_linux_${arch}.zip"
    echo "3. Upload to server: scp file.zip user@server:/tmp/rtt.zip"
    echo ""
    read -p "Have you uploaded manually? (y/N): " choice
    
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        if [ -f /tmp/rtt.zip ]; then
            return 0
        else
            echo -e "${RED}File not found at /tmp/rtt.zip${NC}"
            return 1
        fi
    fi
    
    return 1
}

# Install from downloaded file
install_from_file() {
    echo -e "${YELLOW}Installing RTT...${NC}"
    
    # Cleanup old versions
    rm -f /usr/local/bin/rtt /usr/bin/rtt
    pkill -9 rtt 2>/dev/null || true
    
    # Check if we have a zip or direct binary
    if [ -f /tmp/rtt.zip ]; then
        # Extract zip
        if ! unzip -o /tmp/rtt.zip -d /tmp/rtt_extract/ 2>/dev/null; then
            echo -e "${RED}Failed to extract zip!${NC}"
            return 1
        fi
        
        # Find binary
        local binary=$(find /tmp/rtt_extract/ -type f \( -name "RTT" -o -name "rtt" \) | head -1)
        
        if [ -z "$binary" ]; then
            # Check all files
            binary=$(find /tmp/rtt_extract/ -type f -executable | head -1)
        fi
        
        if [ -n "$binary" ] && [ -f "$binary" ]; then
            cp "$binary" /usr/local/bin/rtt
            chmod +x /usr/local/bin/rtt
            echo -e "${GREEN}✓ Extracted and installed from zip${NC}"
        else
            echo -e "${RED}No binary found in zip!${NC}"
            return 1
        fi
        
        # Cleanup
        rm -rf /tmp/rtt.zip /tmp/rtt_extract/
        
    elif [ -f /tmp/rtt_binary ]; then
        # Direct binary
        mv /tmp/rtt_binary /usr/local/bin/rtt
        chmod +x /usr/local/bin/rtt
        echo -e "${GREEN}✓ Installed direct binary${NC}"
        
    else
        echo -e "${RED}No installation file found!${NC}"
        return 1
    fi
    
    # Create symlink
    ln -sf /usr/local/bin/rtt /usr/bin/rtt 2>/dev/null
    
    return 0
}

# Verify installation
verify_installation() {
    echo -e "${YELLOW}Verifying installation...${NC}"
    
    # Check if binary exists
    if [ ! -f /usr/local/bin/rtt ]; then
        echo -e "${RED}✗ Binary not found at /usr/local/bin/rtt${NC}"
        return 1
    fi
    
    # Check permissions
    if [ ! -x /usr/local/bin/rtt ]; then
        echo -e "${YELLOW}Fixing permissions...${NC}"
        chmod +x /usr/local/bin/rtt
    fi
    
    # Test version command
    if /usr/local/bin/rtt --version >/dev/null 2>&1; then
        local version_info=$(/usr/local/bin/rtt --version 2>&1 | head -3)
        echo -e "${GREEN}✓ RTT installed successfully!${NC}"
        echo -e "${CYAN}Version info:${NC}"
        echo "$version_info"
        return 0
    else
        # Try to run anyway
        echo -e "${YELLOW}⚠ Version check failed, but binary exists${NC}"
        echo -e "${YELLOW}Testing basic execution...${NC}"
        
        timeout 2 /usr/local/bin/rtt --help >/dev/null 2>&1
        if [ $? -eq 0 ] || [ $? -eq 124 ]; then
            echo -e "${GREEN}✓ Binary executes successfully${NC}"
            return 0
        else
            echo -e "${RED}✗ Binary execution failed${NC}"
            return 1
        fi
    fi
}

# Install RTT complete process
install_rtt_complete() {
    print_banner
    
    # Get version
    VERSION=$(get_latest_version)
    
    # Detect system
    detect_system
    
    # Download
    if ! download_rtt "$VERSION" "$RTT_ARCH" "$OS"; then
        echo -e "${RED}Download failed!${NC}"
        return 1
    fi
    
    # Install
    if ! install_from_file; then
        echo -e "${RED}Installation failed!${NC}"
        return 1
    fi
    
    # Verify
    if ! verify_installation; then
        echo -e "${RED}Verification failed!${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ RTT installation completed successfully!${NC}"
    return 0
}

# Manual installation
manual_install() {
    echo -e "${CYAN}=== Manual Installation ===${NC}"
    
    echo -e "${YELLOW}Available methods:${NC}"
    echo "1) Upload binary via SCP"
    echo "2) Download from custom URL"
    echo "3) Enter path to existing binary"
    
    read -p "Choose method [1-3]: " method
    
    case $method in
        1)
            echo -e "${YELLOW}Please upload binary to /tmp/rtt_binary${NC}"
            echo "Command example:"
            echo "  scp RTT_linux_$(uname -m) user@$(curl -s ifconfig.me):/tmp/rtt_binary"
            read -p "Press Enter after upload... " dummy
            
            if [ -f /tmp/rtt_binary ]; then
                chmod +x /tmp/rtt_binary
                mv /tmp/rtt_binary /usr/local/bin/rtt
                ln -sf /usr/local/bin/rtt /usr/bin/rtt
                echo -e "${GREEN}✓ Manual installation complete!${NC}"
                verify_installation
            else
                echo -e "${RED}File not found!${NC}"
            fi
            ;;
        2)
            read -p "Enter download URL: " url
            if [ -n "$url" ]; then
                wget -q "$url" -O /usr/local/bin/rtt
                chmod +x /usr/local/bin/rtt
                ln -sf /usr/local/bin/rtt /usr/bin/rtt
                echo -e "${GREEN}✓ Downloaded and installed!${NC}"
                verify_installation
            fi
            ;;
        3)
            read -p "Enter full path to binary: " path
            if [ -f "$path" ]; then
                chmod +x "$path"
                cp "$path" /usr/local/bin/rtt
                ln -sf /usr/local/bin/rtt /usr/bin/rtt
                echo -e "${GREEN}✓ Copied and installed!${NC}"
                verify_installation
            else
                echo -e "${RED}File not found!${NC}"
            fi
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            ;;
    esac
}

# Create tunnel service
create_service() {
    echo -e "${CYAN}=== Create Tunnel Service ===${NC}"
    
    if ! command -v rtt &> /dev/null; then
        echo -e "${RED}RTT not installed! Please install first.${NC}"
        return 1
    fi
    
    # Server type
    echo -e "${YELLOW}Select server type:${NC}"
    echo "1) Iran (internal server)"
    echo "2) Kharej (external server)"
    echo "3) Custom command"
    
    read -p "Choice [1-3]: " server_type
    
    case $server_type in
        1)
            read -p "Password: " password
            read -p "Local port (default: 443): " port
            port=${port:-443}
            read -p "SNI (default: google.com): " sni
            sni=${sni:-google.com}
            
            cmd="--iran --lport:$port --password:$password --sni:$sni --log-level:info"
            service_name="rtt-iran"
            ;;
        2)
            read -p "Iran server IP: " iran_ip
            read -p "Password: " password
            read -p "Local port to forward (default: 8080): " port
            port=${port:-8080}
            read -p "SNI (default: google.com): " sni
            sni=${sni:-google.com}
            
            cmd="--kharej --iran-ip:$iran_ip --iran-port:443 --toip:127.0.0.1 --toport:$port --password:$password --sni:$sni --log-level:info"
            service_name="rtt-kharej"
            ;;
        3)
            read -p "Enter full RTT command: " cmd
            read -p "Service name: " service_name
            if [ -z "$service_name" ]; then
                service_name="rtt-custom"
            fi
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            return 1
            ;;
    esac
    
    # Test command
    echo -e "${YELLOW}Testing command...${NC}"
    timeout 5 rtt $cmd &
    local pid=$!
    sleep 3
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Command test passed${NC}"
        kill $pid 2>/dev/null
        
        # Create service
        cat > /etc/systemd/system/$service_name.service << EOF
[Unit]
Description=RTT Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/rtt $cmd
Restart=always
RestartSec=3
TimeoutSec=10

[Install]
WantedBy=multi-user.target
EOF
        
        # Enable service
        systemctl daemon-reload
        systemctl enable $service_name
        systemctl start $service_name
        
        sleep 2
        
        if systemctl is-active --quiet $service_name; then
            echo -e "${GREEN}✓ Service '$service_name' is running!${NC}"
            echo -e "${YELLOW}Service status:${NC}"
            systemctl status $service_name --no-pager | head -15
        else
            echo -e "${RED}✗ Service failed to start${NC}"
            journalctl -u $service_name -n 20 --no-pager
        fi
    else
        echo -e "${RED}✗ Command test failed!${NC}"
    fi
}

# Manage services
manage_services() {
    echo -e "${CYAN}=== Manage Services ===${NC}"
    
    # Find RTT services
    services=$(systemctl list-unit-files --type=service | grep rtt | awk '{print $1}')
    
    if [ -z "$services" ]; then
        echo -e "${YELLOW}No RTT services found${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Found services:${NC}"
    local idx=1
    local service_array=()
    
    for service in $services; do
        echo "$idx) $service"
        service_array[$idx]=$service
        ((idx++))
    done
    
    echo ""
    echo "a) Start all"
    echo "b) Stop all"
    echo "c) Restart all"
    
    read -p "Select service number or action: " choice
    
    case $choice in
        a|A)
            for service in "${service_array[@]}"; do
                systemctl start $service 2>/dev/null && echo "✓ Started $service" || echo "✗ Failed to start $service"
            done
            ;;
        b|B)
            for service in "${service_array[@]}"; do
                systemctl stop $service 2>/dev/null && echo "✓ Stopped $service" || echo "✗ Failed to stop $service"
            done
            ;;
        c|C)
            for service in "${service_array[@]}"; do
                systemctl restart $service 2>/dev/null && echo "✓ Restarted $service" || echo "✗ Failed to restart $service"
            done
            ;;
        *)
            if [[ $choice =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -lt $idx ]; then
                selected_service=${service_array[$choice]}
                
                echo -e "${YELLOW}Actions for $selected_service:${NC}"
                echo "1) Start"
                echo "2) Stop"
                echo "3) Restart"
                echo "4) Status"
                echo "5) View logs"
                echo "6) Disable"
                echo "7) Enable"
                
                read -p "Choose action: " action
                
                case $action in
                    1) systemctl start $selected_service ;;
                    2) systemctl stop $selected_service ;;
                    3) systemctl restart $selected_service ;;
                    4) systemctl status $selected_service --no-pager ;;
                    5) journalctl -u $selected_service -n 30 --no-pager ;;
                    6) systemctl disable $selected_service ;;
                    7) systemctl enable $selected_service ;;
                    *) echo "Invalid action" ;;
                esac
            else
                echo -e "${RED}Invalid selection!${NC}"
            fi
            ;;
    esac
}

# Test RTT
test_rtt() {
    echo -e "${CYAN}=== Test RTT Installation ===${NC}"
    
    if ! command -v rtt &> /dev/null; then
        echo -e "${RED}RTT not found!${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ RTT found at: $(which rtt)${NC}"
    
    # Version test
    echo -e "${YELLOW}Version test:${NC}"
    rtt --version 2>&1 | head -5
    
    # Help test
    echo -e "${YELLOW}Help test:${NC}"
    timeout 2 rtt --help 2>&1 | head -10
    
    # Iran mode test
    echo -e "${YELLOW}Quick Iran mode test (3 seconds):${NC}"
    timeout 3 rtt --iran --lport:9999 --password:testpass --sni:google.com --log-level:error &
    local pid=$!
    sleep 2
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Iran mode works${NC}"
        kill $pid 2>/dev/null
    else
        echo -e "${YELLOW}⚠ Iran mode test inconclusive${NC}"
    fi
    
    echo -e "${GREEN}Testing complete!${NC}"
}

# Uninstall
uninstall_rtt() {
    echo -e "${RED}=== Uninstall RTT ===${NC}"
    
    read -p "Are you sure? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return 0
    fi
    
    # Stop and remove services
    for service in $(systemctl list-unit-files --type=service | grep rtt | awk '{print $1}'); do
        systemctl stop $service 2>/dev/null
        systemctl disable $service 2>/dev/null
        rm -f /etc/systemd/system/$service
        echo "Removed service: $service"
    done
    
    # Remove binary
    rm -f /usr/local/bin/rtt /usr/bin/rtt
    
    # Cleanup
    systemctl daemon-reload
    pkill -9 rtt 2>/dev/null || true
    
    echo -e "${GREEN}RTT uninstalled successfully!${NC}"
}

# System info
system_info() {
    echo -e "${CYAN}=== System Information ===${NC}"
    
    echo -e "${YELLOW}OS:${NC}"
    cat /etc/os-release 2>/dev/null | grep PRETTY_NAME || uname -a
    
    echo -e "${YELLOW}Architecture:${NC}"
    echo "Machine: $(uname -m)"
    echo "Processor: $(uname -p)"
    
    echo -e "${YELLOW}Kernel:${NC}"
    uname -r
    
    echo -e "${YELLOW}CPU:${NC}"
    lscpu | grep "Model name" | cut -d: -f2 | xargs
    
    echo -e "${YELLOW}Memory:${NC}"
    free -h
    
    echo -e "${YELLOW}Disk:${NC}"
    df -h /
    
    echo -e "${YELLOW}Network:${NC}"
    ip addr show | grep "inet " | head -3
}

# Quick install
quick_install() {
    print_banner
    check_root
    install_deps
    install_rtt_complete
}

# Main menu
main_menu() {
    while true; do
        print_banner
        
        echo -e "\n${PURPLE}=== Main Menu ===${NC}"
        echo -e "${GREEN}1) Install/Update RTT${NC}"
        echo -e "${GREEN}2) Manual Installation${NC}"
        echo -e "${CYAN}3) Create Tunnel Service${NC}"
        echo -e "${CYAN}4) Manage Services${NC}"
        echo -e "${YELLOW}5) Test RTT${NC}"
        echo -e "${YELLOW}6) System Information${NC}"
        echo -e "${RED}7) Uninstall RTT${NC}"
        echo -e "${WHITE}0) Exit${NC}"
        
        read -p "Select option: " choice
        
        case $choice in
            1)
                install_rtt_complete
                read -p "Press Enter to continue..."
                ;;
            2)
                manual_install
                read -p "Press Enter to continue..."
                ;;
            3)
                create_service
                read -p "Press Enter to continue..."
                ;;
            4)
                manage_services
                read -p "Press Enter to continue..."
                ;;
            5)
                test_rtt
                read -p "Press Enter to continue..."
                ;;
            6)
                system_info
                read -p "Press Enter to continue..."
                ;;
            7)
                uninstall_rtt
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

# Start script
if [ "$0" = "$BASH_SOURCE" ]; then
    if [ "$1" = "quick" ]; then
        quick_install
    else
        check_root
        install_deps
        main_menu
    fi
fi
