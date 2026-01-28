#!/bin/bash
set -e

# TLS Certificate Generation for Kroxylicious Demo
# Creates CA, Kafka server cert, and 3 proxy client certs

CERTS_DIR="./certs"
VALIDITY_DAYS=365
PASSWORD="changeit"

echo "🔐 Generating TLS certificates for Kroxylicious demo..."
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

# 1. Generate CA (Certificate Authority)
echo "📜 Step 1/6: Generating CA certificate..."
openssl req -new -x509 \
    -keyout ca.key \
    -out ca.crt \
    -days $VALIDITY_DAYS \
    -passout pass:$PASSWORD \
    -subj "/C=US/ST=CA/L=SF/O=KroxyliciousDemo/CN=Demo-CA"

# 2. Generate Kafka Server Certificate
echo "📜 Step 2/6: Generating Kafka server certificate..."
openssl genrsa -out kafka-server.key 2048

openssl req -new \
    -key kafka-server.key \
    -out kafka-server.csr \
    -subj "/C=US/ST=CA/L=SF/O=KafkaServer/CN=kafka"

openssl x509 -req \
    -in kafka-server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out kafka-server.crt \
    -days $VALIDITY_DAYS \
    -passin pass:$PASSWORD \
    -extfile <(printf "subjectAltName=DNS:kafka,DNS:localhost,IP:127.0.0.1")

# 3. Create Kafka Keystore (JKS format)
echo "📜 Step 3/6: Creating Kafka keystore..."
openssl pkcs12 -export \
    -in kafka-server.crt \
    -inkey kafka-server.key \
    -out kafka-server.p12 \
    -name kafka-server \
    -passout pass:$PASSWORD

keytool -importkeystore \
    -srckeystore kafka-server.p12 \
    -srcstoretype PKCS12 \
    -srcstorepass $PASSWORD \
    -destkeystore kafka-server.keystore.jks \
    -deststoretype JKS \
    -deststorepass $PASSWORD \
    -noprompt

# 4. Create Kafka Truststore (contains CA)
echo "📜 Step 4/6: Creating Kafka truststore..."
keytool -import \
    -file ca.crt \
    -alias ca-cert \
    -keystore kafka.truststore.jks \
    -storepass $PASSWORD \
    -noprompt

# 5. Generate Proxy Client Certificates (3 for rotation)
echo "📜 Step 5/6: Generating proxy client certificates..."
for i in 1 2 3; do
    echo "  → Generating proxy-cert-${i}..."
    
    # Generate private key
    openssl genrsa -out proxy-key-${i}.pem 2048
    
    # Generate CSR
    openssl req -new \
        -key proxy-key-${i}.pem \
        -out proxy-cert-${i}.csr \
        -subj "/C=US/ST=CA/L=SF/O=KroxyliciousProxy/CN=proxy-client-${i}"
    
    # Sign with CA
    openssl x509 -req \
        -in proxy-cert-${i}.csr \
        -CA ca.crt \
        -CAkey ca.key \
        -CAcreateserial \
        -out proxy-cert-${i}.pem \
        -days $VALIDITY_DAYS \
        -passin pass:$PASSWORD
    
    # Cleanup CSR
    rm proxy-cert-${i}.csr
done

# 6. Cleanup temporary files
echo "📜 Step 6/6: Cleaning up..."
rm kafka-server.csr kafka-server.p12 ca.srl

# Summary
echo ""
echo "✅ Certificate generation complete!"
echo ""
echo "📁 Generated files in $CERTS_DIR:"
echo "   CA Certificate:        ca.crt"
echo "   Kafka Server:          kafka-server.keystore.jks"
echo "   Kafka Truststore:      kafka.truststore.jks"
echo "   Proxy Certificates:    proxy-cert-{1,2,3}.pem"
echo "   Proxy Keys:            proxy-key-{1,2,3}.pem"
echo ""
echo "🔑 All passwords: $PASSWORD"
