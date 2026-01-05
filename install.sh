#!/bin/bash

# RTT Installer Script
# Version: 4.0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Banner
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         RTT Tunnel Installer - Professional         ║"
    echo "║           Fixed Installation Version                ║"
    echo "║             By: Peyman (Ptechgithub)                ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root!${NC}"
        exit 1
    fi
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    
    case $OS in
        ubuntu|debian)
            PKG_MGR="apt-get"
            ;;
        centos|rhel|fedora|almalinux|rocky)
            if [ "$OS" = "fedora" ]; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        *)
            echo -e "${RED}Unsupported OS: $OS${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}OS: $OS $VER${NC}"
    echo -e "${GREEN}Package Manager: $PKG_MGR${NC}"
}

# Install dependencies
install_deps() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    
    if [ "$PKG_MGR" = "apt-get" ]; then
        apt-get update
        apt-get install -y wget curl unzip lsof net-tools jq
    elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
        $PKG_MGR install -y wget curl unzip lsof net-tools epel-release
        $PKG_MGR install -y jq || {
            # Install jq manually if package not available
            wget -O /usr/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-amd64
            chmod +x /usr/bin/jq
        }
    fi
    
    echo -e "${GREEN}Dependencies installed${NC}"
}

# Detect architecture
get_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            RTT_ARCH="amd64"
            ;;
        aarch64|arm64)
            RTT_ARCH="arm64"
            ;;
        armv7l|armv8l)
            RTT_ARCH="arm"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}Architecture: $ARCH -> $RTT_ARCH${NC}"
}

