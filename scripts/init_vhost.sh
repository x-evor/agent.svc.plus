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
apt-get update && apt-get install -y curl wget git socat build-essential debian-keyring debian-archive-keyring apt-transport-https dnsutils

# 2. Xray Installation
echo -e "${GREEN}[2/7] Installing Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 3. Go & Caddy Installation
echo -e "${GREEN}[3/7] Installing Go and building Caddy with DNS plugins...${NC}"

# 3. Go & Caddy Installation
echo -e "${GREEN}[3/7] Installing Go and building Caddy with DNS plugins...${NC}"

# Install Go
if ! command -v go &> /dev/null; then
    GO_VER="1.23.4"
    GO_FILE="go${GO_VER}.linux-amd64.tar.gz"
    GO_URL="https://go.dev/dl/${GO_FILE}"
    LOCAL_TAR="/tmp/${GO_FILE}"
    
    NEED_DOWNLOAD=true
    
    if [ -f "$LOCAL_TAR" ]; then
        echo "Found cached Go tarball at $LOCAL_TAR"
        echo "Verifying checksum..."
        # Fetch expected SHA256
        REMOTE_SHA256=$(curl -sL "${GO_URL}.sha256")
        if [ -n "$REMOTE_SHA256" ]; then
            LOCAL_SHA256=$(sha256sum "$LOCAL_TAR" | awk '{print $1}')
            if [ "$LOCAL_SHA256" == "$REMOTE_SHA256" ]; then
                echo -e "${GREEN}Checksum verified. Skipping download.${NC}"
                NEED_DOWNLOAD=false
            else
                echo -e "${YELLOW}Checksum mismatch (Local: $LOCAL_SHA256, Remote: $REMOTE_SHA256). Re-downloading...${NC}"
            fi
        else
            echo "Could not fetch remote checksum. Proceeding with existing file."
            NEED_DOWNLOAD=false
        fi
    fi

    if [ "$NEED_DOWNLOAD" = true ]; then
        wget "$GO_URL" -O "$LOCAL_TAR"
    fi
    
    rm -rf /usr/local/go && tar -C /usr/local -xzf "$LOCAL_TAR"
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
echo -e "${GREEN}[5/7] Installing/Updating Agent Service...${NC}"

AGENT_DIR="/opt/agent.svc.plus"

if [ -d "$AGENT_DIR" ]; then
    echo "Updating existing agent repository..."
    cd "$AGENT_DIR"
    git fetch origin
    git reset --hard origin/main
else
    git clone https://github.com/cloud-neutral-toolkit/agent.svc.plus.git "$AGENT_DIR"
    cd "$AGENT_DIR"
fi

# Build
echo "Building Agent binary..."
go mod tidy
go build -o /usr/local/bin/agent-svc-plus ./cmd/agent

# Copy default config if not exists, but don't overwrite user config
mkdir -p /etc/agent
if [ ! -f /etc/agent/account-agent.yaml ]; then
    echo "Initializing new configuration file..."
    cp account-agent.yaml /etc/agent/account-agent.yaml
    # Initial path setup for templates in the new config
    sed -i 's|config/xray.xhttp.template.json|/usr/local/etc/xray/templates/xray.xhttp.template.json|g' /etc/agent/account-agent.yaml
    sed -i 's|config/xray.tcp.template.json|/usr/local/etc/xray/templates/xray.tcp.template.json|g' /etc/agent/account-agent.yaml
else
    echo "Configuration file exists at /etc/agent/account-agent.yaml, skipping overwrite."
fi

