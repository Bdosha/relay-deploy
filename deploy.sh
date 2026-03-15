#!/bin/bash
# deploy.sh — Deploy a new VPN exit node from the relay server
#
# Usage:
#   ./deploy.sh <exit_server_ip> <exit_server_root_password>
#
# What it does:
#   1. Installs Xray on the exit server
#   2. Generates fresh Reality keys
#   3. Configures Xray with all users from config.env
#   4. Sets up systemd, logrotate, DNS
#   5. Updates iptables on THIS (relay) server
#   6. Runs a full chain test
#   7. Outputs new VLESS links for all users
#
# Safe to run via nohup: ./deploy.sh IP PASS > deploy.log 2>&1 &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CHAIN_SCRIPT="/opt/vpn-chain/iptables-chain.sh"
TMP_DIR="/tmp/vpn-deploy-$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step() { echo -e "\n${GREEN}[$1/$TOTAL_STEPS]${NC} $2"; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Args & config
# ---------------------------------------------------------------------------

if [ $# -lt 2 ]; then
    echo "Usage: $0 <exit_server_ip> <exit_server_root_password>"
    echo "Example: $0 31.56.117.136 'MyP@ssw0rd'"
    exit 1
fi

EXIT_IP="$1"
EXIT_PASS="$2"
TOTAL_STEPS=10

[ -f "$CONFIG_FILE" ] || fail "Config not found: $CONFIG_FILE"
source "$CONFIG_FILE"

[ "$NUM_USERS" -gt 0 ] 2>/dev/null || fail "NUM_USERS not set in config.env"

RELAY_IP=$(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1)
[ -n "$RELAY_IP" ] || fail "Cannot determine relay server IP"

mkdir -p "$TMP_DIR"

echo "============================================"
echo "  VPN Exit Node Deployment"
echo "============================================"
echo "  Relay (this server): $RELAY_IP"
echo "  Exit server:         $EXIT_IP"
echo "  Users:               $NUM_USERS"
echo "  SNI:                 $SNI"
echo "  Xray port:           $XRAY_PORT"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Helpers — key-based SSH if available, otherwise sshpass
# ---------------------------------------------------------------------------

USE_KEY=false
if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
     root@"$EXIT_IP" true 2>/dev/null; then
    USE_KEY=true
fi

_ssh_opts=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=10)

ssh_exit() {
    if $USE_KEY; then
        ssh "${_ssh_opts[@]}" root@"$EXIT_IP" "$@"
    else
        sshpass -p "$EXIT_PASS" ssh "${_ssh_opts[@]}" root@"$EXIT_IP" "$@"
    fi
}

scp_to_exit() {
    local src="$1" dst="$2"
    if $USE_KEY; then
        scp -o StrictHostKeyChecking=no "$src" root@"$EXIT_IP":"$dst"
    else
        sshpass -p "$EXIT_PASS" scp -o StrictHostKeyChecking=no "$src" root@"$EXIT_IP":"$dst"
    fi
}

remove_all_rules() {
    local table="$1"; shift
    while iptables $table -D "$@" 2>/dev/null; do :; done
}

# ---------------------------------------------------------------------------
# Step 1: Preflight checks
# ---------------------------------------------------------------------------
step 1 "Preflight checks"

command -v sshpass >/dev/null 2>&1 || fail "sshpass not installed. Run: apt install sshpass"
[ -f "$CHAIN_SCRIPT" ]          || fail "Chain script missing: $CHAIN_SCRIPT"

if [ ! -f /tmp/xray ]; then
    warn "/tmp/xray not found — downloading for chain test..."
    cd /tmp
    wget -q "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -O xray.zip
    unzip -o xray.zip xray >/dev/null 2>&1
    chmod +x /tmp/xray
    rm -f xray.zip
fi

if $USE_KEY; then
    log "Auth: SSH key"
else
    log "Auth: password (sshpass)"
fi
log "All preflight checks passed"

# ---------------------------------------------------------------------------
# Step 2: Test SSH to exit server
# ---------------------------------------------------------------------------
step 2 "Testing SSH to $EXIT_IP"

ssh_exit "echo OK" >/dev/null 2>&1 || fail "Cannot SSH to $EXIT_IP — check IP and password"
EXIT_OS=$(ssh_exit "lsb_release -ds 2>/dev/null || head -1 /etc/os-release")
log "Connected. OS: $EXIT_OS"

