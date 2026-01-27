#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Starting Agent Service Plus Installation...${NC}"

# Check arguments for Domain
DOMAIN=$1
if [ -z "$DOMAIN" ]; then
    # Try using system hostname if not provided
    HOSTNAME=$(hostname)
    echo -e "${YELLOW}No domain provided. Using system hostname: ${HOSTNAME}${NC}"
    DOMAIN=$HOSTNAME
fi

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Domain is required.${NC}"
    exit 1
fi

echo -e "${GREEN}Using domain: ${DOMAIN}${NC}"

# 1. System Update & Dependencies
echo -e "${GREEN}[1/7] Updating system and installing dependencies...${NC}"
apt-get update && apt-get install -y curl wget git socat build-essential debian-keyring debian-archive-keyring apt-transport-https

# 2. Xray Installation
echo -e "${GREEN}[2/7] Installing Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 3. Go & Caddy Installation
echo -e "${GREEN}[3/7] Installing Go and building Caddy with DNS plugins...${NC}"

# Install Go
if ! command -v go &> /dev/null; then
    wget https://go.dev/dl/go1.23.4.linux-amd64.tar.gz -O /tmp/go.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
fi
go version

# Install xcaddy
if ! command -v xcaddy &> /dev/null; then
    wget https://github.com/caddyserver/xcaddy/releases/download/v0.4.5/xcaddy_0.4.5_linux_amd64.deb -O /tmp/xcaddy.deb
    dpkg -i /tmp/xcaddy.deb
fi

# Build Caddy
if ! command -v caddy &> /dev/null; then
    xcaddy build \
        --with github.com/caddy-dns/cloudflare \
        --with github.com/caddy-dns/alidns \
        --output /usr/bin/caddy
fi

caddy version

# 4. Configuration Directories
echo -e "${GREEN}[4/7] Setting up configuration directories...${NC}"
mkdir -p /usr/local/etc/xray
mkdir -p /etc/caddy
mkdir -p /etc/ssl/agent
mkdir -p /etc/agent

# 5. Agent Installation
echo -e "${GREEN}[5/7] Installing Agent Service...${NC}"
git clone https://github.com/cloud-neutral-toolkit/agent.svc.plus.git /opt/agent.svc.plus || (cd /opt/agent.svc.plus && git pull)
cd /opt/agent.svc.plus
go mod tidy
go build -o /usr/local/bin/agent-svc-plus ./cmd/agent

# Copy default config if not exists
if [ ! -f /etc/agent/account-agent.yaml ]; then
    cp account-agent.yaml /etc/agent/account-agent.yaml
fi

# Copy templates
mkdir -p /usr/local/etc/xray/templates
cp config/*.template.json /usr/local/etc/xray/templates/

# Update config to point to templates (simple sed if needed, or rely on user to edit)
# For now we assume the default config matches or we adjust the copied config
sed -i 's|config/xray.xhttp.template.json|/usr/local/etc/xray/templates/xray.xhttp.template.json|g' /etc/agent/account-agent.yaml
sed -i 's|config/xray.tcp.template.json|/usr/local/etc/xray/templates/xray.tcp.template.json|g' /etc/agent/account-agent.yaml


# 6. Caddy Configuration
echo -e "${GREEN}[6/7] Configuration Caddyfile...${NC}"
cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN}:443 {
    @grpc {
        path /split/*
    }

    handle @grpc {
        reverse_proxy unix//dev/shm/xray.sock {
             transport h2c
        }
    }

    # Fallback/Default site content
    respond "Agent Service Plus Node"
}
EOF

# 7. Systemd Services
echo -e "${GREEN}[7/7] Installing Systemd Services...${NC}"

# Xray Service (XHTTP/Default)
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (XHTTP)
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
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray/

[Install]
WantedBy=multi-user.target
EOF

# Xray TCP Service
cat > /etc/systemd/system/xray-tcp.service <<EOF
[Unit]
Description=Xray Service (TCP)
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/tcp-config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray/

[Install]
WantedBy=multi-user.target
EOF

# Agent Service
cat > /etc/systemd/system/agent-svc-plus.service <<EOF
[Unit]
Description=Agent Service Plus
After=network.target

[Service]
ExecStart=/usr/local/bin/agent-svc-plus -config /etc/agent/account-agent.yaml
Restart=always
User=root
WorkingDirectory=/opt/agent.svc.plus

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl enable xray-tcp
systemctl enable caddy
systemctl enable agent-svc-plus

echo -e "${GREEN}Installation Complete!${NC}"
echo -e "IMPORTANT: Edit /etc/agent/account-agent.yaml with your AGENT ID and TOKEN."
echo -e "Then run: systemctl start agent-svc-plus"
