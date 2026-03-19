#!/bin/bash
# ================================================================
#  3proxy — High-Performance Proxy Server — One-Click Installer
# ================================================================
#
#  Features:
#    - Handles 50K+ simultaneous connections
#    - HTTP & HTTPS (CONNECT tunnel) support
#    - Basic authentication
#    - Compiled from source for maximum performance
#    - Local DNS cache (Unbound) for fast resolution
#    - Aggressive kernel tuning (BBR, conntrack, FD limits)
#    - Auto-restart on failure via systemd
#    - SSH login banner with proxy details
#    - Interactive management command (proxy)
#
#  Supported OS:
#    - Ubuntu 22.04 / 24.04
#    - Debian 11 / 12
#    - CentOS 8 / 9, RHEL 8 / 9, AlmaLinux, Rocky Linux
#
#  Usage:
#    1. Edit the CONFIGURATION section below
#    2. Upload to server:  scp install_proxy.sh root@YOUR_SERVER:/root/
#    3. Run:               ssh root@YOUR_SERVER 'bash /root/install_proxy.sh'
#
#  Management:
#    proxy                           # interactive settings
#    systemctl status 3proxy         # check status
#    systemctl restart 3proxy        # restart proxy
#    systemctl stop 3proxy           # stop proxy
#    journalctl -u 3proxy -f         # live logs
#
# ================================================================

set -e

# ================================================================
# CONFIGURATION — Edit these values before running
# ================================================================

PROXY_PORT=8088
PROXY_USER="proxyuser"
PROXY_PASS=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 20)
if [ -z "$PROXY_PASS" ]; then
    PROXY_PASS=$(head -c 100 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)
fi

# ================================================================
# DO NOT EDIT BELOW THIS LINE
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ================================================================
# DETECT OS
# ================================================================

info "Detecting operating system..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    fail "Cannot detect OS (no /etc/os-release)"
fi

case "$OS_ID" in
    ubuntu|debian) PKG="apt" ;;
    centos|rhel|almalinux|rocky) PKG="yum" ;;
    *) fail "Unsupported OS: $OS_ID" ;;
esac
ok "Detected $PRETTY_NAME (package manager: $PKG)"

# ================================================================
# INSTALL DEPENDENCIES
# ================================================================

info "Installing dependencies..."