# Get latest version
get_latest_version() {
    echo -e "${YELLOW}Getting latest version...${NC}"
    
    # Try multiple methods
    VERSION=$(curl -s https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest | jq -r '.tag_name' | sed 's/V//' 2>/dev/null)
    
    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        # Alternative method
        VERSION=$(curl -s https://github.com/radkesvat/ReverseTlsTunnel/releases/latest | grep -oP 'tag/V\K[0-9.]+' | head -1)
    fi
    
    if [ -z "$VERSION" ]; then
        # Fallback to known version
        VERSION="7.0.1"
        echo -e "${YELLOW}Using fallback version: $VERSION${NC}"
    else
        echo -e "${GREEN}Latest version: $VERSION${NC}"
    fi
    
    echo $VERSION
}

# Manual download from multiple sources
download_rtt() {
    local version=$1
    local arch=$2
    
    echo -e "${YELLOW}Downloading RTT v$version for $arch...${NC}"
    
    # List of possible download URLs
    local urls=(
        "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/v${version}_linux_${arch}.zip"
        "https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/v${version}_linux_${arch}.zip"
        "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/v$version/v${version}_linux_${arch}.zip"
    )
    
    # Try each URL
    for url in "${urls[@]}"; do
        echo -e "${BLUE}Trying: $url${NC}"
        
        if wget --timeout=30 --tries=3 -q "$url" -O /tmp/rtt.zip; then
            echo -e "${GREEN}Download successful!${NC}"
            return 0
        fi
        
        echo -e "${YELLOW}Failed, trying next...${NC}"
    done
    
    # If all URLs fail, try direct from releases page
    echo -e "${YELLOW}Trying alternative method...${NC}"
    
    # Get download URL from releases page
    local download_page=$(curl -s "https://github.com/radkesvat/ReverseTlsTunnel/releases/expanded_assets/V$version")
    local download_url=$(echo "$download_page" | grep -oP "href=\"\K[^\"]*${arch}\.zip(?=\")" | head -1)
    
    if [ -n "$download_url" ]; then
        echo -e "${BLUE}Found: https://github.com$download_url${NC}"
        wget --timeout=30 -q "https://github.com$download_url" -O /tmp/rtt.zip && return 0
    fi
    
    echo -e "${RED}All download methods failed!${NC}"
    return 1
}

# Alternative: Direct binary download
download_rtt_direct() {
    local version=$1
    local arch=$2
    
    echo -e "${YELLOW}Trying direct binary download...${NC}"
    
    # Direct binary URLs (without zip)
    local binary_urls=(
        "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V$version/RTT_linux_$arch"
        "https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/RTT_linux_$arch"
    )
    
    for url in "${binary_urls[@]}"; do
        echo -e "${BLUE}Trying: $url${NC}"
        
        if wget --timeout=30 --tries=3 -q "$url" -O /tmp/rtt_binary; then
            chmod +x /tmp/rtt_binary
            mv /tmp/rtt_binary /usr/local/bin/rtt
            echo -e "${GREEN}Direct binary download successful!${NC}"
            return 0
        fi
    done
    
    return 1
}

# Install from release assets
install_from_assets() {
    local version=$1
    local arch=$2
    
    echo -e "${YELLOW}Searching for release assets...${NC}"
    
    # Get assets list
    local assets=$(curl -s "https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/tags/V$version" | 
                   jq -r '.assets[] | .browser_download_url' 2>/dev/null)
    
    if [ -z "$assets" ]; then
        assets=$(curl -s "https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest" | 
                 jq -r '.assets[] | .browser_download_url' 2>/dev/null)
    fi
    
    # Find matching asset
    local asset_url=$(echo "$assets" | grep -i "$arch" | head -1)
    
    if [ -n "$asset_url" ]; then
        echo -e "${GREEN}Found asset: $asset_url${NC}"
        
        if wget --timeout=30 -q "$asset_url" -O /tmp/rtt.zip; then
            return 0
        fi
    fi
    
    return 1
}

# Install RTT - Main function
install_rtt() {
    print_banner
    
    # Get version and arch
    VERSION=$(get_latest_version)
    get_arch
    
    echo -e "${CYAN}Installing RTT v$VERSION for $RTT_ARCH...${NC}"
    
    # Remove old versions
    echo -e "${YELLOW}Cleaning old installations...${NC}"
    rm -f /usr/local/bin/rtt /usr/local/bin/RTT /usr/bin/rtt /usr/bin/RTT
    pkill -9 rtt 2>/dev/null || true
    pkill -9 RTT 2>/dev/null || true
    
    # Try multiple installation methods
    local installed=0
    
    # Method 1: Download zip from releases
    if [ $installed -eq 0 ]; then
        echo -e "${YELLOW}Method 1: Download from releases...${NC}"
        if download_rtt "$VERSION" "$RTT_ARCH"; then
            if install_from_zip; then
                installed=1
            fi
        fi
    fi
    
    # Method 2: Install from assets
    if [ $installed -eq 0 ]; then
        echo -e "${YELLOW}Method 2: Install from assets...${NC}"
        if install_from_assets "$VERSION" "$RTT_ARCH"; then
            if install_from_zip; then
                installed=1
            fi
        fi
    fi
    
    # Method 3: Direct binary download
    if [ $installed -eq 0 ]; then
        echo -e "${YELLOW}Method 3: Direct binary download...${NC}"
        if download_rtt_direct "$VERSION" "$RTT_ARCH"; then
            installed=1
        fi
    fi
    
    # Method 4: Manual build locations
    if [ $installed -eq 0 ]; then
        echo -e "${YELLOW}Method 4: Trying known build locations...${NC}"
        
        # Try different build patterns
        local builds=(
            "https://nightly.link/radkesvat/ReverseTlsTunnel/workflows/build/master/RTT_linux_$RTT_ARCH.zip"
            "https://github.com/radkesvat/ReverseTlsTunnel/suites/$(curl -s https://github.com/radkesvat/ReverseTlsTunnel/actions | grep -oP 'suites/\K[0-9]+' | head -1)/artifacts/$(curl -s https://github.com/radkesvat/ReverseTlsTunnel/actions | grep -oP 'artifactId=\K[0-9]+' | head -1)"
        )
        
        for build_url in "${builds[@]}"; do
            echo -e "${BLUE}Trying: $build_url${NC}"
            if wget --timeout=30 -q "$build_url" -O /tmp/rtt.zip; then
                if install_from_zip; then
                    installed=1
                    break
                fi
            fi
        done
    fi
    
    # Method 5: Pre-compiled binaries from CDN
    if [ $installed -eq 0 ]; then
        echo -e "${YELLOW}Method 5: CDN sources...${NC}"
        
        # Try jsDelivr CDN
        local cdn_url="https://cdn.jsdelivr.net/gh/radkesvat/ReverseTlsTunnel@$VERSION/RTT_linux_$RTT_ARCH"
        
        if wget --timeout=30 -q "$cdn_url" -O /tmp/rtt_binary; then
            chmod +x /tmp/rtt_binary
            mv /tmp/rtt_binary /usr/local/bin/rtt
            echo -e "${GREEN}Installed from CDN!${NC}"
            installed=1
        fi
    fi
    
    # Final verification
    if [ $installed -eq 1 ]; then
        verify_installation
    else
        echo -e "${RED}All installation methods failed!${NC}"
        echo -e "${YELLOW}Possible reasons:${NC}"
        echo "1. No internet connection"
        echo "2. GitHub is blocked"
        echo "3. Version $VERSION doesn't exist for $RTT_ARCH"
        echo "4. Firewall blocking downloads"
        
        # Offer manual installation
        manual_install_option
    fi
}

# Install from zip file
install_from_zip() {
    echo -e "${YELLOW}Extracting and installing...${NC}"
    
    # Check if zip file exists
    if [ ! -f /tmp/rtt.zip ]; then
        echo -e "${RED}No zip file found!${NC}"
        return 1
    fi
    
    # Extract
    unzip -o /tmp/rtt.zip -d /tmp/rtt_extract/ >/dev/null 2>&1
    
    # Find binary
    local binary=$(find /tmp/rtt_extract/ -type f \( -name "RTT" -o -name "rtt" \) | head -1)
    
    if [ -z "$binary" ]; then
        # Look in subdirectories
        binary=$(find /tmp/rtt_extract/ -type f -executable | head -1)
    fi
    
    if [ -n "$binary" ] && [ -f "$binary" ]; then
        # Install
        cp "$binary" /usr/local/bin/rtt
        chmod +x /usr/local/bin/rtt
        ln -sf /usr/local/bin/rtt /usr/bin/rtt 2>/dev/null
        
        echo -e "${GREEN}Binary found and installed: $binary${NC}"
        
        # Cleanup
        rm -rf /tmp/rtt.zip /tmp/rtt_extract/
        return 0
    else
        echo -e "${RED}No binary found in zip!${NC}"
        ls -la /tmp/rtt_extract/ 2>/dev/null
        return 1
    fi
}

# Verify installation
verify_installation() {
    echo -e "${YELLOW}Verifying installation...${NC}"
    
    if command -v rtt &> /dev/null; then
        echo -e "${GREEN}✓ RTT installed at: $(which rtt)${NC}"
        
        # Test version
        if rtt --version >/dev/null 2>&1; then
            local version_info=$(rtt --version 2>&1 | head -5)
            echo -e "${GREEN}✓ Version info:${NC}"
            echo "$version_info"
        else
            # Try alternative
            if /usr/local/bin/rtt --version >/dev/null 2>&1; then
                local version_info=$(/usr/local/bin/rtt --version 2>&1 | head -5)
                echo -e "${GREEN}✓ Version info:${NC}"
                echo "$version_info"
            else
                echo -e "${YELLOW}⚠ Version check failed, but binary exists${NC}"
            fi
        fi
        
        # Test basic functionality
        echo -e "${YELLOW}Testing basic functionality...${NC}"
        timeout 2 rtt --help >/dev/null 2>&1
        if [ $? -eq 0 ] || [ $? -eq 124 ]; then
            echo -e "${GREEN}✓ RTT is working!${NC}"
        else
            echo -e "${YELLOW}⚠ Help command failed, but binary exists${NC}"
        fi
        
        return 0
    else
        echo -e "${RED}✗ RTT not found in PATH!${NC}"
        
        # Check if it exists but not in PATH
        if [ -f /usr/local/bin/rtt ]; then
            echo -e "${YELLOW}Found at /usr/local/bin/rtt but not in PATH${NC}"
            /usr/local/bin/rtt --version >/dev/null 2>&1 && echo -e "${GREEN}✓ Binary works!${NC}"
            echo -e "${YELLOW}Adding to PATH...${NC}"
            ln -sf /usr/local/bin/rtt /usr/bin/rtt
        fi
        
        return 1
    fi
}

# Manual install option
manual_install_option() {
    echo -e "\n${CYAN}=== Manual Installation Option ===${NC}"
    echo -e "${YELLOW}If automatic installation failed, you can:${NC}"
    echo "1. Download manually from:"
    echo "   https://github.com/radkesvat/ReverseTlsTunnel/releases"
    echo "2. Upload the binary to server"
    echo "3. Use the manual install option below"
    
    read -p "Do you want to install manually? [y/N]: " choice
    
    if [[ $choice =~ ^[Yy]$ ]]; then
        manual_install
    fi
}

# Manual installation
manual_install() {
    echo -e "${CYAN}=== Manual Installation ===${NC}"
    
    echo -e "${YELLOW}Available options:${NC}"
    echo "1) Upload binary via SCP/SFTP"
    echo "2) Download from custom URL"
    echo "3) Use existing binary"
    
    read -p "Choose option [1-3]: " option
    
    case $option in
        1)
            echo -e "${YELLOW}Please upload RTT binary to /tmp/rtt_binary${NC}"
            echo -e "You can use: scp RTT_linux_$(uname -m) user@server:/tmp/rtt_binary"
            read -p "Press Enter after upload..." dummy
            
            if [ -f /tmp/rtt_binary ]; then
                chmod +x /tmp/rtt_binary
                mv /tmp/rtt_binary /usr/local/bin/rtt
                ln -sf /usr/local/bin/rtt /usr/bin/rtt
                echo -e "${GREEN}Manual installation complete!${NC}"
                verify_installation
            else
                echo -e "${RED}No file found at /tmp/rtt_binary!${NC}"
            fi
            ;;
        2)
            read -p "Enter download URL: " download_url
            if [ -n "$download_url" ]; then
                wget -q "$download_url" -O /usr/local/bin/rtt
                chmod +x /usr/local/bin/rtt
                ln -sf /usr/local/bin/rtt /usr/bin/rtt
                echo -e "${GREEN}Downloaded and installed!${NC}"
                verify_installation
            fi
            ;;
        3)
            read -p "Enter path to existing binary: " binary_path
            if [ -f "$binary_path" ]; then
                chmod +x "$binary_path"
                cp "$binary_path" /usr/local/bin/rtt
                ln -sf /usr/local/bin/rtt /usr/bin/rtt
                echo -e "${GREEN}Copied and installed!${NC}"
                verify_installation
            else
                echo -e "${RED}File not found: $binary_path${NC}"
            fi
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            ;;
    esac
}

