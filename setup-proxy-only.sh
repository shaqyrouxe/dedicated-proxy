#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          High-Concurrency Rotating Proxy Installer          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Multi-worker  │  IP Rotation  │  Upstream Chaining         ║"
echo "║  uvloop        │  DNS Cache    │  BBR Congestion Control    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${BOLD}Server detected IP:${NC} ${GREEN}${SERVER_IP}${NC}"
echo ""

read -rp "Proxy port [8088]: " PROXY_PORT < /dev/tty
PROXY_PORT=${PROXY_PORT:-8088}

read -rp "Proxy username [proxyuser]: " PROXY_USER < /dev/tty
PROXY_USER=${PROXY_USER:-proxyuser}

DEFAULT_PASS=$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)
read -rp "Proxy password [${DEFAULT_PASS}]: " PROXY_PASS < /dev/tty
PROXY_PASS=${PROXY_PASS:-$DEFAULT_PASS}

read -rp "Local IPs for rotation (comma-separated, blank = server IP only): " IP_INPUT < /dev/tty
if [ -z "$IP_INPUT" ]; then
    IP_POOL=("$SERVER_IP")
else
    IFS=',' read -ra IP_POOL <<< "$IP_INPUT"
    for i in "${!IP_POOL[@]}"; do
        IP_POOL[$i]=$(echo "${IP_POOL[$i]}" | tr -d ' ')
    done
fi

echo ""
echo -e "${BOLD}Configuration Summary:${NC}"
echo -e "  Port     : ${GREEN}${PROXY_PORT}${NC}"
echo -e "  Username : ${GREEN}${PROXY_USER}${NC}"
echo -e "  Password : ${GREEN}${PROXY_PASS}${NC}"
echo -e "  IP Pool  : ${GREEN}${IP_POOL[*]}${NC}"
echo ""
read -rp "Proceed with installation? [Y/n]: " CONFIRM < /dev/tty
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Aborted."; exit 1
fi

echo ""
echo -e "${CYAN}[1/7] Updating system & installing dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv iptables curl net-tools lsof > /dev/null 2>&1
pip3 install uvloop 2>/dev/null || pip3 install --break-system-packages uvloop 2>/dev/null || true
echo -e "  ${GREEN}Done${NC}"

echo -e "${CYAN}[2/7] Applying kernel tuning for high concurrency...${NC}"
cat > /etc/sysctl.d/99-proxy-tuning.conf << 'SYSCTL'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.nf_conntrack_max = 1048576
SYSCTL

modprobe nf_conntrack 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-proxy-tuning.conf > /dev/null 2>&1

if modprobe tcp_bbr 2>/dev/null; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
    echo -e "  ${GREEN}BBR congestion control enabled${NC}"
fi

cat > /etc/security/limits.d/99-proxy.conf << 'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS

ulimit -n 1048576 2>/dev/null || true
echo -e "  ${GREEN}Done${NC}"

echo -e "${CYAN}[3/7] Binding IP addresses to network interface...${NC}"
IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
for IP in "${IP_POOL[@]}"; do
    if [ "$IP" != "$SERVER_IP" ]; then
        if ! ip addr show dev "$IFACE" | grep -q "$IP"; then
            ip addr add "${IP}/32" dev "$IFACE" 2>/dev/null || true
            echo -e "  Added ${GREEN}${IP}${NC} to ${IFACE}"
        else
            echo -e "  ${IP} already bound"
        fi
    else
        echo -e "  ${IP} (primary — already active)"
    fi
done
echo -e "  ${GREEN}Done${NC}"

echo -e "${CYAN}[4/7] Stopping any existing proxy services...${NC}"
systemctl stop rotproxy 2>/dev/null || true
systemctl disable rotproxy 2>/dev/null || true
systemctl stop 3proxy 2>/dev/null || true
systemctl disable 3proxy 2>/dev/null || true
kill $(lsof -t -i:"${PROXY_PORT}") 2>/dev/null || true
sleep 1
echo -e "  ${GREEN}Done${NC}"