if [ "$PKG" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential git curl wget net-tools unbound dns-utils openssl >/dev/null 2>&1
else
    yum install -y -q gcc make git curl wget net-tools unbound bind-utils openssl >/dev/null 2>&1
fi
ok "Dependencies installed"

# ================================================================
# REMOVE OLD PROXY (if exists)
# ================================================================

if systemctl is-active --quiet goproxy 2>/dev/null; then
    info "Removing old Go proxy..."
    systemctl stop goproxy 2>/dev/null || true
    systemctl disable goproxy 2>/dev/null || true
    rm -f /etc/systemd/system/goproxy.service
    rm -rf /opt/proxy
    systemctl daemon-reload
    ok "Old Go proxy removed"
fi

if systemctl is-active --quiet 3proxy 2>/dev/null; then
    info "Stopping existing 3proxy..."
    systemctl stop 3proxy 2>/dev/null || true
fi

# ================================================================
# BUILD 3PROXY FROM SOURCE
# ================================================================

info "Building 3proxy from source..."

cd /tmp
rm -rf 3proxy
git clone --depth 1 https://github.com/3proxy/3proxy.git
cd 3proxy
make -f Makefile.Linux
cp bin/3proxy /usr/local/bin/3proxy
chmod +x /usr/local/bin/3proxy
cd /
rm -rf /tmp/3proxy

ok "3proxy built and installed ($(ls -lh /usr/local/bin/3proxy | awk '{print $5}'))"

# ================================================================
# CONFIGURE 3PROXY
# ================================================================

info "Writing 3proxy configuration..."
mkdir -p /etc/3proxy

cat > /etc/3proxy/3proxy.cfg << PROXYCFG
# 3proxy - High Performance Forward Proxy

# DNS (local Unbound cache + fallback)
nserver 127.0.0.1
nserver 8.8.8.8
nserver 1.1.1.1
nscache 131072

# Timeouts
timeouts 1 5 30 60 180 1800 15 60

# Max simultaneous connections
maxconn 50000

# Thread stack size (smaller = more threads possible)
stacksize 8192

# No logging for speed
log /dev/null

# Users
users ${PROXY_USER}:CL:${PROXY_PASS}

# Auth required
auth strong

# Allow only authenticated user
allow ${PROXY_USER}

# HTTP/HTTPS proxy
proxy -n -p${PROXY_PORT}
PROXYCFG

chmod 600 /etc/3proxy/3proxy.cfg
ok "3proxy config written"

# ================================================================
# CONFIGURE UNBOUND (Local DNS Cache)
# ================================================================

info "Configuring Unbound DNS cache..."

cat > /etc/unbound/unbound.conf << 'UNBOUNDCFG'
server:
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.0/8 allow

    num-threads: 4
    msg-cache-slabs: 8
    rrset-cache-slabs: 8
    infra-cache-slabs: 8
    key-cache-slabs: 8
    msg-cache-size: 128m
    rrset-cache-size: 256m
    infra-cache-numhosts: 100000
    outgoing-range: 8192
    num-queries-per-thread: 4096
    so-rcvbuf: 8m
    so-sndbuf: 8m

    cache-min-ttl: 60
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400

    hide-identity: yes
    hide-version: yes

forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 8.8.4.4
    forward-addr: 1.1.1.1
    forward-addr: 1.0.0.1
UNBOUNDCFG

systemctl restart unbound
systemctl enable unbound
ok "Unbound DNS cache configured"

# ================================================================
# KERNEL TUNING
# ================================================================

info "Applying kernel tuning..."

cat > /etc/sysctl.d/99-proxy-tuning.conf << 'SYSCTL'
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.netfilter.nf_conntrack_max = 2097152
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = 786432 1048576 26777216
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
vm.swappiness = 10
SYSCTL

sysctl -p /etc/sysctl.d/99-proxy-tuning.conf 2>/dev/null || true

cat > /etc/security/limits.d/99-proxy.conf << 'LIMITS'
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
*    soft    nproc     131072
*    hard    nproc     131072
LIMITS

ok "Kernel parameters tuned"

# ================================================================
# SYSTEMD SERVICE
# ================================================================

info "Creating systemd service..."

cat > /etc/systemd/system/3proxy.service << 'SERVICE'
[Unit]
Description=3proxy - High Performance Proxy Server
After=network-online.target unbound.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=1
LimitNOFILE=1048576
LimitNPROC=131072
LimitCORE=infinity
TasksMax=infinity
StandardOutput=journal
StandardError=journal
SyslogIdentifier=3proxy

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl start 3proxy
systemctl enable 3proxy
ok "3proxy service started"

# ================================================================
# FIREWALL
# ================================================================

info "Configuring firewall..."

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow ${PROXY_PORT}/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
    ok "ufw configured"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    firewall-cmd --permanent --add-port=${PROXY_PORT}/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    ok "firewalld configured"
else
    iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport ${PROXY_PORT} -j ACCEPT 2>/dev/null || true
    ok "iptables rules added"
fi

# ================================================================
# SSH BANNER
# ================================================================

info "Installing SSH login banner..."

cat > /etc/profile.d/proxy-banner.sh << 'BANNER'
#!/bin/bash

SERVER_IP=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || curl -4 -s --max-time 3 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')

if systemctl is-active --quiet 3proxy; then
    STATUS="\033[0;32mRUNNING\033[0m"
else
    STATUS="\033[0;31mDOWN\033[0m"
fi

UPTIME=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}')
CPU=$(nproc)
RAM_USED=$(free -m | awk '/Mem/{printf "%dMB / %dMB (%.0f%%)", $3, $2, $3/$2*100}')
CONNS=$(ss -s 2>/dev/null | awk '/^TCP:/{print $4}' | tr -d ',')

_PU=$(grep '^users ' /etc/3proxy/3proxy.cfg 2>/dev/null | head -1 | awk '{print $2}' | cut -d: -f1)
_PP=$(grep '^users ' /etc/3proxy/3proxy.cfg 2>/dev/null | head -1 | awk '{print $2}' | cut -d: -f3)
_PA=$(grep '^proxy ' /etc/3proxy/3proxy.cfg 2>/dev/null | head -1 | sed 's/.*-p\([0-9]*\).*/\1/')

echo ""
echo -e "\033[1;36m============================================\033[0m"
echo -e "\033[1;36m        PROXY SERVER DETAILS\033[0m"
echo -e "\033[1;36m============================================\033[0m"
echo ""
echo -e "  Status:     $STATUS"
echo -e "  Engine:     3proxy"
echo -e "  Server:     $SERVER_IP:$_PA"
echo -e "  Username:   $_PU"
echo -e "  Password:   $_PP"
echo ""
echo -e "  Proxy URL:"
echo -e "  \033[1;33mhttp://$_PU:$_PP@$SERVER_IP:$_PA\033[0m"
echo ""
echo -e "  Max Conns:  50000"
echo -e "  Uptime:     $UPTIME"
echo -e "  CPU:        $CPU cores"
echo -e "  Memory:     $RAM_USED"
echo -e "  TCP Conns:  $CONNS"
echo ""
echo -e "\033[1;36m============================================\033[0m"
echo -e "  \033[1;33mproxy\033[0m                        # change settings"
echo -e "  systemctl status 3proxy     # status"
echo -e "  systemctl restart 3proxy    # restart"
echo -e "  journalctl -u 3proxy -f     # logs"
echo -e "\033[1;36m============================================\033[0m"
echo ""
BANNER

chmod +x /etc/profile.d/proxy-banner.sh