# Test RTT functionality
test_rtt() {
    echo -e "${CYAN}=== Testing RTT ===${NC}"
    
    if ! command -v rtt &> /dev/null; then
        echo -e "${RED}RTT not installed!${NC}"
        return 1
    fi
    
    # Test 1: Version
    echo -e "${YELLOW}Test 1: Version check...${NC}"
    rtt --version 2>&1 | head -5
    
    # Test 2: Help
    echo -e "\n${YELLOW}Test 2: Help command...${NC}"
    timeout 2 rtt --help 2>&1 | head -10
    
    # Test 3: Basic Iran config
    echo -e "\n${YELLOW}Test 3: Testing Iran mode (5 seconds)...${NC}"
    timeout 5 rtt --iran --lport:9999 --password:test123 --sni:google.com --log-level:error &
    local pid=$!
    sleep 3
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Iran mode works!${NC}"
        kill $pid 2>/dev/null
    else
        echo -e "${RED}✗ Iran mode failed${NC}"
    fi
    
    # Test 4: File permissions
    echo -e "\n${YELLOW}Test 4: File permissions...${NC}"
    ls -la /usr/local/bin/rtt
    
    echo -e "${GREEN}Testing complete!${NC}"
}

# Create simple tunnel service
create_service() {
    echo -e "${CYAN}=== Create Tunnel Service ===${NC}"
    
    if ! command -v rtt &> /dev/null; then
        echo -e "${RED}RTT not installed! Install it first.${NC}"
        return 1
    fi
    
    # Server type
    echo -e "${YELLOW}Select server type:${NC}"
    echo "1) Iran (internal server)"
    echo "2) Kharej (external server)"
    read -p "Choice [1/2]: " server_type
    
    # Get config
    read -p "Password: " password
    read -p "SNI (default: google.com): " sni
    sni=${sni:-google.com}
    
    if [ "$server_type" = "1" ]; then
        # Iran
        read -p "Local port (default: 443): " lport
        lport=${lport:-443}
        
        cmd="--iran --lport:$lport --password:$password --sni:$sni --log-level:info"
        
    elif [ "$server_type" = "2" ]; then
        # Kharej
        read -p "Iran server IP: " iran_ip
        read -p "Local port to forward (default: 8080): " toport
        toport=${toport:-8080}
        
        cmd="--kharej --iran-ip:$iran_ip --iran-port:443 --toip:127.0.0.1 --toport:$toport --password:$password --sni:$sni --log-level:info"
    else
        echo -e "${RED}Invalid choice!${NC}"
        return 1
    fi
    
    # Test command first
    echo -e "${YELLOW}Testing command: rtt $cmd${NC}"
    timeout 5 rtt $cmd &
    local pid=$!
    sleep 3
    
    if ps -p $pid >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Command works!${NC}"
        kill $pid 2>/dev/null
        
        # Create service
        read -p "Service name (default: rtt-tunnel): " service_name
        service_name=${service_name:-rtt-tunnel}
        
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

[Install]
WantedBy=multi-user.target
EOF
        
        # Enable and start
        systemctl daemon-reload
        systemctl enable $service_name
        systemctl start $service_name
        
        sleep 2
        
        if systemctl is-active --quiet $service_name; then
            echo -e "${GREEN}✓ Service created and running!${NC}"
            systemctl status $service_name --no-pager | head -20
        else
            echo -e "${RED}✗ Service failed to start${NC}"
            journalctl -u $service_name -n 20 --no-pager
        fi
    else
        echo -e "${RED}✗ Command test failed!${NC}"
    fi
}