echo -e "${CYAN}[5/7] Deploying proxy server...${NC}"
mkdir -p /usr/local/proxy/bin /usr/local/proxy/conf

cat > /usr/local/proxy/bin/rotproxy.py << 'PROXYEOF'
#!/usr/bin/env python3
import asyncio, base64, itertools, json, logging, multiprocessing
import os, signal, socket, sys, time
from urllib.parse import urlparse

LISTEN      = os.getenv("PROXY_LISTEN", "0.0.0.0")
PORT        = int(os.getenv("PROXY_PORT", "8088"))
AUTH_USER   = os.getenv("PROXY_USER", "proxyuser")
AUTH_PASS   = os.getenv("PROXY_PASS", "changeme")
POOL_FILE   = os.getenv("PROXY_POOL_FILE", "/usr/local/proxy/conf/pool.json")
WORKERS     = int(os.getenv("PROXY_WORKERS", "0"))
BUF         = 262144
TIMEOUT     = 15
DNS_TTL     = 300

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [w%(process)d] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S")
log = logging.getLogger("rotproxy")

_dns_cache = {}

async def cached_resolve(host, port):
    key = f"{host}:{port}"; now = time.monotonic()
    if key in _dns_cache:
        result, ts = _dns_cache[key]
        if now - ts < DNS_TTL:
            return result
    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, port, family=socket.AF_INET, type=socket.SOCK_STREAM)
    if not infos:
        raise ConnectionError(f"Cannot resolve {host}")
    _dns_cache[key] = (infos, now)
    if len(_dns_cache) > 10000:
        cutoff = now - DNS_TTL
        for k in [k for k, (_, ts) in _dns_cache.items() if ts < cutoff]:
            del _dns_cache[k]
    return infos

RESP_407 = b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Proxy\"\r\nContent-Length: 0\r\n\r\n"
RESP_400 = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
RESP_502 = b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
RESP_200 = b"HTTP/1.1 200 Connection Established\r\n\r\n"
RESP_431 = b"HTTP/1.1 431 Header Too Large\r\nContent-Length: 0\r\n\r\n"

def check_auth_fast(hdrs):
    raw = hdrs.get(b"proxy-authorization", b"")
    if not raw: return False
    try:
        _, blob = raw.split(None, 1)
        return base64.b64decode(blob).decode() == f"{AUTH_USER}:{AUTH_PASS}"
    except Exception: return False

def parse_headers_fast(raw):
    hdrs = {}
    for line in raw.split(b"\r\n"):
        idx = line.find(b":")
        if idx > 0:
            hdrs[line[:idx].strip().lower()] = line[idx+1:].strip()
    return hdrs

pool_entries = []
pool_cycle = None

def load_pool():
    global pool_entries, pool_cycle
    try:
        with open(POOL_FILE) as f:
            data = json.load(f)
        entries = data if isinstance(data, list) else data.get("proxies", [])
        pool_entries = [e for e in entries if e.get("enabled", True)]
        if pool_entries:
            pool_cycle = itertools.cycle(pool_entries)
            log.info("Loaded %d pool entries from %s", len(pool_entries), POOL_FILE)
            for e in pool_entries:
                if e.get("type") == "local":
                    log.info("  Local IP: %s", e.get("ip"))
                else:
                    log.info("  Upstream: %s:%s", e.get("host"), e.get("port"))
        else:
            log.warning("Pool is empty!"); pool_cycle = None
    except FileNotFoundError:
        log.warning("Pool file not found: %s", POOL_FILE)
        ip_str = os.getenv("PROXY_IP_POOL", "")
        ips = [ip.strip() for ip in ip_str.split(",") if ip.strip()]
        pool_entries = [{"type":"local","ip":ip,"id":str(i),"enabled":True} for i,ip in enumerate(ips)]
        pool_cycle = itertools.cycle(pool_entries) if pool_entries else None
    except Exception as exc:
        log.error("Failed to load pool: %s", exc); pool_cycle = None

