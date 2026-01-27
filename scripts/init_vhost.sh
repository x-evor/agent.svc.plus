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
# Function to compare versions
version_lt() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1"; }

INSTALLED_CADDY_VER="0.0.0"
if command -v caddy &> /dev/null; then
    INSTALLED_CADDY_VER=$(caddy version | awk '{print $1}' | sed 's/v//')
fi

REQUIRED_VER="2.8.0"
echo "Installed Caddy Version: $INSTALLED_CADDY_VER"

if version_lt "$INSTALLED_CADDY_VER" "$REQUIRED_VER"; then
    echo -e "${YELLOW}Caddy is missing or older than v${REQUIRED_VER}. Building/Upgrading...${NC}"
    xcaddy build \
        --with github.com/caddy-dns/cloudflare \
        --with github.com/caddy-dns/alidns \
        --output /usr/bin/caddy
else
    echo -e "${GREEN}Caddy is up to date (v$INSTALLED_CADDY_VER). Skipping build.${NC}"
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

# Check for existing Certbot certificates to reuse
LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
TLS_CONFIG=""

if [ -f "$LE_CERT" ] && [ -f "$LE_KEY" ]; then
    echo "Found existing Certbot certificates. usage: Direct."
    TLS_CONFIG="tls $LE_CERT $LE_KEY"
    
    # 1. Update Xray TCP Template to use these paths directly
    # We replace the default /etc/ssl/agent paths with the Let's Encrypt paths
    sed -i "s|/etc/ssl/agent/svc.plus.pem|${LE_CERT}|g" /usr/local/etc/xray/templates/xray.tcp.template.json
    sed -i "s|/etc/ssl/agent/svc.plus.key|${LE_KEY}|g" /usr/local/etc/xray/templates/xray.tcp.template.json
    echo "Updated Xray TCP template to use Certbot paths directly."
    
    # 2. Force initialization of tcp-config.json from the patched template
    # This guarantees the file on disk matches the Certbot paths immediately
    cp /usr/local/etc/xray/templates/xray.tcp.template.json /usr/local/etc/xray/tcp-config.json
    chown nobody:nogroup /usr/local/etc/xray/tcp-config.json
    echo "Initialized /usr/local/etc/xray/tcp-config.json from patched template."
    
    # 3. Fix Permissions so 'nobody' (Xray) can read them
    # Directories need search (x) permission, files need read (r)
    echo "Adjusting permissions for /etc/letsencrypt to allow Xray access..."
    chmod 755 /etc/letsencrypt
    chmod 755 /etc/letsencrypt/live
    chmod 755 /etc/letsencrypt/archive
    chmod -R +r /etc/letsencrypt/archive/${DOMAIN}
    chmod -R +r /etc/letsencrypt/live/${DOMAIN}
fi

cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN}:443 {
    ${TLS_CONFIG}
    
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
# Syncs certificates from Caddy or Certbot to Agent folder

# Ensure destination directory exists and is accessible
mkdir -p /etc/ssl/agent
chmod 755 /etc/ssl/agent

DOMAIN="${DOMAIN}"
TARGET_CRT="/etc/ssl/agent/svc.plus.pem"
TARGET_KEY="/etc/ssl/agent/svc.plus.key"

# Priority 1: Certbot / Let's Encrypt Standard Path
LE_CERT="/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/\${DOMAIN}/privkey.pem"

if [ -f "\$LE_CERT" ] && [ -f "\$LE_KEY" ]; then
    echo "Found Certbot certificates at \$LE_CERT"
    SOURCE_CRT="\$LE_CERT"
    SOURCE_KEY="\$LE_KEY"
else
    # Priority 2: Caddy Internal Storage
    # Directories to search for Caddy data
    SEARCH_PATHS="/var/lib/caddy /root /etc/caddy /usr/share/caddy"

    echo "Starting search for Caddy certificates..."

    # Retry loop (ACME issuing takes time if not using pre-existing certs)
    MAX_RETRIES=30
    SLEEP_SEC=2

    for ((i=1; i<=MAX_RETRIES; i++)); do
        # Attempt to find the certificate
        for DIR in \${SEARCH_PATHS}; do
            if [ -d "\$DIR" ]; then
                # Find closest match file named exactly \${DOMAIN}.crt
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
fi

if [ -n "\$SOURCE_CRT" ] && [ -f "\$SOURCE_CRT" ]; then
    echo "Found certificate at: \$SOURCE_CRT"
    
    # Check if we should link or copy. 
    # If it's Certbot, we might want to copy to avoid permission issues with Xray (nobody user) reading /etc/letsencrypt/live
    # Copying is safer for permissions.
    
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
    
    echo "--- DIAGNOSTICS ---"
    echo "1. Caddy Service Status:"
    systemctl status caddy --no-pager | head -n 5
    
    echo -e "\n2. Caddy Certificate Data Directory:"
    caddy environ | grep -i data
    
    echo -e "\n3. Domain Resolution (getent hosts):"
    getent hosts "\${DOMAIN}" || echo "Failed to resolve \${DOMAIN}"
    
    echo -e "\n4. Last 20 lines of Caddy Log:"
    if journalctl -u caddy --no-pager >/dev/null 2>&1; then
        journalctl -u caddy --no-pager | tail -n 20
    else
        tail -n 20 /var/log/caddy.log 2>/dev/null || echo "No logs found."
    fi
    echo "-------------------"
    
    exit 1
fi
EOF
chmod +x /usr/local/bin/sync-agent-certs

# 7. Systemd Services
echo -e "${GREEN}[7/7] Installing Systemd Services...${NC}"

# Permissions for config dir
mkdir -p /usr/local/etc/xray
chown -R nobody:nogroup /usr/local/etc/xray

# Attempt immediate sync
/usr/local/bin/sync-agent-certs || true

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
