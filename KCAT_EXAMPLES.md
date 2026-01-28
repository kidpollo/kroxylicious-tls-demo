# kcat Examples for TLS Credential Supplier Demo

This file contains various kcat commands to test certificate rotation through Kroxylicious.

## ✅ Works from localhost!

All ports are now properly exposed (including broker node ports 9201, 9221, 9241), so kcat commands work directly from your host machine.

## Installation

```bash
# macOS
brew install kcat

# Linux (Debian/Ubuntu)
apt-get install kafkacat

# Linux (RHEL/CentOS)
yum install kafkacat
```

Note: `kafkacat` is the old name, `kcat` is the new name. They're the same tool.

## Virtual Cluster Endpoints

- **demo1**: `localhost:9192` (bootstrap) / `localhost:9200` (broker)
- **demo2**: `localhost:9210` (bootstrap) / `localhost:9220` (broker)
- **demo3**: `localhost:9230` (bootstrap) / `localhost:9240` (broker)

## Basic Commands

### List Topics

```bash
# Connect to demo1
kcat -b localhost:9192 -L

# Connect to demo2
kcat -b localhost:9210 -L

# Connect to demo3
kcat -b localhost:9230 -L
```

### Create a Topic

```bash
# Create topic through demo1
kcat -b localhost:9192 -t test-rotation -P -Q <<EOF
This is a test message
EOF
```

### Produce Messages

```bash
# Single message
echo "Hello from demo1" | kcat -b localhost:9192 -t test-rotation -P

# Multiple messages
cat <<EOF | kcat -b localhost:9192 -t test-rotation -P
message 1
message 2
message 3
EOF

# From file
kcat -b localhost:9192 -t test-rotation -P -l < messages.txt

# Interactive mode (Ctrl+D to finish)
kcat -b localhost:9192 -t test-rotation -P
```

### Consume Messages

```bash
# Consume all messages (from beginning)
kcat -b localhost:9192 -t test-rotation -C -o beginning

# Consume only new messages
kcat -b localhost:9192 -t test-rotation -C -o end

# Consume with offset
kcat -b localhost:9192 -t test-rotation -C -o 0

# Consume N messages then exit
kcat -b localhost:9192 -t test-rotation -C -c 10

# Consume with metadata
kcat -b localhost:9192 -t test-rotation -C -f 'Topic: %t [%p] Offset: %o - %s\n'
```

## Testing Certificate Rotation

### Sequential Connections (Different Certs)

```bash
# Send 3 messages through different virtual clusters
# Each should use a different certificate

echo "Message via demo1" | kcat -b localhost:9192 -t rotation-test -P
echo "Message via demo2" | kcat -b localhost:9210 -t rotation-test -P
echo "Message via demo3" | kcat -b localhost:9230 -t rotation-test -P
```

After running these, check Kafka logs:
```bash
podman logs kafka | grep "Certificate CN:" | tail -10
```

You should see:
```
Certificate CN: proxy-client-1
Certificate CN: proxy-client-2  
Certificate CN: proxy-client-3
```

### Loop Through All Clusters

```bash
# Send 12 messages (4 per cluster) to see rotation
for i in {1..4}; do
  echo "Round $i to demo1" | kcat -b localhost:9192 -t rotation-test -P
  echo "Round $i to demo2" | kcat -b localhost:9210 -t rotation-test -P
  echo "Round $i to demo3" | kcat -b localhost:9230 -t rotation-test -P
  sleep 1
done
```

### Rapid Fire (Single Cluster)

```bash
# Send many messages through one cluster
# Rotation happens due to internal connection pooling

for i in {1..20}; do
  echo "Rapid message $i" | kcat -b localhost:9192 -t rotation-test -P
  sleep 0.5
done
```

## Monitoring Commands

### Watch Rotation Live (2 Terminal Windows)

**Terminal 1** - Watch Kafka authentication logs:
```bash
# Podman
podman logs -f kafka 2>&1 | grep --line-buffered "Certificate CN:"

# Docker
docker logs -f kafka 2>&1 | grep --line-buffered "Certificate CN:"
```

**Terminal 2** - Send messages:
```bash
for i in {1..30}; do
  echo "Message $i" | kcat -b localhost:9192 -t live-test -P
  sleep 1
done
```

