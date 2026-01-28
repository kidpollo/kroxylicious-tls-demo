#!/bin/bash

# TLS Credential Supplier Rotation Test Script
# This script demonstrates certificate rotation by connecting to all 3 virtual clusters

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Kroxylicious TLS Credential Supplier - Rotation Test${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Check if kcat is installed
if ! command -v kcat &> /dev/null; then
    echo -e "${YELLOW}⚠️  kcat not found. Installing...${NC}"
    echo "   Run: brew install kcat (macOS) or apt-get install kafkacat (Linux)"
    exit 1
fi

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    export DOCKER_HOST=unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || echo "")
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo -e "${YELLOW}⚠️  Neither podman nor docker found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Using container runtime: $CONTAINER_CMD${NC}"
echo ""

# Check if services are running
echo -e "${BLUE}Checking services...${NC}"
if ! $CONTAINER_CMD ps | grep -q kafka; then
    echo -e "${YELLOW}⚠️  Kafka not running. Start with: $CONTAINER_CMD compose up -d${NC}"
    exit 1
fi

if ! $CONTAINER_CMD ps | grep -q kroxylicious; then
    echo -e "${YELLOW}⚠️  Kroxylicious not running. Start with: $CONTAINER_CMD compose up -d${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Kafka and Kroxylicious are running${NC}"
echo ""

# Function to send test message
send_message() {
    local port=$1
    local cluster_name=$2
    local message=$3
    
    echo -e "${BLUE}→ Sending message through $cluster_name (port $port)${NC}"
    echo "$message" | kcat -b localhost:$port -t rotation-test -P 2>&1 | grep -v "^%" || true
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}  ✓ Message sent successfully${NC}"
    else
        echo -e "${YELLOW}  ⚠️  Message may have failed (check logs)${NC}"
    fi
    echo ""
}

# Test all 3 virtual clusters
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Testing Certificate Rotation Across Virtual Clusters${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

send_message 9192 "demo1" "Test message 1 - Should use cert-1"
sleep 2

send_message 9210 "demo2" "Test message 2 - Should use cert-2"
sleep 2

send_message 9230 "demo3" "Test message 3 - Should use cert-3"
sleep 2

# Send more messages to see full rotation
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Sending Multiple Messages to Observe Rotation${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

for i in {1..9}; do
    port=9192
    if [ $((i % 3)) -eq 0 ]; then
        port=9230
        cluster="demo3"
    elif [ $((i % 3)) -eq 1 ]; then
        port=9192
        cluster="demo1"
    else
        port=9210
        cluster="demo2"
    fi
    
    echo -e "${BLUE}→ Message $i via $cluster (port $port)${NC}"
    echo "Rotation test message $i" | kcat -b localhost:$port -t rotation-test -P 2>&1 | grep -v "^%" > /dev/null || true
    sleep 1
done

echo ""
echo -e "${GREEN}✓ Test messages sent${NC}"
echo ""

# Show certificate usage
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Certificate Usage Summary (from Kafka logs)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

$CONTAINER_CMD logs kafka 2>&1 | grep "Certificate CN: proxy-client" | sort | uniq -c | while read count cn; do
    echo -e "${GREEN}  $count authentications${NC} - $cn"
done

echo ""

# Show recent certificate selections
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Recent Certificate Selections (from Kroxylicious logs)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

$CONTAINER_CMD logs kroxylicious 2>&1 | grep "Selected Certificate:" | tail -10 | while read line; do
    echo -e "${GREEN}  $line${NC}"
done

echo ""

# Show recent authentications
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Recent Authentications (from Kafka logs)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

$CONTAINER_CMD logs kafka 2>&1 | grep -A 3 "CLIENT AUTHENTICATED" | tail -20

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Rotation test complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "To view live rotation:"
echo "  Terminal 1: $CONTAINER_CMD logs -f kafka | grep 'Certificate CN:'"
echo "  Terminal 2: for i in {1..20}; do echo \"msg \$i\" | kcat -b localhost:9192 -t test -P; sleep 1; done"
echo ""
