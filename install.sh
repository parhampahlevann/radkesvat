#!/bin/bash
# quick-rtt-install.sh

echo "Quick RTT Installer"
echo "=================="

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        RTT_ARCH="amd64"
        ;;
    aarch64|arm64)
        RTT_ARCH="arm64"
        ;;
    armv7l)
        RTT_ARCH="arm"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Install dependencies
apt-get update
apt-get install -y wget unzip

# Download RTT
echo "Downloading RTT for $RTT_ARCH..."
wget "https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V7.0.1/v7.0.1_linux_${RTT_ARCH}.zip" -O /tmp/rtt.zip

# Extract and install
unzip /tmp/rtt.zip -d /tmp/
find /tmp -name "RTT" -type f -exec mv {} /usr/local/bin/rtt \;
chmod +x /usr/local/bin/rtt

# Test
rtt --version
echo "Installation complete!"