You'll see the certificate CN rotating in Terminal 1.

### Watch Kroxylicious Certificate Selection

```bash
# Podman
podman logs -f kroxylicious 2>&1 | grep --line-buffered "Selected Certificate"

# Docker
docker logs -f kroxylicious 2>&1 | grep --line-buffered "Selected Certificate"
```

## Advanced Examples

### Produce with Keys

```bash
# Message with key
echo "key1:value1" | kcat -b localhost:9192 -t test-rotation -P -K:

# Multiple keyed messages
cat <<EOF | kcat -b localhost:9192 -t test-rotation -P -K:
user1:login event
user2:logout event
user1:purchase event
EOF
```

### Consume with Full Details

```bash
kcat -b localhost:9192 -t test-rotation -C \
  -f 'Key: %k\nValue: %s\nPartition: %p\nOffset: %o\nTimestamp: %T\n---\n'
```

### Produce with Partition

```bash
# Send to specific partition
echo "message for partition 0" | kcat -b localhost:9192 -t test-rotation -P -p 0
echo "message for partition 1" | kcat -b localhost:9192 -t test-rotation -P -p 1
```

### Metadata Only

```bash
# Just show metadata (no consume)
kcat -b localhost:9192 -L -J | jq .
```

## Performance Testing

### Throughput Test

```bash
# Generate 10000 messages rapidly
seq 1 10000 | kcat -b localhost:9192 -t perf-test -P

# Consume and count
kcat -b localhost:9192 -t perf-test -C -c 10000 -q | wc -l
```

### Latency Test

```bash
# Produce with timestamp
for i in {1..10}; do
  echo "$(date +%s%N) message $i" | kcat -b localhost:9192 -t latency-test -P
  sleep 1
done

# Consume with timestamp to measure latency
kcat -b localhost:9192 -t latency-test -C -o beginning \
  -f '%T %s\n' -c 10
```

## Troubleshooting

### Connection Issues

```bash
# Verbose mode (-v) shows connection details
kcat -b localhost:9192 -L -v

# Debug mode (-d all) shows everything
kcat -b localhost:9192 -L -d broker,topic,metadata
```

### Check Broker Connectivity

```bash
# Test all 3 virtual clusters
for port in 9192 9210 9230; do
  echo "Testing port $port..."
  kcat -b localhost:$port -L 2>&1 | head -5
  echo ""
done
```

### Verify Messages Were Sent

```bash
# Produce
echo "test message" | kcat -b localhost:9192 -t verify-test -P -v

# Immediately consume to verify
kcat -b localhost:9192 -t verify-test -C -o beginning -c 1
```

## Tips

1. **Use `-q` for quiet mode** when scripting (suppresses progress info)
2. **Use `-e` to exit after reaching end** of topic (useful for finite consumption)
3. **Use `-J` for JSON output** when parsing with jq or other tools
4. **Use `-K` to specify key delimiter** (default is tab)
5. **Use `-Z` for null messages** (useful for tombstones in compacted topics)

## Common Issues

### "Broker transport failure"

This usually means:
- Kroxylicious is not running
- Port is incorrect
- Network connectivity issue

Check services:
```bash
podman ps | grep kroxylicious
podman logs kroxylicious | tail -20
```

### "Metadata request failed"

This can happen if:
- Topic doesn't exist (not auto-created)
- Permissions issue
- Broker not reachable

Create topic explicitly:
```bash
echo "init" | kcat -b localhost:9192 -t your-topic -P
```

### Messages not appearing

Common causes:
- Consuming from wrong offset (use `-o beginning`)
- Topic doesn't exist
- Consuming from wrong partition

List all messages:
```bash
kcat -b localhost:9192 -t your-topic -C -o beginning -e
```

## Summary of Most Useful Commands

```bash
# Quick test of all 3 clusters
kcat -b localhost:9192 -L  # demo1
kcat -b localhost:9210 -L  # demo2
kcat -b localhost:9230 -L  # demo3

# Send test message
echo "test" | kcat -b localhost:9192 -t test-topic -P

# Read all messages
kcat -b localhost:9192 -t test-topic -C -o beginning

# Watch rotation
podman logs -f kafka | grep "Certificate CN:"
```