# Suppress default MOTD
chmod -x /etc/update-motd.d/* 2>/dev/null || true

ok "SSH banner installed"

# ================================================================
# MANAGEMENT COMMAND (proxy)
# ================================================================

info "Installing proxy management command..."

cat > /usr/local/bin/proxy << 'MGMT'
#!/bin/bash

ANIMALS=("wolf" "hawk" "tiger" "cobra" "eagle" "shark" "viper" "falcon" "panther" "raven" "fox" "bear" "lion" "orca" "lynx" "bison" "crane" "drake" "mantis" "puma")
ACTIONS=("strike" "dash" "rush" "bolt" "surge" "blaze" "drift" "glide" "snap" "hunt" "raid" "leap" "dive" "crawl" "prowl" "stalk" "charge" "lunge" "sprint" "flash")

random_username() {
    local A=${ANIMALS[$RANDOM % ${#ANIMALS[@]}]}
    local B=${ACTIONS[$RANDOM % ${#ACTIONS[@]}]}
    local N=$(printf "%03d" $((RANDOM % 1000)))
    echo "${A^}${B^}${N}"
}

CFG="/etc/3proxy/3proxy.cfg"

change_username() {
    read -p "  New username (blank = auto-generate): " NEW_USER
    if [ -z "$NEW_USER" ]; then
        NEW_USER=$(random_username)
        echo -e "  Generated: \033[1;33m${NEW_USER}\033[0m"
    fi
    OLD_USER=$(grep '^users ' "$CFG" | head -1 | awk '{print $2}' | cut -d: -f1)
    OLD_PASS=$(grep '^users ' "$CFG" | head -1 | awk '{print $2}' | cut -d: -f3)
    sed -i "s/^users .*/users ${NEW_USER}:CL:${OLD_PASS}/" "$CFG"
    sed -i "s/^allow .*/allow ${NEW_USER}/" "$CFG"
    systemctl restart 3proxy
    echo -e "\033[0;32m  Username changed to: ${NEW_USER}\033[0m"
}

change_password() {
    NEW_PASS=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 20)
    if [ -z "$NEW_PASS" ]; then
        NEW_PASS=$(head -c 100 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)
    fi
    OLD_USER=$(grep '^users ' "$CFG" | head -1 | awk '{print $2}' | cut -d: -f1)
    sed -i "s/^users .*/users ${OLD_USER}:CL:${NEW_PASS}/" "$CFG"
    systemctl restart 3proxy
    echo -e "\033[0;32m  New password: ${NEW_PASS}\033[0m"
}

change_port() {
    read -p "  New port: " NEW_PORT
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "\033[0;31m  Cancelled (invalid port)\033[0m"
        return
    fi
    sed -i "s/^proxy .*/proxy -n -p${NEW_PORT}/" "$CFG"
    if command -v ufw &>/dev/null; then
        ufw allow ${NEW_PORT}/tcp 2>/dev/null
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${NEW_PORT}/tcp 2>/dev/null && firewall-cmd --reload 2>/dev/null
    else
        iptables -I INPUT -p tcp --dport ${NEW_PORT} -j ACCEPT 2>/dev/null
    fi
    systemctl restart 3proxy
    echo -e "\033[0;32m  Port changed to: ${NEW_PORT}\033[0m"
}

echo ""
echo -e "\033[1;33m  [1]\033[0m Change username"
echo -e "\033[1;33m  [2]\033[0m Generate new password"
echo -e "\033[1;33m  [3]\033[0m Change port"
echo -e "\033[1;33m  [q]\033[0m Cancel"
echo ""
read -p "  Select option: " OPT

case "$OPT" in
    1) change_username ;;
    2) change_password ;;
    3) change_port ;;
    *) echo "  Cancelled." ;;
esac

echo ""
MGMT

chmod +x /usr/local/bin/proxy
ok "Management command installed (/usr/local/bin/proxy)"

# ================================================================
# VERIFY
# ================================================================

echo ""
info "Verifying installation..."

sleep 2

if ! systemctl is-active --quiet 3proxy; then
    fail "3proxy is not running!"
fi
ok "3proxy service is active"

SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}        INSTALLATION COMPLETE${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""
echo -e "  Engine:    3proxy (compiled from source)"
echo -e "  Server:    ${SERVER_IP}:${PROXY_PORT}"
echo -e "  Username:  ${PROXY_USER}"
echo -e "  Password:  ${PROXY_PASS}"
echo ""
echo -e "  Proxy URL:"
echo -e "  ${YELLOW}http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT}${NC}"
echo ""
echo -e "  Max Conns: 50,000"
echo -e "  DNS Cache: Unbound (local)"
echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "  ${YELLOW}proxy${NC}                        # change settings"
echo -e "  systemctl status 3proxy     # status"
echo -e "  systemctl restart 3proxy    # restart"
echo -e "  journalctl -u 3proxy -f     # logs"
echo -e "${CYAN}================================================${NC}"
echo ""