# ---------------------------------------------------------------------------
# Step 3: Install Xray on exit server
# ---------------------------------------------------------------------------
step 3 "Installing Xray on exit server"

ssh_exit "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq > /dev/null 2>&1; apt-get install -y -qq unzip wget > /dev/null 2>&1; cd /tmp; wget -q 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip' -O xray.zip; unzip -o xray.zip xray geoip.dat geosite.dat -d /usr/local/bin/ > /dev/null 2>&1; chmod +x /usr/local/bin/xray; rm -f xray.zip; mkdir -p /usr/local/etc/xray /var/log/xray; chown nobody:nogroup /var/log/xray 2>/dev/null || chown nobody:nobody /var/log/xray; /usr/local/bin/xray version | head -1"

log "Xray installed"

# ---------------------------------------------------------------------------
# Step 4: Generate Reality keys
# ---------------------------------------------------------------------------
step 4 "Generating Reality keys and $NUM_USERS UUIDs"

KEY_OUTPUT=$(ssh_exit "/usr/local/bin/xray x25519 2>&1")
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "PrivateKey:" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Password:" | awk '{print $2}')
SHORT_ID=$(ssh_exit "openssl rand -hex 8")

[ -n "$PRIVATE_KEY" ] || fail "Failed to generate private key. Output: $KEY_OUTPUT"
[ -n "$PUBLIC_KEY" ]  || fail "Failed to generate public key"
[ -n "$SHORT_ID" ]    || fail "Failed to generate shortId"

UUIDS_RAW=$(ssh_exit "for i in \$(seq 1 $NUM_USERS); do /usr/local/bin/xray uuid; done 2>&1")
UUIDS=()
i=1
while IFS= read -r uuid; do
    [ -n "$uuid" ] || continue
    UUIDS+=("$uuid:User$i")
    i=$((i + 1))
done <<< "$UUIDS_RAW"
[ "${#UUIDS[@]}" -eq "$NUM_USERS" ] || fail "Expected $NUM_USERS UUIDs, got ${#UUIDS[@]}"

log "Private Key: ${PRIVATE_KEY:0:8}..."
log "Public Key:  $PUBLIC_KEY"
log "Short ID:    $SHORT_ID"
log "UUIDs:       ${#UUIDS[@]} generated"

# ---------------------------------------------------------------------------
# Step 5: Create Xray config (build locally, scp to exit)
# ---------------------------------------------------------------------------
step 5 "Creating Xray config with ${#UUIDS[@]} users"

