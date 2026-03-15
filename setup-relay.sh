#!/bin/bash
# setup-relay.sh — One-time setup of a fresh relay (Russia) server
#
# Usage: run on a fresh Ubuntu server that will be the TCP relay
#   curl -sL <url> | bash
#   or: ./setup-relay.sh
#
# What it does:
#   1. Installs dependencies (sshpass, iptables-persistent)
#   2. Enables IP forwarding permanently
#   3. Creates the iptables chain script + systemd service
#   4. Downloads Xray binary (for chain testing only)
#   5. Creates /opt/vpn-deploy/ directory structure

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run as root"

echo "============================================"
echo "  VPN Relay Server Setup"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
echo "[1/5] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq sshpass unzip wget > /dev/null 2>&1
log "Dependencies installed"

# ---------------------------------------------------------------------------
# 2. IP forwarding
# ---------------------------------------------------------------------------
echo "[2/5] Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward
cat > /etc/sysctl.d/99-vpn-forward.conf << 'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-vpn-forward.conf > /dev/null 2>&1
log "IP forwarding enabled (persistent)"

# ---------------------------------------------------------------------------
# 3. iptables chain script + systemd service
# ---------------------------------------------------------------------------
echo "[3/5] Creating iptables chain script..."

mkdir -p /opt/vpn-chain

cat > /opt/vpn-chain/iptables-chain.sh << 'CHAIN_EOF'
#!/bin/bash
# VPN Chain iptables rules
# Forwards relay ports -> exit server via DNAT

LATVIA_IP="EXIT_IP_PLACEHOLDER"
DEST_PORT="8443"
PORTS=(443 8444)

remove_all() {
    local table="$1"; shift
    while iptables $table -D "$@" 2>/dev/null; do :; done
}

add_if_missing() {
    local table=$1; shift
    if ! iptables $table -C "$@" 2>/dev/null; then
        iptables $table -A "$@"
    fi
}

case "${1:-}" in
    start)
        echo "Adding VPN chain rules (exit: $LATVIA_IP)..."
        echo 1 > /proc/sys/net/ipv4/ip_forward

        for PORT in "${PORTS[@]}"; do
            add_if_missing "-t nat" PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination "${LATVIA_IP}:${DEST_PORT}"
        done
        add_if_missing "-t nat" POSTROUTING -d "$LATVIA_IP" -p tcp --dport "$DEST_PORT" -j MASQUERADE
        add_if_missing "" FORWARD -d "$LATVIA_IP" -p tcp --dport "$DEST_PORT" -j ACCEPT
        add_if_missing "" FORWARD -s "$LATVIA_IP" -p tcp --sport "$DEST_PORT" -j ACCEPT

        echo "VPN chain rules applied (ports: ${PORTS[*]})."
        ;;
    stop)
        echo "Removing VPN chain rules..."
        for PORT in "${PORTS[@]}"; do
            remove_all "-t nat" PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination "${LATVIA_IP}:${DEST_PORT}"
        done
        remove_all "-t nat" POSTROUTING -d "$LATVIA_IP" -p tcp --dport "$DEST_PORT" -j MASQUERADE
        remove_all "" FORWARD -d "$LATVIA_IP" -p tcp --dport "$DEST_PORT" -j ACCEPT
        remove_all "" FORWARD -s "$LATVIA_IP" -p tcp --sport "$DEST_PORT" -j ACCEPT
        echo "VPN chain rules removed."
        ;;
    status)
        echo "=== NAT PREROUTING ==="
        iptables -t nat -L PREROUTING -n --line-numbers
        echo "=== NAT POSTROUTING ==="
        iptables -t nat -L POSTROUTING -n --line-numbers
        echo "=== FORWARD ==="
        iptables -L FORWARD -n --line-numbers
        echo "=== IP FORWARD ==="
        cat /proc/sys/net/ipv4/ip_forward
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
CHAIN_EOF

chmod +x /opt/vpn-chain/iptables-chain.sh

# Set FORWARD policy to DROP (only VPN traffic allowed)
iptables -P FORWARD DROP

cat > /etc/systemd/system/vpn-chain.service << 'SVC_EOF'
[Unit]
Description=VPN Chain iptables rules
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/vpn-chain/iptables-chain.sh start
ExecStop=/opt/vpn-chain/iptables-chain.sh stop

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable vpn-chain >/dev/null 2>&1
log "iptables chain script and systemd service created"

# ---------------------------------------------------------------------------
# 4. Xray binary (for testing from relay)
# ---------------------------------------------------------------------------
echo "[4/5] Downloading Xray binary for chain testing..."
if [ ! -f /tmp/xray ]; then
    cd /tmp
    wget -q "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -O xray.zip
    unzip -o xray.zip xray > /dev/null 2>&1
    chmod +x /tmp/xray
    rm -f xray.zip
fi
log "Xray test binary ready: /tmp/xray"

# ---------------------------------------------------------------------------
# 5. Deploy directory
# ---------------------------------------------------------------------------
echo "[5/5] Creating deploy directory..."
mkdir -p /opt/vpn-deploy
log "Deploy directory: /opt/vpn-deploy/"

echo ""
echo "============================================"
echo -e "  ${GREEN}RELAY SERVER READY${NC}"
echo "============================================"
echo ""
echo "  Next steps:"
echo "  1. Copy deploy.sh and config.env to /opt/vpn-deploy/"
echo "  2. Run: /opt/vpn-deploy/deploy.sh <exit_ip> <exit_password>"
echo ""
