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
#    bash <(curl -sL https://raw.githubusercontent.com/USER/REPO/main/install_proxy.sh)
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
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

TOTAL_STEPS=10
CURRENT_STEP=0
START_TIME=$(date +%s)

progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local PCT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local FILLED=$((PCT / 5))
    local EMPTY=$((20 - FILLED))
    local BAR=""
    for ((i=0; i<FILLED; i++)); do BAR+="█"; done
    for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
    local NOW=$(date +%s)
    local ELAPSED=$((NOW - START_TIME))
    local MINS=$((ELAPSED / 60))
    local SECS=$((ELAPSED % 60))
    echo ""
    echo -e "  ${CYAN}${BAR}${NC}  ${WHITE}${PCT}%${NC}  ${DIM}[${CURRENT_STEP}/${TOTAL_STEPS}]  ${MINS}m${SECS}s${NC}"
    echo -e "  ${GREEN}▸${NC} $1"
    echo ""
}

warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "\n  ${RED}✗${NC} $1\n"; exit 1; }

clear 2>/dev/null || true
echo ""
echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}   ${WHITE}3proxy — High Performance Proxy Installer${NC}   ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}HTTP/HTTPS  •  Auth  •  50K Connections  •  DNS Cache${NC}"
echo ""
sleep 1

# ================================================================
# STEP 1: DETECT OS
# ================================================================

progress "Detecting operating system..."

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
echo -e "  ${DIM}→ $PRETTY_NAME ($PKG)${NC}"

# ================================================================
# STEP 2: INSTALL DEPENDENCIES
# ================================================================

progress "Installing dependencies..."