CLIENTS_JSON=""
for entry in "${UUIDS[@]}"; do
    uuid="${entry%%:*}"
    [ -n "$CLIENTS_JSON" ] && CLIENTS_JSON="$CLIENTS_JSON,"
    CLIENTS_JSON="${CLIENTS_JSON}
            {\"flow\": \"xtls-rprx-vision\", \"id\": \"$uuid\"}"
done

cat > "$TMP_DIR/config.json" << XRAY_EOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "dns": {
        "servers": ["8.8.8.8", "1.1.1.1", "localhost"],
        "queryStrategy": "UseIP"
    },
    "fakedns": [
        {"ipPool": "198.18.0.0/15", "poolSize": 65535}
    ],
    "inbounds": [
        {
            "port": $XRAY_PORT,
            "protocol": "vless",
            "settings": {
                "clients": [$CLIENTS_JSON
                ],
                "decryption": "none"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic", "fakedns"],
                "routeOnly": false
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$SNI:443",
                    "privateKey": "$PRIVATE_KEY",
                    "serverNames": ["$SNI"],
                    "shortIds": ["$SHORT_ID"]
                },
                "sockopt": {
                    "tcpKeepAliveInterval": 15
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {"domainStrategy": "UseIP"},
            "tag": "direct"
        }
    ]
}
XRAY_EOF

scp_to_exit "$TMP_DIR/config.json" /usr/local/etc/xray/config.json
log "Config deployed"

# ---------------------------------------------------------------------------
# Step 6: Systemd service (build locally, scp to exit)
# ---------------------------------------------------------------------------
step 6 "Setting up systemd service"

cat > "$TMP_DIR/xray.service" << 'SVC_EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVC_EOF

scp_to_exit "$TMP_DIR/xray.service" /etc/systemd/system/xray.service
ssh_exit "systemctl daemon-reload; systemctl enable xray >/dev/null 2>&1; systemctl restart xray"
sleep 3

ssh_exit "systemctl is-active xray" >/dev/null 2>&1 || {
    warn "Xray failed to start. Logs:"
    ssh_exit "journalctl -u xray --no-pager -n 20" 2>/dev/null
    fail "Xray service not running on exit server"
}

REMOTE_PORT_CHECK=$(ssh_exit "ss -tlnp | grep -c ':$XRAY_PORT '")
[ "$REMOTE_PORT_CHECK" -ge 1 ] || fail "Xray started but port $XRAY_PORT is not listening"

log "Xray running, port $XRAY_PORT listening"

# ---------------------------------------------------------------------------
# Step 7: Logrotate + DNS
# ---------------------------------------------------------------------------
step 7 "Configuring logrotate and DNS"

cat > "$TMP_DIR/xray-logrotate" << 'LR_EOF'
/var/log/xray/access.log
/var/log/xray/error.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LR_EOF

scp_to_exit "$TMP_DIR/xray-logrotate" /etc/logrotate.d/xray

ssh_exit "sed -i 's/^#\\?FallbackDNS=.*/FallbackDNS=8.8.8.8 1.1.1.1 8.8.4.4/' /etc/systemd/resolved.conf; systemctl restart systemd-resolved 2>/dev/null || true"

log "Logrotate and DNS configured"

# ---------------------------------------------------------------------------
# Step 8: Copy SSH key to exit server
# ---------------------------------------------------------------------------
step 8 "Setting up SSH key access to exit server"

PUB_KEY=""
for kf in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [ -f "$kf" ] && { PUB_KEY=$(cat "$kf"); break; }
done

if [ -z "$PUB_KEY" ]; then
    warn "No SSH key found — generating ed25519 key"
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
    PUB_KEY=$(cat /root/.ssh/id_ed25519.pub)
fi

if [ -n "$PUB_KEY" ]; then
    ssh_exit "mkdir -p /root/.ssh; chmod 700 /root/.ssh; echo '$PUB_KEY' >> /root/.ssh/authorized_keys; sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys"
    log "SSH key deployed — relay can now SSH without password"
else
    warn "Could not set up SSH key"
fi

# ---------------------------------------------------------------------------
# Step 9: Update relay iptables
# ---------------------------------------------------------------------------
step 9 "Updating relay iptables (this server)"

OLD_EXIT_IP=$(grep '^LATVIA_IP=' "$CHAIN_SCRIPT" | head -1 | cut -d'"' -f2)

if [ -n "$OLD_EXIT_IP" ] && [ "$OLD_EXIT_IP" != "$EXIT_IP" ]; then
    log "Switching exit IP: $OLD_EXIT_IP → $EXIT_IP"
    for PORT in "${RELAY_PORTS[@]}"; do
        remove_all_rules "-t nat" PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination "${OLD_EXIT_IP}:${XRAY_PORT}"
    done
    remove_all_rules "-t nat" POSTROUTING -d "$OLD_EXIT_IP" -p tcp --dport "$XRAY_PORT" -j MASQUERADE
    remove_all_rules ""       FORWARD -d "$OLD_EXIT_IP" -p tcp --dport "$XRAY_PORT" -j ACCEPT
    remove_all_rules ""       FORWARD -s "$OLD_EXIT_IP" -p tcp --sport "$XRAY_PORT" -j ACCEPT
elif [ "$OLD_EXIT_IP" = "$EXIT_IP" ]; then
    log "Same exit IP — refreshing rules"
    "$CHAIN_SCRIPT" stop 2>/dev/null || true
fi

sed -i "s/^LATVIA_IP=.*/LATVIA_IP=\"$EXIT_IP\"/" "$CHAIN_SCRIPT"
"$CHAIN_SCRIPT" start

echo 1 > /proc/sys/net/ipv4/ip_forward
iptables-save > /etc/iptables/rules.v4

DNAT_OK=$(iptables -t nat -L PREROUTING -n | grep -c "$EXIT_IP" || true)
FWD_OK=$(iptables -L FORWARD -n | grep -c "$EXIT_IP" || true)
[ "$DNAT_OK" -ge 1 ] || fail "DNAT rules not applied"
[ "$FWD_OK" -ge 1 ]  || fail "FORWARD rules not applied"

log "iptables updated and saved (DNAT: $DNAT_OK rules, FORWARD: $FWD_OK rules)"

# ---------------------------------------------------------------------------
# Step 10: Full chain test
# ---------------------------------------------------------------------------
step 10 "Testing full VPN chain"

TCP_OK="FAIL"
if bash -c "exec 3<>/dev/tcp/$EXIT_IP/$XRAY_PORT" 2>/dev/null; then
    TCP_OK="OK"
    exec 3>&- 2>/dev/null
fi
log "TCP relay→exit ($EXIT_IP:$XRAY_PORT): $TCP_OK"
[ "$TCP_OK" = "OK" ] || fail "Cannot reach exit server port $XRAY_PORT from relay"

FIRST_UUID="${UUIDS[0]%%:*}"

python3 -c "
import json
c={
    'log':{'loglevel':'warning'},
    'inbounds':[{'port':10808,'protocol':'socks','settings':{'udp':True}}],
    'outbounds':[{
        'protocol':'vless',
        'settings':{'vnext':[{
            'address':'$EXIT_IP',
            'port':$XRAY_PORT,
            'users':[{'id':'$FIRST_UUID','flow':'xtls-rprx-vision','encryption':'none'}]
        }]},
        'streamSettings':{
            'network':'tcp',
            'security':'reality',
            'realitySettings':{
                'serverName':'$SNI',
                'fingerprint':'$FINGERPRINT',
                'publicKey':'$PUBLIC_KEY',
                'shortId':'$SHORT_ID'
            }
        }
    }]
}
json.dump(c,open('$TMP_DIR/vpn-test.json','w'),indent=2)
"

pkill -f '/tmp/xray run -config.*vpn-test' 2>/dev/null || true
sleep 1

/tmp/xray run -config "$TMP_DIR/vpn-test.json" &>/dev/null &
XRAY_TEST_PID=$!
sleep 3

HTTP_CODE=$(curl -x socks5h://127.0.0.1:10808 --connect-timeout 10 -s -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null || echo "000")

kill $XRAY_TEST_PID 2>/dev/null
wait $XRAY_TEST_PID 2>/dev/null || true

if [ "$HTTP_CODE" = "200" ]; then
    log "VPN chain test: HTTP $HTTP_CODE — SUCCESS"
else
    fail "VPN chain test failed (HTTP $HTTP_CODE). Check: ssh root@$EXIT_IP 'tail -20 /var/log/xray/error.log'"
fi

# ---------------------------------------------------------------------------
# Output VLESS links
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo -e "  ${GREEN}DEPLOYMENT SUCCESSFUL${NC}"
echo "============================================"
echo ""
echo "  Exit server:  $EXIT_IP"
echo "  Relay server: $RELAY_IP"
echo "  Xray port:    $XRAY_PORT"
echo "  Public Key:   $PUBLIC_KEY"
echo "  Short ID:     $SHORT_ID"
echo "  SNI:          $SNI"
echo ""
echo "============================================"
echo "  VLESS LINKS"
echo "============================================"

LINKS_FILE="$SCRIPT_DIR/links-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "# Generated $(date)"
    echo "# Exit: $EXIT_IP | Relay: $RELAY_IP | SNI: $SNI"
    echo "# Public Key: $PUBLIC_KEY"
    echo "# Short ID: $SHORT_ID"
    echo ""
} > "$LINKS_FILE"

for entry in "${UUIDS[@]}"; do
    uuid="${entry%%:*}"
    name="${entry#*:}"
    link="vless://${uuid}@${RELAY_IP}:443?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#${name}"
    echo ""
    echo "--- $name ---"
    echo "$link"
    echo "--- $name ---" >> "$LINKS_FILE"
    echo "$link" >> "$LINKS_FILE"
    echo "" >> "$LINKS_FILE"
done

echo ""
echo "============================================"
echo "  Links saved: $LINKS_FILE"
echo "  All users must update their VLESS config!"
echo "============================================"