def next_entry():
    if pool_cycle is None: return None
    return next(pool_cycle)

async def open_remote_local(host, port, source_ip):
    loop = asyncio.get_running_loop()
    infos = await cached_resolve(host, port)
    af, stype, proto, _, sa = infos[0]
    sock = socket.socket(af, stype, proto)
    sock.setblocking(False)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try: sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
    except (AttributeError, OSError): pass
    sock.bind((source_ip, 0))
    await asyncio.wait_for(loop.sock_connect(sock, sa), timeout=TIMEOUT)
    return await asyncio.open_connection(sock=sock)

async def open_upstream_connect(target_host, target_port, entry):
    ur, uw = await asyncio.wait_for(
        asyncio.open_connection(entry["host"], int(entry["port"])), timeout=TIMEOUT)
    connect_req = f"CONNECT {target_host}:{target_port} HTTP/1.1\r\nHost: {target_host}:{target_port}\r\n"
    up_user = entry.get("username", "")
    up_pass = entry.get("password", "")
    if up_user:
        cred = base64.b64encode(f"{up_user}:{up_pass}".encode()).decode()
        connect_req += f"Proxy-Authorization: Basic {cred}\r\n"
    connect_req += "\r\n"
    uw.write(connect_req.encode()); await uw.drain()
    resp_line = await asyncio.wait_for(ur.readline(), timeout=TIMEOUT)
    if b"200" not in resp_line:
        uw.close()
        raise ConnectionError(f"Upstream CONNECT failed: {resp_line.decode(errors='replace').strip()}")
    while True:
        hdr = await asyncio.wait_for(ur.readline(), timeout=TIMEOUT)
        if hdr in (b"\r\n", b"\n", b""): break
    return ur, uw

async def open_upstream_http(target_host, target_port, entry):
    ur, uw = await asyncio.wait_for(
        asyncio.open_connection(entry["host"], int(entry["port"])), timeout=TIMEOUT)
    return ur, uw

async def relay(reader, writer):
    try:
        while True:
            data = await reader.read(BUF)
            if not data: break
            writer.write(data)
            if writer.transport.get_write_buffer_size() > BUF:
                await writer.drain()
        if writer.transport and not writer.transport.is_closing():
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError, OSError,
            asyncio.IncompleteReadError, AttributeError): pass
    finally:
        try:
            if not writer.is_closing(): writer.close()
        except Exception: pass

