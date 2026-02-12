/*
 * Rotating TLS Credential Supplier Demo Plugin
 * 
 * This plugin demonstrates dynamic TLS certificate selection by rotating
 * through a pool of pre-generated certificates. Each connection to Kafka
 * uses a different certificate from the pool in round-robin fashion.
 * 
 * Purpose: Show that Kafka authenticates connections with different
 * certificate identities (CN=proxy-client-1, CN=proxy-client-2, etc.)
 */
package io.kroxylicious.demo;

import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

import com.fasterxml.jackson.annotation.JsonProperty;

import io.kroxylicious.proxy.plugin.Plugin;
import io.kroxylicious.proxy.plugin.PluginConfigurationException;
import io.kroxylicious.proxy.plugin.Plugins;
import io.kroxylicious.proxy.tls.ServerTlsCredentialSupplier;
import io.kroxylicious.proxy.tls.ServerTlsCredentialSupplierContext;
import io.kroxylicious.proxy.tls.ServerTlsCredentialSupplierFactory;
import io.kroxylicious.proxy.tls.ServerTlsCredentialSupplierFactoryContext;
import io.kroxylicious.proxy.tls.TlsCredentials;

@Plugin(configType = RotatingTlsCredentialSupplier.Config.class)
public class RotatingTlsCredentialSupplier 
        implements ServerTlsCredentialSupplierFactory<
            RotatingTlsCredentialSupplier.Config, 
            RotatingTlsCredentialSupplier.SharedContext> {

    // ═══════════════════════════════════════════════════════
    // GLOBAL COUNTER - Shared across ALL virtual clusters!
    // This ensures rotation works across all connections
    // ═══════════════════════════════════════════════════════
    private static final AtomicInteger GLOBAL_CONNECTION_COUNTER = new AtomicInteger(0);

    /**
     * Plugin configuration - paths to certificate and key files
     */
    public record Config(
        @JsonProperty(required = true) List<String> certPaths,
        @JsonProperty(required = true) List<String> keyPaths
    ) {}

    /**
     * Shared context across all supplier instances
     * Maintains certificate paths (counter is now static/global)
     */
    public static class SharedContext {
        private final List<Path> certPaths;
        private final List<Path> keyPaths;

        public SharedContext(List<Path> certPaths, List<Path> keyPaths) {
            this.certPaths = certPaths;
            this.keyPaths = keyPaths;
        }

        public int nextIndex() {
            // Use the GLOBAL counter instead of per-instance counter
            return GLOBAL_CONNECTION_COUNTER.getAndIncrement() % certPaths.size();
        }

        public Path getCertPath(int index) {
            return certPaths.get(index);
        }

        public Path getKeyPath(int index) {
            return keyPaths.get(index);
        }

        public int totalConnections() {
            return GLOBAL_CONNECTION_COUNTER.get();
        }
    }

    @Override
    public SharedContext initialize(
            ServerTlsCredentialSupplierFactoryContext context,
            Config config) throws PluginConfigurationException {
        
        // Validate configuration
        Config validated = Plugins.requireConfig(this, config);
        
        if (validated.certPaths().size() != validated.keyPaths().size()) {
            throw new PluginConfigurationException(
                "Number of certificate paths must match number of key paths");
        }

        // Convert string paths to Path objects
        List<Path> certPaths = validated.certPaths().stream()
            .map(Path::of)
            .collect(Collectors.toList());
        
        List<Path> keyPaths = validated.keyPaths().stream()
            .map(Path::of)
            .collect(Collectors.toList());

        // Validate all files exist
        for (int i = 0; i < certPaths.size(); i++) {
            if (!Files.exists(certPaths.get(i))) {
                throw new PluginConfigurationException(
                    "Certificate file not found: " + certPaths.get(i));
            }
            if (!Files.exists(keyPaths.get(i))) {
                throw new PluginConfigurationException(
                    "Key file not found: " + keyPaths.get(i));
            }
        }

        System.out.println("═══════════════════════════════════════════════════════");
        System.out.println("🔐 Rotating TLS Credential Supplier Initialized");
        System.out.println("   Certificate pool size: " + certPaths.size());
        for (int i = 0; i < certPaths.size(); i++) {
            System.out.println("   Certificate " + (i + 1) + ": " + 
                certPaths.get(i).getFileName());
        }
        System.out.println("═══════════════════════════════════════════════════════");

        return new SharedContext(certPaths, keyPaths);
    }

    @Override
    public ServerTlsCredentialSupplier create(
            ServerTlsCredentialSupplierFactoryContext context,
            SharedContext sharedContext) {
        return new RotatingSupplier(sharedContext);
    }

    @Override
    public void close(SharedContext sharedContext) {
        System.out.println("═══════════════════════════════════════════════════════");
        System.out.println("🔐 Rotating TLS Credential Supplier Shutting Down");
        System.out.println("   Total connections handled: " + 
            sharedContext.totalConnections());
        System.out.println("═══════════════════════════════════════════════════════");
    }

    private static final Pattern PRIVATE_KEY_PATTERN = Pattern.compile(
            "-----BEGIN (?:RSA )?PRIVATE KEY-----\\s*(.+?)\\s*-----END (?:RSA )?PRIVATE KEY-----",
            Pattern.DOTALL);

    /**
     * Loads a PEM-encoded private key from a file.
     * Plugin authors are responsible for their own credential parsing.
     */
    static PrivateKey loadPrivateKey(Path path) throws Exception {
        String pem = Files.readString(path);
        Matcher matcher = PRIVATE_KEY_PATTERN.matcher(pem);
        if (!matcher.find()) {
            throw new IllegalArgumentException("No private key found in: " + path);
        }
        byte[] keyBytes = Base64.getDecoder().decode(matcher.group(1).replaceAll("\\s", ""));
        PKCS8EncodedKeySpec keySpec = new PKCS8EncodedKeySpec(keyBytes);
        for (String algorithm : new String[]{ "RSA", "EC", "DSA" }) {
            try {
                return KeyFactory.getInstance(algorithm).generatePrivate(keySpec);
            } catch (Exception ignored) {
                // try next
            }
        }
        throw new IllegalArgumentException("Could not parse private key from: " + path);
    }

    /**
     * Loads a PEM-encoded certificate chain from a file.
     * Plugin authors are responsible for their own credential parsing.
     */
    static Certificate[] loadCertificateChain(Path path) throws Exception {
        byte[] pemBytes = Files.readAllBytes(path);
        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        List<Certificate> certs = new ArrayList<>();
        try (ByteArrayInputStream bais = new ByteArrayInputStream(pemBytes)) {
            while (bais.available() > 0) {
                try {
                    certs.add(cf.generateCertificate(bais));
                } catch (Exception e) {
                    break;
                }
            }
        }
        if (certs.isEmpty()) {
            throw new IllegalArgumentException("No certificates found in: " + path);
        }
        return certs.toArray(new Certificate[0]);
    }

    /**
     * The actual credential supplier that handles per-connection requests
     */
    private static class RotatingSupplier implements ServerTlsCredentialSupplier {
        private final SharedContext sharedContext;

        RotatingSupplier(SharedContext sharedContext) {
            this.sharedContext = sharedContext;
        }

        @Override
        public CompletionStage<TlsCredentials> tlsCredentials(
                ServerTlsCredentialSupplierContext context) {
            
            // Select next certificate in rotation
            int index = sharedContext.nextIndex();
            int connectionNum = sharedContext.totalConnections();
            Path certPath = sharedContext.getCertPath(index);
            Path keyPath = sharedContext.getKeyPath(index);

            // ═══════════════════════════════════════════════════════
            // THIS IS THE KEY OBSERVATION POINT
            // This message prints for EVERY connection to Kafka
            // You'll see different certificates selected each time
            // ═══════════════════════════════════════════════════════
            System.out.println("═══════════════════════════════════════════════════════");
            System.out.println("🔐 TLS CREDENTIAL SUPPLIER INVOKED");
            System.out.println("   Connection #" + connectionNum);
            System.out.println("   Selected Certificate: " + certPath.getFileName());
            System.out.println("   Certificate Index: " + (index + 1) + " of " + 
                sharedContext.certPaths.size());
            
            // Log client context if available (for mTLS scenarios)
            context.clientTlsContext().ifPresent(clientTls -> {
                System.out.println("   Client TLS Context Present: Yes");
                clientTls.clientCertificate().ifPresent(cert -> {
                    System.out.println("   Client Certificate: " + 
                        cert.getSubjectX500Principal().getName());
                });
            });
            
            System.out.println("═══════════════════════════════════════════════════════");

            // Plugin is responsible for loading and parsing credentials
            // from whatever format it uses (PEM files in this case)
            try {
                PrivateKey privateKey = loadPrivateKey(keyPath);
                Certificate[] certChain = loadCertificateChain(certPath);

                // Pass already-parsed JDK objects to the context for validation and wrapping
                TlsCredentials creds = context.tlsCredentials(privateKey, certChain);
                return CompletableFuture.completedFuture(creds);

            } catch (Exception e) {
                System.err.println("Failed to load credentials: " + e.getMessage());
                e.printStackTrace();
                return CompletableFuture.failedFuture(e);
            }
        }
    }
}
