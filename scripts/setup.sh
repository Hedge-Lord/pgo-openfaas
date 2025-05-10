#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up OpenFaaS on CloudLab node...${NC}"

# Cleanup function
cleanup() {
    echo -e "${GREEN}Cleaning up previous installation...${NC}"
    sudo systemctl stop faasd || true
    sudo rm -f /usr/local/bin/faasd
    sudo rm -f /usr/local/bin/containerd
    sudo rm -f /usr/local/bin/containerd-shim
    sudo rm -f /usr/local/bin/containerd-shim-runc-v1
    sudo rm -f /usr/local/bin/containerd-shim-runc-v2
    sudo rm -f /usr/local/bin/ctr
    sudo rm -f /usr/local/bin/runc
    sudo rm -rf /var/lib/faasd
}

# Install dependencies
echo -e "${GREEN}Installing dependencies...${NC}"
sudo apt-get update
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo -e "${GREEN}Installing Docker...${NC}"
    # 1. Stop everything (if already running)
    sudo systemctl stop docker.service || true

    # 2. Remove the BAD SysV wrapper alias
    sudo rm -f /etc/init.d/docker || true
    sudo systemctl daemon-reload || true

    # 3. Make sure the GOOD native unit is installed
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io

    # 4. Enable & start the native unit
    sudo systemctl enable --now docker.service
fi

# Cleanup previous installation
cleanup

# Install faasd
echo -e "${GREEN}Installing faasd...${NC}"
curl -sSL https://raw.githubusercontent.com/openfaas/faasd/master/hack/install.sh | sudo bash

# Install OpenFaaS CLI
echo -e "${GREEN}Installing OpenFaaS CLI...${NC}"
curl -sSL https://cli.openfaas.com | sudo bash

# Install hey for benchmarking
echo -e "${GREEN}Installing hey for benchmarking...${NC}"
sudo curl -sSL https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64 -o /usr/local/bin/hey
sudo chmod +x /usr/local/bin/hey

# Create faasd directory structure
echo -e "${GREEN}Creating OpenFaaS directory structure...${NC}"
sudo mkdir -p /var/lib/faasd/secrets

# Create docker-compose.yaml
echo -e "${GREEN}Creating docker-compose.yaml...${NC}"
sudo tee /var/lib/faasd/docker-compose.yaml > /dev/null << 'EOF'
version: '3.7'
services:
  gateway:
    image: ghcr.io/openfaas/gateway:latest
    ports:
      - "8080:8080"
    environment:
      - basic_auth=false
      - functions_provider_url=http://faasd:8081/
    networks:
      - openfaas
    depends_on:
      - faasd

  faasd:
    image: ghcr.io/openfaas/faasd:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/faasd:/var/lib/faasd
    networks:
      - openfaas

networks:
  openfaas:
    driver: bridge
EOF

# Start OpenFaaS
echo -e "${GREEN}Starting OpenFaaS...${NC}"
sudo systemctl start faasd

# Wait for the gateway to be ready
echo -e "${GREEN}Waiting for OpenFaaS gateway to be ready...${NC}"
while ! curl -s http://localhost:8080/system/functions > /dev/null; do
    sleep 1
done

echo -e "${GREEN}Setup complete! OpenFaaS gateway is available at http://localhost:8080${NC}"
echo -e "${GREEN}You may need to log out and back in for Docker group changes to take effect.${NC}"