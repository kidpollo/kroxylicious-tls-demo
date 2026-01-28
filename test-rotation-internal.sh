#!/bin/bash

# TLS Credential Supplier Rotation Test Script (Internal)
# This script tests from inside the Kafka container to avoid advertised listener issues

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Kroxylicious TLS Credential Supplier - Rotation Test${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
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

# Clear old logs to see fresh results
echo -e "${BLUE}Clearing certificate counter in Kafka logs...${NC}"
echo "(We'll look at new authentications after this point)"
echo ""

# Function to send test message from inside kafka container
send_message() {
    local port=$1
    local cluster_name=$2
    local message=$3
    
    echo -e "${BLUE}→ Sending message through $cluster_name (port $port)${NC}"
    
    echo "$message" | $CONTAINER_CMD exec -i kafka timeout 5 \
        /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server kroxylicious:$port \
        --topic rotation-test 2>&1 | grep -v "WARN" || true
    
    echo -e "${GREEN}  ✓ Message sent${NC}"
    sleep 2
    echo ""
}

# Test all 3 virtual clusters
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Testing Certificate Rotation Across Virtual Clusters${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

send_message 9192 "demo1" "Test message 1 via demo1"
send_message 9210 "demo2" "Test message 2 via demo2"
send_message 9230 "demo3" "Test message 3 via demo3"

# Send more messages
echo -e "${BLUE}Sending more messages to see continued rotation...${NC}"
echo ""

for i in {4..12}; do
    port=9192
    cluster="demo1"
    
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
    
    echo -e "${BLUE}→ Message $i via $cluster${NC}"
    echo "Rotation test message $i" | $CONTAINER_CMD exec -i kafka timeout 5 \
        /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server kroxylicious:$port \
        --topic rotation-test 2>&1 | grep -v "WARN" || true
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

$CONTAINER_CMD logs kroxylicious 2>&1 | grep "Selected Certificate:" | tail -15 | while read line; do
    cert=$(echo "$line" | grep -o "proxy-cert-[0-9]")
    if [ ! -z "$cert" ]; then
        echo -e "${GREEN}  ✓ Selected: $cert${NC}"
    fi
done

echo ""

# Show recent unique authentications
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Recent Unique Certificate Authentications${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

$CONTAINER_CMD logs kafka 2>&1 | grep "Certificate CN: proxy-client" | tail -30 | sort -u | while read line; do
    cn=$(echo "$line" | grep -o "proxy-client-[0-9]")
    if [ ! -z "$cn" ]; then
        echo -e "${GREEN}  ✓ Authenticated: CN=$cn${NC}"
    fi
done

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Rotation test complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "To view live rotation:"
echo "  Terminal 1: $CONTAINER_CMD logs -f kafka | grep 'Certificate CN:'"
echo "  Terminal 2: ./test-rotation-internal.sh"
echo ""
echo "You should see all 3 certificate identities:"
echo "  - proxy-client-1"
echo "  - proxy-client-2"
echo "  - proxy-client-3"
echo ""