# Always update templates
mkdir -p /usr/local/etc/xray/templates
cp config/*.template.json /usr/local/etc/xray/templates/
echo "Templates updated at /usr/local/etc/xray/templates/"


# 6. Caddy Configuration
echo -e "${GREEN}[6/7] Configuration Caddyfile...${NC}"
cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN}:443 {
    @grpc {
        path /split/*
    }

    handle @grpc {
        reverse_proxy unix//dev/shm/xray.sock {
             transport http {
                 versions h2c 2
             }
        }
    }

    # Fallback/Default site content
    respond "Agent Service Plus Node"
}
EOF

# Help script for syncing certificates
cat > /usr/local/bin/sync-agent-certs <<EOF
#!/bin/bash
# Syncs certificates from Caddy to Agent folder

# Ensure destination directory exists and is accessible
mkdir -p /etc/ssl/agent
chmod 755 /etc/ssl/agent

DOMAIN="${DOMAIN}"
TARGET_CRT="/etc/ssl/agent/svc.plus.pem"
TARGET_KEY="/etc/ssl/agent/svc.plus.key"

# Directories to search for Caddy data
# 1. Standard package install (User=caddy, Home=/var/lib/caddy)
# 2. Root install (User=root, Home=/root)
# 3. Custom/Other
SEARCH_PATHS="/var/lib/caddy /root /etc/caddy /usr/share/caddy"

echo "Starting certificate sync for domain: \${DOMAIN}"

# Retry loop (ACME issuing takes time)
MAX_RETRIES=30
SLEEP_SEC=2

for ((i=1; i<=MAX_RETRIES; i++)); do
    SOURCE_CRT=""
    SOURCE_KEY=""
    
    # Attempt to find the certificate
    for DIR in \${SEARCH_PATHS}; do
        if [ -d "\$DIR" ]; then
            # Find closest match file named exactly \${DOMAIN}.crt
            # Use 'find' to handle deep directory structures in .local/share/caddy/...
            FOUND_CRT=\$(find "\$DIR" -name "\${DOMAIN}.crt" 2>/dev/null | head -n 1)
            
            if [ -n "\$FOUND_CRT" ]; then
                # Check if corresponding key exists
                FOUND_KEY="\${FOUND_CRT%.crt}.key"
                if [ -f "\$FOUND_KEY" ]; then
                    SOURCE_CRT="\$FOUND_CRT"
                    SOURCE_KEY="\$FOUND_KEY"
                    break 2 # Break both loops found
                fi
            fi
        fi
    done
    
    echo "Attempt \$i/\$MAX_RETRIES: Certificate not found yet. Waiting \$SLEEP_SEC seconds..."
    sleep \$SLEEP_SEC
done

if [ -n "\$SOURCE_CRT" ] && [ -f "\$SOURCE_CRT" ]; then
    echo "Found certificate at: \$SOURCE_CRT"
    
    cp "\$SOURCE_CRT" "\$TARGET_CRT"
    cp "\$SOURCE_KEY" "\$TARGET_KEY"
    
    # Permissions for 'nobody' user (Xray)
    chown nobody:nogroup /etc/ssl/agent/svc.plus.*
    chmod 644 "\$TARGET_CRT"
    chmod 600 "\$TARGET_KEY"
    
    echo "Certificates successfully synced to /etc/ssl/agent/"
    
    # Reload/Restart Xray TCP if running
    systemctl restart xray-tcp || true
else
    echo "TIMED OUT: Could not find certificate for \${DOMAIN} in search paths: \${SEARCH_PATHS}"
    exit 1
fi
EOF
chmod +x /usr/local/bin/sync-agent-certs

# 7. Systemd Services
echo -e "${GREEN}[7/7] Installing Systemd Services...${NC}"

# Permissions for config dir
mkdir -p /usr/local/etc/xray
chown -R nobody:nogroup /usr/local/etc/xray

# Add a timer to sync certs regularly (optional, but good for renewals)
cat > /etc/systemd/system/agent-cert-sync.service <<EOF
[Unit]
Description=Sync Caddy Certificates for Xray Agent
After=caddy.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-agent-certs
TimeoutStartSec=300
EOF

cat > /etc/systemd/system/agent-cert-sync.timer <<EOF
[Unit]
Description=Daily Sync of Caddy Certificates

[Timer]
OnBootSec=1m
OnUnitActiveSec=1d

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable agent-cert-sync.timer
systemctl start agent-cert-sync.timer

# Attempt immediate sync (backgrounded so it doesn't block if retrying)
/usr/local/bin/sync-agent-certs &

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