if [ "$PKG" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive

    # Kill any stuck apt/dpkg processes
    killall -9 apt-get 2>/dev/null || true
    killall -9 dpkg 2>/dev/null || true
    sleep 1

    # Fix any broken dpkg state
    dpkg --configure -a >/dev/null 2>&1 || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null

    echo -e "  ${DIM}→ Updating package lists...${NC}"
    apt-get update -y >/dev/null 2>&1 || true

    echo -e "  ${DIM}→ Installing packages...${NC}"
    if ! apt-get install -y build-essential git curl wget net-tools unbound dns-utils openssl >/dev/null 2>&1; then
        warn "First attempt failed — retrying..."
        apt-get update -y >/dev/null 2>&1 || true
        dpkg --configure -a >/dev/null 2>&1 || true
        apt-get install -y -f >/dev/null 2>&1 || true
        if ! apt-get install -y build-essential git curl wget net-tools unbound dns-utils openssl >/dev/null 2>&1; then
            warn "Some packages may have failed"
        fi
    fi
else
    echo -e "  ${DIM}→ Installing packages...${NC}"
    if ! yum install -y -q gcc make git curl wget net-tools unbound bind-utils openssl >/dev/null 2>&1; then
        warn "First attempt failed — retrying..."
        yum clean all >/dev/null 2>&1 || true
        if ! yum install -y -q gcc make git curl wget net-tools unbound bind-utils openssl >/dev/null 2>&1; then
            warn "Some packages may have failed"
        fi
    fi
fi

for cmd in git gcc make curl openssl; do
    if ! command -v $cmd &>/dev/null; then
        fail "Required command '$cmd' not found after install. Run manually:\n\n  apt-get update && apt-get install -y build-essential git curl openssl\n\n  Then re-run this script."
    fi
done
echo -e "  ${DIM}→ build-essential, git, curl, unbound, openssl${NC}"

# ================================================================
# STEP 3: REMOVE OLD PROXY
# ================================================================

progress "Checking for existing proxy installations..."

FOUND_OLD=0

# Go proxy
if systemctl list-unit-files goproxy.service &>/dev/null && systemctl cat goproxy.service &>/dev/null 2>&1; then
    systemctl stop goproxy 2>/dev/null || true
    systemctl disable goproxy 2>/dev/null || true
    rm -f /etc/systemd/system/goproxy.service
    FOUND_OLD=1
    echo -e "  ${DIM}→ Go proxy service removed${NC}"
fi
rm -rf /opt/proxy 2>/dev/null

# 3proxy
if systemctl list-unit-files 3proxy.service &>/dev/null && systemctl cat 3proxy.service &>/dev/null 2>&1; then
    systemctl stop 3proxy 2>/dev/null || true
    systemctl disable 3proxy 2>/dev/null || true
    rm -f /etc/systemd/system/3proxy.service
    FOUND_OLD=1
    echo -e "  ${DIM}→ 3proxy service removed${NC}"
fi
rm -f /usr/local/bin/3proxy 2>/dev/null
rm -rf /etc/3proxy 2>/dev/null
rm -rf /tmp/3proxy 2>/dev/null

# Squid
if command -v squid &>/dev/null || systemctl cat squid.service &>/dev/null 2>&1; then
    systemctl stop squid 2>/dev/null || true
    systemctl disable squid 2>/dev/null || true
    if [ "$PKG" = "apt" ]; then
        apt-get purge -y squid squid-common >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    else
        yum remove -y squid >/dev/null 2>&1 || true
    fi
    rm -rf /etc/squid /var/log/squid /var/spool/squid 2>/dev/null
    FOUND_OLD=1
    echo -e "  ${DIM}→ Squid removed${NC}"
fi

# Dante (SOCKS proxy)
if command -v sockd &>/dev/null || systemctl cat danted.service &>/dev/null 2>&1; then
    systemctl stop danted 2>/dev/null || true
    systemctl disable danted 2>/dev/null || true
    if [ "$PKG" = "apt" ]; then
        apt-get purge -y dante-server >/dev/null 2>&1 || true
    else
        yum remove -y dante-server >/dev/null 2>&1 || true
    fi
    FOUND_OLD=1
    echo -e "  ${DIM}→ Dante SOCKS proxy removed${NC}"
fi

# Privoxy
if command -v privoxy &>/dev/null || systemctl cat privoxy.service &>/dev/null 2>&1; then
    systemctl stop privoxy 2>/dev/null || true
    systemctl disable privoxy 2>/dev/null || true
    if [ "$PKG" = "apt" ]; then
        apt-get purge -y privoxy >/dev/null 2>&1 || true
    else
        yum remove -y privoxy >/dev/null 2>&1 || true
    fi
    FOUND_OLD=1
    echo -e "  ${DIM}→ Privoxy removed${NC}"
fi

# Tinyproxy
if command -v tinyproxy &>/dev/null || systemctl cat tinyproxy.service &>/dev/null 2>&1; then
    systemctl stop tinyproxy 2>/dev/null || true
    systemctl disable tinyproxy 2>/dev/null || true
    if [ "$PKG" = "apt" ]; then
        apt-get purge -y tinyproxy >/dev/null 2>&1 || true
    else
        yum remove -y tinyproxy >/dev/null 2>&1 || true
    fi
    FOUND_OLD=1
    echo -e "  ${DIM}→ Tinyproxy removed${NC}"
fi

# Cleanup leftover proxy management command and banner
rm -f /usr/local/bin/proxy 2>/dev/null
rm -f /etc/profile.d/proxy-banner.sh 2>/dev/null

systemctl daemon-reload 2>/dev/null || true

if [ "$FOUND_OLD" -eq 0 ]; then
    echo -e "  ${DIM}→ No existing proxy found — clean slate${NC}"
else
    echo -e "  ${DIM}→ Cleanup complete${NC}"
fi

# ================================================================
# STEP 4: BUILD 3PROXY
# ================================================================

progress "Building 3proxy from source..."

cd /tmp
rm -rf 3proxy

echo -e "  ${DIM}→ Cloning repository...${NC}"
if ! git clone --depth 1 https://github.com/3proxy/3proxy.git >/dev/null 2>&1; then
    fail "Failed to clone 3proxy. Check network/DNS."
fi

echo -e "  ${DIM}→ Compiling (this may take 15-20s)...${NC}"
cd /tmp/3proxy
if ! make -f Makefile.Linux >/dev/null 2>&1; then
    fail "Failed to compile 3proxy. Check build-essential."
fi

cp bin/3proxy /usr/local/bin/3proxy
chmod +x /usr/local/bin/3proxy
cd /
rm -rf /tmp/3proxy

echo -e "  ${DIM}→ Installed: /usr/local/bin/3proxy ($(ls -lh /usr/local/bin/3proxy | awk '{print $5}'))${NC}"

# ================================================================
# STEP 5: CONFIGURE 3PROXY
# ================================================================

progress "Writing 3proxy configuration..."

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
echo -e "  ${DIM}→ /etc/3proxy/3proxy.cfg${NC}"

# ================================================================
# STEP 6: DNS CACHE
# ================================================================

progress "Configuring Unbound DNS cache..."

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

systemctl restart unbound >/dev/null 2>&1
systemctl enable unbound >/dev/null 2>&1
echo -e "  ${DIM}→ 128MB msg cache, 256MB rrset cache, prefetch enabled${NC}"

# ================================================================
# STEP 7: KERNEL TUNING
# ================================================================

progress "Tuning kernel for high concurrency..."

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

sysctl -p /etc/sysctl.d/99-proxy-tuning.conf >/dev/null 2>&1 || true

cat > /etc/security/limits.d/99-proxy.conf << 'LIMITS'
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
*    soft    nproc     131072
*    hard    nproc     131072
LIMITS

echo -e "  ${DIM}→ BBR, 2M file descriptors, 2M conntrack, TCP fastopen${NC}"

# ================================================================
# STEP 8: SYSTEMD + FIREWALL
# ================================================================

progress "Setting up systemd service & firewall..."

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
systemctl enable 3proxy >/dev/null 2>&1

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow ${PROXY_PORT}/tcp >/dev/null 2>&1 || true
    echo "y" | ufw enable >/dev/null 2>&1 || true
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${PROXY_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
else
    iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport ${PROXY_PORT} -j ACCEPT 2>/dev/null || true
fi

echo -e "  ${DIM}→ Service enabled, port ${PROXY_PORT}/tcp allowed${NC}"

# ================================================================
# STEP 9: SSH BANNER + MANAGEMENT
# ================================================================

progress "Installing SSH banner & management tools..."

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
chmod -x /etc/update-motd.d/* 2>/dev/null || true

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
echo -e "  ${DIM}→ /etc/profile.d/proxy-banner.sh${NC}"
echo -e "  ${DIM}→ /usr/local/bin/proxy${NC}"

# ================================================================
# STEP 10: VERIFY
# ================================================================

progress "Verifying installation..."

sleep 2

if ! systemctl is-active --quiet 3proxy; then
    fail "3proxy failed to start! Check: journalctl -u 3proxy -n 20"
fi

SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')

HTTP_TEST=$(curl -s -o /dev/null -w "%{http_code}" -x http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT} http://httpbin.org/ip --connect-timeout 10 --max-time 15 2>/dev/null)
HTTPS_TEST=$(curl -s -o /dev/null -w "%{http_code}" -x http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT} https://httpbin.org/ip --connect-timeout 10 --max-time 15 2>/dev/null)
AUTH_TEST=$(curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:${PROXY_PORT} http://httpbin.org/ip --connect-timeout 10 --max-time 15 2>/dev/null)

if [ "$HTTP_TEST" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} HTTP proxy       ${GREEN}PASS${NC}"
else
    echo -e "  ${RED}✗${NC} HTTP proxy       ${RED}FAIL${NC}"
fi

if [ "$HTTPS_TEST" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} HTTPS (CONNECT)  ${GREEN}PASS${NC}"
else
    echo -e "  ${RED}✗${NC} HTTPS (CONNECT)  ${RED}FAIL${NC}"
fi

if [ "$AUTH_TEST" = "407" ]; then
    echo -e "  ${GREEN}✓${NC} Auth required    ${GREEN}PASS${NC}"
else
    echo -e "  ${RED}✗${NC} Auth required    ${RED}FAIL${NC}"
fi

END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))
TOTAL_MINS=$((TOTAL_ELAPSED / 60))
TOTAL_SECS=$((TOTAL_ELAPSED % 60))

echo ""
echo ""
echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}        ${GREEN}INSTALLATION COMPLETE${NC}                 ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}        ${DIM}Finished in ${TOTAL_MINS}m${TOTAL_SECS}s${NC}                      ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${WHITE}Engine:${NC}    3proxy (compiled)                ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${WHITE}Server:${NC}    ${SERVER_IP}:${PROXY_PORT}$(printf '%*s' $((17 - ${#SERVER_IP} - ${#PROXY_PORT})) '')${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${WHITE}Username:${NC}  ${PROXY_USER}$(printf '%*s' $((25 - ${#PROXY_USER})) '')${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${WHITE}Password:${NC}  ${PROXY_PASS}$(printf '%*s' $((25 - ${#PROXY_PASS})) '')${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${WHITE}Proxy URL:${NC}                                 ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${YELLOW}http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT}${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${WHITE}Max Conns:${NC} 50,000                           ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${WHITE}DNS Cache:${NC} Unbound (local)                  ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${YELLOW}proxy${NC}                    change settings    ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${DIM}systemctl status 3proxy${NC}  check status       ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${DIM}systemctl restart 3proxy${NC} restart             ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  ${DIM}journalctl -u 3proxy -f${NC}  live logs           ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
