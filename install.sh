#!/bin/bash

# Simple MTProto Proxy Installer using pre-compiled binary
# Most reliable method

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Installing MTProto Proxy..."

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Step 1: Install dependencies
echo -e "${GREEN}[1] Installing dependencies...${NC}"
apt update
apt install -y curl wget nano

# Step 2: Download pre-compiled binary
echo -e "${GREEN}[2] Downloading MTProto...${NC}"
cd /tmp
wget https://github.com/TelegramMessenger/MTProxy/releases/download/v1/MTProxy.tar.gz
tar -xvf MTProxy.tar.gz
cd MTProxy

# Move binary
mv objs/bin/mtproto-proxy /usr/local/bin/
chmod +x /usr/local/bin/mtproto-proxy

# Step 3: Generate secret
echo -e "${GREEN}[3] Generating secret...${NC}"
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo $SECRET > /etc/mtproto_secret

# Step 4: Create config script
echo -e "${GREEN}[4] Creating configuration...${NC}"
cat > /etc/mtproto_config.sh << 'EOF'
#!/bin/bash
# MTProxy configuration

PORT=443
SECRET=$(cat /etc/mtproto_secret)
WORKERS=2

/usr/local/bin/mtproto-proxy \
    --user=nobody \
    --group=nogroup \
    --port=$PORT \
    --http-ports=8080 \
    --mtproto-secret=/etc/mtproto_secret \
    --slaves=$WORKERS \
    --bind-addr 0.0.0.0 \
    --max-special-connections 100000 \
    --max-connections 100000 \
    --stats-name mtproto_stats \
    --allow-skip-dh
EOF

chmod +x /etc/mtproto_config.sh

# Step 5: Create systemd service
echo -e "${GREEN}[5] Creating service...${NC}"
cat > /etc/systemd/system/mtproto.service << EOF
[Unit]
Description=MTProto Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=/etc/mtproto_config.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Step 6: Start service
echo -e "${GREEN}[6] Starting service...${NC}"
systemctl daemon-reload
systemctl enable mtproto
systemctl start mtproto

# Step 7: Get IP and show info
IP=$(curl -s https://api.ipify.org)
SECRET=$(cat /etc/mtproto_secret)

echo ""
echo "========================================"
echo "MTProto Proxy Installed Successfully!"
echo "========================================"
echo "IP: $IP"
echo "Port: 443"
echo "Secret: $SECRET"
echo ""
echo "Connection string:"
echo "tg://proxy?server=$IP&port=443&secret=$SECRET"
echo ""
echo "Check status: systemctl status mtproto"
echo "View logs: journalctl -u mtproto -f"
echo "========================================"
