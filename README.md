# Kroxylicious TLS Credential Supplier Demo

> **⚠️ Prerequisites**: This demo requires a Kroxylicious Docker image with TLS Credential Supplier plugin support. See [Prerequisites](#prerequisites) section below.

This demo validates the TLS Credential Supplier feature for Kroxylicious, which allows dynamic selection of client certificates when the proxy connects to Kafka brokers.

## What This Demonstrates

- **Dynamic Certificate Selection**: Kroxylicious rotates through 3 different client certificates
- **Multiple Certificate Identities**: Kafka authenticates connections with different CNs:
  - `CN=proxy-client-1`
  - `CN=proxy-client-2`
  - `CN=proxy-client-3`
- **Multiple Virtual Clusters**: 3 separate virtual clusters all sharing the same rotation pool

## Architecture

```
Client → Kroxylicious (3 Virtual Clusters) → Kafka (mTLS)
         Port 9192 (demo1)                    
         Port 9210 (demo2)     [cert rotation]
         Port 9230 (demo3)                    Port 9093
```

## Directory Structure

```
kroxylicious-tls-demo/
├── README.md                    # This file
├── docker-compose.yml           # Modern KRaft Kafka + Kroxylicious
├── proxy-config.yaml            # 3 virtual clusters with TLS supplier
├── generate-certs.sh            # Certificate generation script
├── test-rotation.sh             # kcat test script
├── certs/                       # Generated certificates
│   ├── ca.crt, ca.key           # Certificate Authority
│   ├── kafka-server.*           # Kafka server cert (JKS)
│   ├── kafka.truststore.jks     # Kafka truststore (trusts CA)
│   ├── proxy-cert-{1,2,3}.pem   # 3 proxy client certs
│   └── proxy-key-{1,2,3}.pem    # 3 proxy client keys
├── tls-plugin/                  # Rotating TLS Credential Supplier
│   ├── pom.xml
│   ├── src/main/java/.../RotatingTlsCredentialSupplier.java
│   └── target/*.jar
└── principal-builder/           # Custom Kafka principal builder
    ├── pom.xml                  # Logs certificate CNs
    ├── src/main/java/.../LoggingPrincipalBuilder.java
    └── target/*.jar
```

## Prerequisites

### Required Software
- **Docker or Podman** - Container runtime
- **Maven** - For building plugins
- **Java 17+** - Required for plugin compilation
- **kcat** (optional) - For testing from command line

### ⚠️ Important: Kroxylicious Image with TLS Credential Supplier Support

**This demo requires a Kroxylicious Docker image with TLS Credential Supplier plugin support.**

The `docker-compose.yml` references:
```yaml
image: quay.io/kroxylicious/proxy:0.19.0-SNAPSHOT
```

**Before starting this demo**, ensure you have a Kroxylicious image that supports the TLS Credential Supplier API:

```bash
# In your Kroxylicious repository with TLS Credential Supplier support
cd /path/to/kroxylicious

# Build the Docker image (this takes a few minutes)
mvn clean install -Dquick -Pdist

# Verify the image exists
podman images | grep kroxylicious
# Should show: quay.io/kroxylicious/proxy with the appropriate version tag
```

**Why is this needed?**
- The TLS Credential Supplier API must be available in the Kroxylicious build
- The demo plugins (rotating credential supplier) require this API to function
- Without a compatible image, docker-compose will fail to start

**Note**: If using a different image name/tag, update the `image:` field in `docker-compose.yml` accordingly.

## Quick Start

### 1. Generate Certificates

```bash
./generate-certs.sh
```

This creates:
- CA certificate and key
- Kafka server certificate (signed by CA)
- 3 proxy client certificates (signed by CA, with different CNs)

### 2. Build the Plugins

```bash
# Build TLS credential supplier plugin
cd tls-plugin
mvn clean package -Dmaven.test.skip=true
cd ..

# Build principal builder
cd principal-builder
mvn clean package -Dmaven.test.skip=true
cd ..
```

### 3. Start the Stack

```bash
# For Podman users
export DOCKER_HOST=unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')
podman compose -f docker-compose.yml up -d

# For Docker users
docker compose up -d
```

Wait 30 seconds for services to initialize.

### 4. Verify Services Are Running

```bash
# Podman
podman ps

# Docker
docker ps
```

You should see:
- `kafka` - Apache Kafka in KRaft mode
- `kroxylicious` - Proxy with 6 ports exposed

### 5. Test Certificate Rotation

You can now test with kcat directly from your localhost!

```bash
# Quick test all 3 virtual clusters
echo "msg1" | kcat -b localhost:9192 -t test -P
echo "msg2" | kcat -b localhost:9210 -t test -P
echo "msg3" | kcat -b localhost:9230 -t test -P

# Watch rotation
podman logs kafka | grep "Certificate CN:" | tail -10
```

Or use the automated test script:

```bash
./test-rotation.sh
```

For testing from inside the Kafka container (alternative):

```bash
./test-rotation-internal.sh
```

### 6. View Certificate Rotation in Action

**Check Kroxylicious logs** (see certificate selection):
```bash
# Podman
podman logs kroxylicious | grep "Selected Certificate"

# Docker
docker logs kroxylicious | grep "Selected Certificate"
```

**Check Kafka logs** (see different CNs authenticated):
```bash
# Podman
podman logs kafka | grep "Certificate CN:"

# Docker  
docker logs kafka | grep "Certificate CN:"
```

You should see all 3 identities:
```
Certificate CN: proxy-client-1
Certificate CN: proxy-client-2
Certificate CN: proxy-client-3
```

## Testing with kcat

### List Topics (connects to each virtual cluster)

```bash
# Virtual Cluster 1 (demo1) - Port 9192
kcat -b localhost:9192 -L

# Virtual Cluster 2 (demo2) - Port 9210
kcat -b localhost:9210 -L

# Virtual Cluster 3 (demo3) - Port 9230
kcat -b localhost:9230 -L
```

Each connection will use a different certificate from the rotation pool.

### Produce Messages

```bash
# Send message through demo1
echo "test message from demo1" | kcat -b localhost:9192 -t test-topic -P

# Send message through demo2
echo "test message from demo2" | kcat -b localhost:9210 -t test-topic -P

# Send message through demo3
echo "test message from demo3" | kcat -b localhost:9230 -t test-topic -P
```

### Consume Messages

```bash
# Consume from demo1
kcat -b localhost:9192 -t test-topic -C

# Consume from demo2  
kcat -b localhost:9210 -t test-topic -C

# Consume from demo3
kcat -b localhost:9230 -t test-topic -C
```

### Watch Rotation in Real-Time

Open 2 terminals:

**Terminal 1** - Watch Kafka authentication:
```bash
# Podman
podman logs -f kafka | grep "Certificate CN:"

# Docker
docker logs -f kafka | grep "Certificate CN:"
```

**Terminal 2** - Send multiple messages:
```bash
for i in {1..10}; do
  echo "message $i" | kcat -b localhost:9192 -t test -P
  sleep 1
done
```

You'll see the certificate CN rotating: client-1 → client-2 → client-3 → client-1 ...

## Configuration Details

### Virtual Clusters

| Cluster | Bootstrap Port | Broker Port(s) | TLS Supplier |
|---------|---------------|----------------|--------------|
| demo1   | 9192          | 9200-9201      | Rotating (global counter) |
| demo2   | 9210          | 9220-9221      | Rotating (global counter) |
| demo3   | 9230          | 9240-9241      | Rotating (global counter) |

**Note**: Kafka uses node ID 1, so the actual broker port is nodeStartPort + nodeId:
- demo1: 9200 + 1 = **9201**
- demo2: 9220 + 1 = **9221**
- demo3: 9240 + 1 = **9241**

All clusters share the same global rotation counter, ensuring proper round-robin across all connections.

### Kafka Configuration

- **Mode**: KRaft (no Zookeeper)
- **INTERNAL listener**: Port 9093 (TLS + mTLS required)
- **EXTERNAL listener**: Port 9092 (Plaintext, for inter-broker)
- **Principal Builder**: Custom `LoggingPrincipalBuilder` logs certificate CNs

### Certificate Details

| Certificate | CN | Organization | Purpose |
|-------------|-----|-------------|---------|
| ca.crt | Test CA | KroxyliciousCA | Signs all certs |
| kafka-server | kafka | KafkaServer | Kafka server identity |
| proxy-cert-1 | proxy-client-1 | KroxyliciousProxy | Proxy identity 1 |
| proxy-cert-2 | proxy-client-2 | KroxyliciousProxy | Proxy identity 2 |
| proxy-cert-3 | proxy-client-3 | KroxyliciousProxy | Proxy identity 3 |

## Cleanup

```bash
# Stop services
podman compose -f docker-compose.yml down

# Or for Docker
docker compose down

# Remove generated certificates (optional)
rm -rf certs/*.{crt,key,pem,jks}
```

## Troubleshooting

### "Image not found" or "no such image" error

**Most common issue**: You need to build a Kroxylicious Docker image with TLS Credential Supplier support!

```bash
# Build from Kroxylicious source with TLS Credential Supplier API
cd /path/to/kroxylicious
mvn clean install -Dquick -Pdist

# Verify the image was built
podman images | grep kroxylicious
```

If using a different image name/tag, update `docker-compose.yml`:
```yaml
kroxylicious:
  image: your-image-name:your-tag
```

### Containers not starting

Check logs:
```bash
podman logs kafka
podman logs kroxylicious
```

### Port conflicts

If ports 9092, 9093, 9192, 9200, 9210, 9220, 9230, or 9240 are in use:
```bash
# Find what's using the port
lsof -i :9192

# Kill the process or change ports in docker-compose.yml
```

### Certificate errors

Regenerate certificates:
```bash
rm -rf certs/*.{crt,key,pem,jks}
./generate-certs.sh
```

### Only seeing one certificate CN

The global counter was added to fix this. Verify you rebuilt the plugin:
```bash
cd tls-plugin
mvn clean package -Dmaven.test.skip=true
podman compose restart kroxylicious
```

## Key Learnings

1. **Global State**: The rotation counter must be static/global (not per-instance) for proper rotation across virtual clusters
2. **Async Streams**: Certificate streams must be read fully before passing to async processors
3. **Principal Builder**: Custom principal builders are ideal for observing certificate identities in Kafka
4. **Port Configuration**: Each virtual cluster needs non-overlapping port ranges for `portIdentifiesNode`

## Related Files in Kroxylicious Repository

- `kroxylicious-api/src/main/java/io/kroxylicious/proxy/config/tls/Tls.java` - TLS configuration with backward-compatible constructor
- Binary compatibility validated with japicmp Maven plugin

## Success Criteria

✅ **All validation criteria met:**
- TLS supplier API works without errors
- Certificates load dynamically from PEM files  
- SSL/TLS handshake completes (TLSv1.3)
- **Kafka authenticates with 3 different certificate CNs**
- **Certificates rotate across connections (global counter)**