async def handle(cr, cw):
    rw = None
    try:
        sock = cw.get_extra_info("socket")
        if sock: sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client_addr = cw.get_extra_info("peername", ("?", 0))
        req_line = await asyncio.wait_for(cr.readline(), timeout=30)
        if not req_line: return
        hdr_buf = b""
        while True:
            line = await asyncio.wait_for(cr.readline(), timeout=30)
            if line in (b"\r\n", b"\n", b""): break
            hdr_buf += line
            if len(hdr_buf) > 65536: cw.write(RESP_431); return
        hdrs = parse_headers_fast(hdr_buf)
        if not check_auth_fast(hdrs):
            cw.write(RESP_407); await cw.drain(); return
        parts = req_line.split(None, 2)
        if len(parts) < 2: cw.write(RESP_400); return
        method = parts[0]; target = parts[1].decode(errors="replace")
        entry = next_entry()
        if entry is None: cw.write(RESP_502); await cw.drain(); return
        etype = entry.get("type", "local")
        elabel = entry.get("ip") if etype == "local" else f"{entry.get('host','?')}:{entry.get('port','?')}"
        if method == b"CONNECT":
            host, _, port = target.rpartition(":")
            port = int(port) if port else 443
            try:
                if etype == "local": rr, rw = await open_remote_local(host, port, entry["ip"])
                else: rr, rw = await open_upstream_connect(host, port, entry)
            except Exception: cw.write(RESP_502); await cw.drain(); return
            log.info("%s -> %s:%s via %s (CONNECT)", client_addr[0], host, port, elabel)
            cw.write(RESP_200); await cw.drain()
            await asyncio.gather(relay(cr, rw), relay(rr, cw), return_exceptions=True)
        else:
            parsed = urlparse(target)
            host = parsed.hostname or ""; port = parsed.port or 80
            path = parsed.path or "/"
            if parsed.query: path += "?" + parsed.query
            try:
                if etype == "local":
                    rr, rw = await open_remote_local(host, port, entry["ip"])
                    log.info("%s -> %s:%s via %s (%s)", client_addr[0], host, port, elabel, method.decode(errors="replace"))
                    fwd = bytearray(method + b" " + path.encode() + b" HTTP/1.1\r\n")
                    for raw_line in hdr_buf.split(b"\r\n"):
                        if raw_line:
                            k = raw_line.split(b":", 1)[0].lower()
                            if k not in (b"proxy-authorization", b"proxy-connection"):
                                fwd.extend(raw_line + b"\r\n")
                    if b"host" not in hdrs: fwd.extend(f"Host: {host}\r\n".encode())
                    fwd.extend(b"\r\n"); rw.write(fwd); await rw.drain()
                else:
                    rr, rw = await open_upstream_http(host, port, entry)
                    log.info("%s -> %s:%s via %s (%s)", client_addr[0], host, port, elabel, method.decode(errors="replace"))
                    fwd = bytearray(method + b" " + target.encode() + b" HTTP/1.1\r\n")
                    up_user = entry.get("username", ""); up_pass = entry.get("password", "")
                    if up_user:
                        cred = base64.b64encode(f"{up_user}:{up_pass}".encode()).decode()
                        fwd.extend(f"Proxy-Authorization: Basic {cred}\r\n".encode())
                    for raw_line in hdr_buf.split(b"\r\n"):
                        if raw_line:
                            k = raw_line.split(b":", 1)[0].lower()
                            if k not in (b"proxy-authorization", b"proxy-connection"):
                                fwd.extend(raw_line + b"\r\n")
                    if b"host" not in hdrs: fwd.extend(f"Host: {host}\r\n".encode())
                    fwd.extend(b"\r\n"); rw.write(fwd); await rw.drain()
            except Exception: cw.write(RESP_502); await cw.drain(); return
            await relay(rr, cw)
    except (ConnectionError, asyncio.CancelledError, asyncio.TimeoutError, OSError): pass
    except Exception as exc: log.error("handle error: %s", exc)
    finally:
        for w in (cw, rw):
            if w is not None:
                try:
                    if not w.is_closing(): w.close()
                except Exception: pass

def run_worker(wid):
    try: import uvloop; uvloop.install()
    except ImportError: pass
    load_pool()
    async def _serve():
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.bind((LISTEN, PORT)); sock.listen(65535); sock.setblocking(False)
        srv = await asyncio.start_server(handle, sock=sock, backlog=65535)
        log.info("Worker %d listening on %s:%d", wid, LISTEN, PORT)
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGHUP, load_pool)
        async with srv: await srv.serve_forever()
    asyncio.run(_serve())

def main():
    nw = WORKERS if WORKERS > 0 else multiprocessing.cpu_count()
    load_pool()
    log.info("Starting %d workers | %d pool entries | Port: %d", nw, len(pool_entries), PORT)
    children = []
    for i in range(nw):
        p = multiprocessing.Process(target=run_worker, args=(i,), daemon=True)
        p.start(); children.append(p)
    def shutdown(sig, frame):
        log.info("Shutting down...")
        for p in children: p.terminate()
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    for p in children: p.join()

if __name__ == "__main__":
    main()
PROXYEOF

chmod +x /usr/local/proxy/bin/rotproxy.py
echo -e "  ${GREEN}Proxy code deployed${NC}"

