#!/bin/bash

# MTProto Proxy Optimized Installation Script for Ubuntu
# Author: Complete script with optimized parameters

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check root access
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root."
        exit 1
    fi
}

# Update system
update_system() {
    print_step "Updating system..."
    apt update && apt upgrade -y
}

# Install dependencies
install_dependencies() {
    print_step "Installing required dependencies..."
    apt install -y \
        git \
        curl \
        wget \
        build-essential \
        zlib1g-dev \
        libssl-dev \
        libevent-dev \
        supervisor \
        python3 \
        python3-pip \
        libssl-dev \
        gcc \
        make
}

# Install MTProto Proxy
install_mtproto_proxy() {
    print_step "Installing MTProto Proxy..."
    
    # Create directory
    mkdir -p /opt/mtproto-proxy
    cd /opt/mtproto-proxy
    
    # Clean if exists
    rm -rf /opt/mtproto-proxy/*
    
    # Download source code
    git clone https://github.com/TelegramMessenger/MTProxy .
    
    # Compile
    make
    
    # Check if compilation succeeded
    if [ ! -f "objs/bin/mtproto-proxy" ]; then
        print_error "Compilation failed!"
        exit 1
    fi
    
    # Create config directory
    mkdir -p /etc/mtproto-proxy
    
    print_message "MTProto Proxy installed successfully."
}

# Generate secret key
generate_secret() {
    print_step "Generating secret key..."
    cd /opt/mtproto-proxy
    
    # Generate two random secrets
    SECRET1=$(head -c 16 /dev/urandom | xxd -ps)
    SECRET2=$(head -c 16 /dev/urandom | xxd -ps)
    
    echo "$SECRET1" > /etc/mtproto-proxy/secret1.txt
    echo "$SECRET2" > /etc/mtproto-proxy/secret2.txt
    
    # Use first secret as primary
    SECRET=$SECRET1
    
    print_message "Secret keys generated."
    print_message "Primary secret: $SECRET1"
    print_message "Secondary secret: $SECRET2"
}

# Create optimized config file
create_optimized_config() {
    print_step "Creating optimized configuration..."
    
    # Get public IP
    PUBLIC_IP=$(curl -s https://api.ipify.org)
    
    # Create main config file
    cat > /etc/mtproto-proxy/proxy.conf << EOF
# Optimized MTProto Proxy Configuration
# Generated automatically

workers = 4
port = 443
ip = ${PUBLIC_IP}
secret = ${SECRET}

# Performance optimizations
tcp_send_buffer = 1048576
tcp_recv_buffer = 1048576
tcp_timeout = 600
stat_timeout = 3600
tcp_keepalive = 60
tcp_keepcnt = 3
tcp_keepidle = 60
tcp_keepintvl = 10
msg_queue_size = 2048
ack_delay_time = 0.1
resend_timeout = 1.0
socks5 = false
fake_tls = true
ddos_protection = true
allow_skip_dh = true
mtu = 1400
EOF
    
    # Create environment file for systemd
    cat > /etc/mtproto-proxy/environment << EOF
WORKERS=4
PORT=443
SECRET=${SECRET}
IP=${PUBLIC_IP}
CUSTOM_OPTS="--aes-pwd /opt/mtproto-proxy/proxy-secret --allow-skip-dh --msg-buf-size 1048576 --max-special-connections 100000 --max-connections 100000 --stats-name mtproto_stats --slaves 4"
EOF
    
    chmod 600 /etc/mtproto-proxy/environment
    print_message "Configuration created successfully."
}

# Create systemd service with optimized parameters
create_systemd_service() {
    print_step "Creating systemd service..."
    
    # Get both secrets
    SECRET1=$(cat /etc/mtproto-proxy/secret1.txt)
    SECRET2=$(cat /etc/mtproto-proxy/secret2.txt)
    
    cat > /etc/systemd/system/mtproto-proxy.service << EOF
[Unit]
Description=MTProto Proxy Service (Optimized)
After=network.target
Wants=network.target
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/mtproto-proxy
EnvironmentFile=/etc/mtproto-proxy/environment
ExecStart=/opt/mtproto-proxy/objs/bin/mtproto-proxy \\
    --user=nobody \\
    --group=nogroup \\
    --port=\${PORT} \\
    --http-ports=8080 \\
    --mtproto-secret=/etc/mtproto-proxy/secret1.txt \\
    --mtproto-secret=/etc/mtproto-proxy/secret2.txt \\
    --slaves=\${WORKERS} \\
    --bind-addr 0.0.0.0 \\
    --nat-info \${IP}:\${PORT} \\
    --proxy-tag "" \\
    --max-special-connections 100000 \\
    --max-connections 100000 \\
    --stats-name mtproto_stats \\
    --allow-skip-dh \\
    --msg-buf-size 1048576 \\
    --log=/var/log/mtproto-proxy.log \\
    --verbose

ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StandardOutput=append:/var/log/mtproto-proxy.log
StandardError=append:/var/log/mtproto-proxy-error.log

# Security and performance optimizations
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log
ReadOnlyPaths=/
PrivateDevices=yes
CapabilityBoundingSet=
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
MemoryDenyWriteExecute=yes

# Resource limits
LimitNOFILE=1000000
LimitNPROC=10000
LimitMEMLOCK=infinity
CPUSchedulingPolicy=rr
CPUSchedulingPriority=1
Nice=-10
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    print_message "Systemd service created."
}

# Optimize network settings
optimize_network_settings() {
    print_step "Optimizing network settings..."
    
    # Backup current sysctl settings
    cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d)
    
    cat > /etc/sysctl.d/99-mtproto-optimization.conf << EOF
# MTProto Proxy Network Optimizations

# TCP Optimization
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 262144 524288 1572864

# TCP Window Scaling
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# TCP Connection Management
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0

# TCP Keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Congestion Control (BBR)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Security
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_retries2 = 5

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# General
fs.file-max = 1000000
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_mtu_probing = 1

# IPv6 optimizations (if used)
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
    
    # Apply settings
    sysctl -p /etc/sysctl.d/99-mtproto-optimization.conf
    sysctl --system
    
    print_message "Network settings optimized."
}

# Configure firewall
configure_firewall() {
    print_step "Configuring firewall..."
    
    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        apt install -y ufw
    fi
    
    # Reset UFW
    echo "y" | ufw reset
    
    # Set defaults
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow necessary ports
    ufw allow 22/tcp comment 'SSH'
    ufw allow 443/tcp comment 'MTProto HTTPS'
    ufw allow 443/udp comment 'MTProto UDP'
    ufw allow 80/tcp comment 'HTTP Redirect'
    ufw allow 8080/tcp comment 'MTProto HTTP'
    
    # Enable UFW
    echo "y" | ufw enable
    
    # Check status
    ufw status verbose
    
    print_message "Firewall configured."
}

# Install and configure supervisor for process management
install_supervisor() {
    print_step "Setting up process monitoring..."
    
    cat > /etc/supervisor/conf.d/mtproto-proxy.conf << EOF
[program:mtproto-proxy]
command=/opt/mtproto-proxy/objs/bin/mtproto-proxy --user=nobody --group=nogroup --port=443 --http-ports=8080 --mtproto-secret=/etc/mtproto-proxy/secret1.txt --mtproto-secret=/etc/mtproto-proxy/secret2.txt --slaves=4 --bind-addr 0.0.0.0 --nat-info $(curl -s https://api.ipify.org):443 --proxy-tag "" --max-special-connections 100000 --max-connections 100000 --stats-name mtproto_stats --allow-skip-dh --msg-buf-size 1048576 --log=/var/log/mtproto-proxy.log --verbose
directory=/opt/mtproto-proxy
user=nobody
autostart=true
autorestart=true
startretries=999
startsecs=10
stopwaitsecs=10
stdout_logfile=/var/log/mtproto-proxy-supervisor.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
stderr_logfile=/var/log/mtproto-proxy-supervisor-error.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=5
environment=HOME="/tmp",USER="nobody"

# Process management
killasgroup=true
stopasgroup=true

# Resource limits
priority=999
EOF
    
    # Restart supervisor
    systemctl restart supervisor
    supervisorctl update
    
    print_message "Supervisor monitoring configured."
}

# Create connection monitoring script
create_monitoring_script() {
    print_step "Creating connection monitoring script..."
    
    mkdir -p /opt/mtproto-proxy/scripts
    
    cat > /opt/mtproto-proxy/scripts/monitor-connections.sh << 'EOF'
#!/bin/bash

LOG_FILE="/var/log/mtproto-monitor.log"
ERROR_LOG="/var/log/mtproto-errors.log"
MAX_RETRIES=5
RETRY_DELAY=10

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

check_connection() {
    # Check if proxy process is running
    if ! pgrep -x "mtproto-proxy" > /dev/null; then
        log_message "ERROR: MTProto Proxy process not running!"
        return 1
    fi
    
    # Check if proxy is listening on port 443
    if ! ss -tlnp | grep ":443" | grep "mtproto-proxy" > /dev/null; then
        log_message "ERROR: Proxy not listening on port 443!"
        return 1
    fi
    
    # Test local connectivity
    if ! timeout 10 curl -s http://localhost:8080/ > /dev/null; then
        log_message "WARNING: Local HTTP check failed!"
        return 2
    fi
    
    # Test external connectivity (with retry)
    for i in {1..3}; do
        if timeout 15 curl -s https://api.telegram.org > /dev/null; then
            log_message "INFO: External connectivity OK"
            return 0
        fi
        sleep 5
    done
    
    log_message "ERROR: External connectivity failed!"
    return 3
}

restart_service() {
    log_message "Attempting to restart MTProto Proxy..."
    
    # Try systemd restart
    systemctl restart mtproto-proxy.service
    
    # Wait and check
    sleep 15
    
    if check_connection; then
        log_message "SUCCESS: Service restarted successfully"
        return 0
    else
        log_message "ERROR: Service restart failed!"
        return 1
    fi
}

# Main monitoring loop
while true; do
    if ! check_connection; then
        log_message "Connection issues detected. Attempting recovery..."
        
        # Try multiple recovery methods
        for attempt in {1..$MAX_RETRIES}; do
            log_message "Recovery attempt $attempt of $MAX_RETRIES"
            
            if restart_service; then
                log_message "Recovery successful"
                break
            fi
            
            if [ $attempt -lt $MAX_RETRIES ]; then
                sleep $RETRY_DELAY
            fi
        done
        
        # If still failing, try complete reload
        if ! check_connection; then
            log_message "CRITICAL: All recovery attempts failed!"
            systemctl daemon-reload
            systemctl reset-failed mtproto-proxy.service
            systemctl start mtproto-proxy.service
            sleep 30
        fi
    fi
    
    # Log statistics every hour
    if [ $(date +%M) == "00" ]; then
        CONNECTIONS=$(ss -tn | grep ":443" | wc -l)
        MEMORY=$(ps -o rss= -p $(pgrep mtproto-proxy) | awk '{sum+=$1} END {print sum/1024}')
        log_message "STATS: Connections: $CONNECTIONS, Memory: ${MEMORY}MB"
    fi
    
    sleep 60
done
EOF
    
    chmod +x /opt/mtproto-proxy/scripts/monitor-connections.sh
    
    # Create systemd service for monitor
    cat > /etc/systemd/system/mtproto-monitor.service << EOF
[Unit]
Description=MTProto Proxy Connection Monitor
After=mtproto-proxy.service
Requires=mtproto-proxy.service

[Service]
Type=simple
ExecStart=/opt/mtproto-proxy/scripts/monitor-connections.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable mtproto-monitor.service
    
    print_message "Monitoring script created."
}

# Create health check and maintenance script
create_maintenance_script() {
    print_step "Creating maintenance script..."
    
    cat > /opt/mtproto-proxy/scripts/maintenance.sh << 'EOF'
#!/bin/bash

# Maintenance script for MTProto Proxy
# Run daily via cron

LOG="/var/log/mtproto-maintenance.log"

echo "$(date) - Starting maintenance" >> $LOG

# 1. Rotate logs if they're too large
find /var/log -name "mtproto*log" -size +50M -exec truncate -s 10M {} \;

# 2. Clear old connection states
conntrack -D 2>/dev/null || true

# 3. Restart service if it's been running for more than 7 days
PROXY_PID=$(systemctl show -p MainPID mtproto-proxy.service | cut -d= -f2)
if [ -f /proc/$PROXY_PID/stat ]; then
    START_TIME=$(awk '{print $22}' /proc/$PROXY_PID/stat)
    CURRENT_TIME=$(awk '{print int($1/100)}' /proc/uptime)
    UPTIME=$((CURRENT_TIME - START_TIME))
    
    # If uptime > 7 days (604800 seconds)
    if [ $UPTIME -gt 604800 ]; then
        echo "$(date) - Restarting long-running proxy (uptime: ${UPTIME}s)" >> $LOG
        systemctl restart mtproto-proxy.service
    fi
fi

# 4. Check disk space
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ $DISK_USAGE -gt 90 ]; then
    echo "$(date) - WARNING: Disk usage at ${DISK_USAGE}%" >> $LOG
fi

# 5. Update system if needed (weekly)
DAY=$(date +%u)
if [ $DAY -eq 6 ]; then  # Saturday
    apt-get update && apt-get upgrade -y >> $LOG 2>&1
fi

echo "$(date) - Maintenance completed" >> $LOG
EOF
    
    chmod +x /opt/mtproto-proxy/scripts/maintenance.sh
    
    # Add to cron (daily at 3 AM)
    (crontab -l 2>/dev/null; echo "0 3 * * * /opt/mtproto-proxy/scripts/maintenance.sh") | crontab -
    
    print_message "Maintenance script created."
}

# Create backup script
create_backup_script() {
    print_step "Creating backup script..."
    
    cat > /opt/mtproto-proxy/scripts/backup.sh << 'EOF'
#!/bin/bash

BACKUP_DIR="/var/backups/mtproto"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

echo "Backup started at $(date)" > $BACKUP_DIR/backup_$DATE.log

# Backup configuration
cp -r /etc/mtproto-proxy $BACKUP_DIR/mtproto-proxy-config_$DATE
cp /etc/systemd/system/mtproto-proxy.service $BACKUP_DIR/
cp /etc/sysctl.d/99-mtproto-optimization.conf $BACKUP_DIR/

# Backup secrets (with minimal permissions)
cp /etc/mtproto-proxy/secret*.txt $BACKUP_DIR/
chmod 600 $BACKUP_DIR/secret*.txt

# Backup logs
tar -czf $BACKUP_DIR/logs_$DATE.tar.gz /var/log/mtproto*.log 2>/dev/null || true

# Clean old backups (keep last 7 days)
find $BACKUP_DIR -type f -mtime +7 -delete
find $BACKUP_DIR -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

echo "Backup completed at $(date)" >> $BACKUP_DIR/backup_$DATE.log
echo "Backup size: $(du -sh $BACKUP_DIR | cut -f1)"
EOF
    
    chmod +x /opt/mtproto-proxy/scripts/backup.sh
    
    # Add to cron (weekly on Sunday)
    (crontab -l 2>/dev/null; echo "0 2 * * 0 /opt/mtproto-proxy/scripts/backup.sh") | crontab -
    
    print_message "Backup script created."
}

# Create status check script
create_status_script() {
    cat > /usr/local/bin/mtproto-status << 'EOF'
#!/bin/bash

echo "=== MTProto Proxy Status ==="
echo ""

# Check service status
systemctl status mtproto-proxy.service --no-pager -l

echo ""
echo "=== Connection Status ==="

# Check listening ports
echo "Listening ports:"
ss -tlnp | grep mtproto-proxy || echo "No ports found"

echo ""
echo "=== Active Connections ==="
CONNECTIONS=$(ss -tn state established | grep ":443" | wc -l)
echo "Active connections: $CONNECTIONS"

echo ""
echo "=== Resource Usage ==="
ps aux | grep mtproto-proxy | grep -v grep | awk '{print "Memory: "$6/1024"MB, CPU: "$3"%"}'

echo ""
echo "=== Recent Logs ==="
tail -20 /var/log/mtproto-proxy.log 2>/dev/null || echo "Log file not found"
EOF
    
    chmod +x /usr/local/bin/mtproto-status
}

# Create test script
create_test_script() {
    cat > /usr/local/bin/test-mtproto << 'EOF'
#!/bin/bash

SECRET=$(cat /etc/mtproto-proxy/secret1.txt 2>/dev/null || echo "No secret found")
IP=$(curl -s https://api.ipify.org)

echo "Testing MTProto Proxy Connection..."
echo "IP: $IP"
echo "Secret: $SECRET"
echo ""
echo "Connection string:"
echo "tg://proxy?server=$IP&port=443&secret=$SECRET"
echo ""
echo "Testing connectivity..."

# Test local
if curl -s http://localhost:8080/ > /dev/null; then
    echo "✓ Local connection OK"
else
    echo "✗ Local connection FAILED"
fi

# Test external (with timeout)
if timeout 10 curl -s https://api.telegram.org > /dev/null; then
    echo "✓ External connectivity OK"
else
    echo "✗ External connectivity FAILED"
fi
EOF
    
    chmod +x /usr/local/bin/test-mtproto
}

# Create uninstall script
create_uninstall_script() {
    cat > /opt/mtproto-proxy/uninstall.sh << 'EOF'
#!/bin/bash

echo "Stopping MTProto Proxy services..."
systemctl stop mtproto-proxy.service
systemctl stop mtproto-monitor.service
systemctl disable mtproto-proxy.service
systemctl disable mtproto-monitor.service

echo "Removing services..."
rm -f /etc/systemd/system/mtproto-proxy.service
rm -f /etc/systemd/system/mtproto-monitor.service

echo "Removing configuration..."
rm -rf /etc/mtproto-proxy

echo "Removing scripts..."
rm -f /usr/local/bin/mtproto-status
rm -f /usr/local/bin/test-mtproto
rm -rf /opt/mtproto-proxy/scripts

echo "Removing cron jobs..."
crontab -l | grep -v mtproto | crontab -

echo "Removing supervisor config..."
rm -f /etc/supervisor/conf.d/mtproto-proxy.conf

echo "Cleaning up logs..."
rm -f /var/log/mtproto*.log

echo "Uninstall complete. Note: /opt/mtproto-proxy directory still exists."
EOF
    
    chmod +x /opt/mtproto-proxy/uninstall.sh
}

# Display installation information
show_installation_info() {
    SECRET1=$(cat /etc/mtproto-proxy/secret1.txt 2>/dev/null || echo "ERROR: Secret not found")
    PUBLIC_IP=$(curl -s https://api.ipify.org)
    
    echo ""
    echo "=========================================="
    echo "MTProto Proxy Installation Complete!"
    echo "=========================================="
    echo ""
    echo "SERVER INFORMATION:"
    echo "IP Address: $PUBLIC_IP"
    echo "Port: 443"
    echo "Primary Secret: $SECRET1"
    echo "Secondary Secret: $(cat /etc/mtproto-proxy/secret2.txt 2>/dev/null || echo 'Not found')"
    echo ""
    echo "CONNECTION STRINGS:"
    echo "tg://proxy?server=$PUBLIC_IP&port=443&secret=$SECRET1"
    echo "https://t.me/proxy?server=$PUBLIC_IP&port=443&secret=$SECRET1"
    echo ""
    echo "MANAGEMENT COMMANDS:"
    echo "mtproto-status          # Check proxy status"
    echo "test-mtproto            # Test connection"
    echo "systemctl restart mtproto-proxy  # Restart service"
    echo "journalctl -u mtproto-proxy -f   # View logs"
    echo ""
    echo "BACKUP & MAINTENANCE:"
    echo "Backups: /var/backups/mtproto/"
    echo "Maintenance: Runs daily at 3 AM"
    echo "Monitoring: Active"
    echo ""
    echo "UNINSTALL:"
    echo "cd /opt/mtproto-proxy && ./uninstall.sh"
    echo "=========================================="
    echo ""
    
    # Start services
    print_step "Starting services..."
    systemctl start mtproto-proxy.service
    systemctl start mtproto-monitor.service
    sleep 3
    
    print_message "Installation completed successfully!"
}

# Main installation function
main() {
    clear
    echo "=========================================="
    echo "MTProto Proxy Optimized Installer"
    echo "for Ubuntu Server"
    echo "=========================================="
    echo ""
    
    check_root
    
    # Execute installation steps
    print_step "Starting installation process..."
    
    update_system
    install_dependencies
    install_mtproto_proxy
    generate_secret
    create_optimized_config
    create_systemd_service
    optimize_network_settings
    configure_firewall
    install_supervisor
    create_monitoring_script
    create_maintenance_script
    create_backup_script
    create_status_script
    create_test_script
    create_uninstall_script
    
    show_installation_info
    
    # Final checks
    print_step "Running final checks..."
    if systemctl is-active --quiet mtproto-proxy.service; then
        print_message "✓ MTProto Proxy service is running"
    else
        print_error "✗ MTProto Proxy service failed to start"
    fi
    
    print_message "Installation complete! Reboot recommended for network optimizations."
}

# Run main function
main