# Check firewall
check_firewall() {
    echo -e "${CYAN}=== Firewall Check ===${NC}"
    
    # Check if firewall is active
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        echo -e "${YELLOW}UFW firewall is active${NC}"
        echo -e "${YELLOW}You may need to allow ports:${NC}"
        echo "  sudo ufw allow 443/tcp"
        echo "  sudo ufw allow 80/tcp"
    fi
    
    if command -v firewall-cmd &> /dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        echo -e "${YELLOW}FirewallD is active${NC}"
    fi
    
    # Check iptables
    echo -e "${YELLOW}Current iptables rules for ports 80,443:${NC}"
    iptables -L -n | grep -E "(80|443)" || echo "No specific rules found"
}

# Main menu
main_menu() {
    while true; do
        print_banner
        
        echo -e "\n${PURPLE}=== Main Menu ===${NC}"
        echo -e "${GREEN}1) Install/Update RTT${NC}"
        echo -e "${GREEN}2) Test RTT Installation${NC}"
        echo -e "${CYAN}3) Create Tunnel Service${NC}"
        echo -e "${CYAN}4) Check Firewall${NC}"
        echo -e "${YELLOW}5) Manual Installation${NC}"
        echo -e "${YELLOW}6) Check System Info${NC}"
        echo -e "${RED}7) Uninstall RTT${NC}"
        echo -e "${WHITE}0) Exit${NC}"
        
        read -p "Select option: " choice
        
        case $choice in
            1)
                install_rtt
                read -p "Press Enter to continue..."
                ;;
            2)
                test_rtt
                read -p "Press Enter to continue..."
                ;;
            3)
                create_service
                read -p "Press Enter to continue..."
                ;;
            4)
                check_firewall
                read -p "Press Enter to continue..."
                ;;
            5)
                manual_install
                read -p "Press Enter to continue..."
                ;;
            6)
                echo -e "${CYAN}=== System Info ===${NC}"
                echo "OS: $(uname -a)"
                echo "Arch: $(uname -m)"
                echo "Kernel: $(uname -r)"
                echo "CPU: $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
                echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
                read -p "Press Enter to continue..."
                ;;
            7)
                echo -e "${RED}Uninstalling RTT...${NC}"
                rm -f /usr/local/bin/rtt /usr/bin/rtt
                systemctl stop rtt-tunnel 2>/dev/null
                systemctl disable rtt-tunnel 2>/dev/null
                rm -f /etc/systemd/system/rtt-tunnel.service
                systemctl daemon-reload
                echo -e "${GREEN}RTT uninstalled!${NC}"
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

# Quick install function
quick_install() {
    print_banner
    check_root
    detect_os
    install_deps
    install_rtt
}

# Start
if [ "$0" = "$BASH_SOURCE" ]; then
    if [ "$1" = "quick" ]; then
        quick_install
    else
        check_root
        detect_os
        install_deps
        main_menu
    fi
fi