# ── Build pool.json ──────────────────────────────────────────────────
POOL_JSON="["
FIRST=true
for IP in "${IP_POOL[@]}"; do
    ID=$(head -c 4 /dev/urandom | xxd -p)
    if [ "$FIRST" = true ]; then FIRST=false; else POOL_JSON="${POOL_JSON},"; fi
    POOL_JSON="${POOL_JSON}{\"id\":\"${ID}\",\"type\":\"local\",\"ip\":\"${IP}\",\"label\":\"\",\"enabled\":true}"
done
POOL_JSON="${POOL_JSON}]"

echo "$POOL_JSON" | python3 -m json.tool > /usr/local/proxy/conf/pool.json
echo -e "  ${GREEN}Pool config written (${#IP_POOL[@]} entries)${NC}"
echo -e "  ${GREEN}Done${NC}"

echo -e "${CYAN}[6/7] Creating systemd service...${NC}"
cat > /etc/systemd/system/rotproxy.service << SVCEOF
[Unit]
Description=High-Concurrency Rotating Proxy
After=network.target

[Service]
Type=simple
Environment=PROXY_PORT=${PROXY_PORT}
Environment=PROXY_USER=${PROXY_USER}
Environment=PROXY_PASS=${PROXY_PASS}
Environment=PROXY_POOL_FILE=/usr/local/proxy/conf/pool.json
ExecStart=/usr/bin/python3 /usr/local/proxy/bin/rotproxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=65535
KillMode=process

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable rotproxy
systemctl start rotproxy
sleep 2
echo -e "  ${GREEN}Done${NC}"

echo -e "${CYAN}[7/7] Configuring firewall...${NC}"
iptables -I INPUT -p tcp --dport "${PROXY_PORT}" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
echo -e "  ${GREEN}Done${NC}"

echo ""
echo -e "${CYAN}Verifying proxy...${NC}"
sleep 1

WORKERS_RUNNING=$(pgrep -f rotproxy.py -c 2>/dev/null || echo 0)
if [ "$WORKERS_RUNNING" -gt 0 ]; then
    echo -e "  ${GREEN}Proxy is running (${WORKERS_RUNNING} processes)${NC}"
else
    echo -e "  ${RED}Proxy may not be running. Check: journalctl -u rotproxy -n 20${NC}"
fi

TEST_RESULT=$(curl -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT}" -s --max-time 10 http://httpbin.org/ip 2>/dev/null || echo "FAIL")
if echo "$TEST_RESULT" | grep -q "origin"; then
    ORIGIN=$(echo "$TEST_RESULT" | grep -o '"origin": *"[^"]*"' | head -1)
    echo -e "  ${GREEN}Test passed: ${ORIGIN}${NC}"
else
    echo -e "  ${YELLOW}Test inconclusive. Proxy may still be starting up.${NC}"
fi

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  SETUP COMPLETE${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "  Proxy Address : ${GREEN}${SERVER_IP}:${PROXY_PORT}${NC}"
echo -e "  Username      : ${GREEN}${PROXY_USER}${NC}"
echo -e "  Password      : ${GREEN}${PROXY_PASS}${NC}"
echo -e "  IP Pool       : ${GREEN}${#IP_POOL[@]} addresses${NC}"
echo -e "  Workers       : ${GREEN}$(nproc) (1 per CPU)${NC}"
echo -e "  Rotation      : ${GREEN}Per-request round-robin${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}Test:${NC}"
echo -e "  curl -x http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT} http://httpbin.org/ip"
echo -e "  curl -x http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT} https://httpbin.org/ip"
echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}Management:${NC}"
echo -e "  Pool config : /usr/local/proxy/conf/pool.json"
echo -e "  Restart     : systemctl restart rotproxy"
echo -e "  Logs        : journalctl -u rotproxy -f"
echo -e "  Status      : systemctl status rotproxy"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
