/*
 * Logging Principal Builder for Certificate Identity Validation
 * 
 * This principal builder logs the CN from client certificates to demonstrate
 * that Kroxylicious is presenting different certificate identities to Kafka
 * when using the TLS credential supplier plugin.
 * 
 * Expected log output:
 *   ════════════════════════════════════════════════════════════
 *   ✅ CLIENT AUTHENTICATED via mTLS
 *      Certificate CN: proxy-client-1
 *      Subject DN: CN=proxy-client-1,O=Demo,C=US
 *   ════════════════════════════════════════════════════════════
 */
package io.kroxylicious.demo;

import java.nio.charset.StandardCharsets;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSession;

import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.security.auth.AuthenticationContext;
import org.apache.kafka.common.security.auth.KafkaPrincipal;
import org.apache.kafka.common.security.auth.KafkaPrincipalBuilder;
import org.apache.kafka.common.security.auth.KafkaPrincipalSerde;
import org.apache.kafka.common.security.auth.PlaintextAuthenticationContext;
import org.apache.kafka.common.security.auth.SslAuthenticationContext;

public class LoggingPrincipalBuilder implements KafkaPrincipalBuilder, KafkaPrincipalSerde {
    private static final Pattern CN_PATTERN = Pattern.compile("^.*CN=([^,]+).*$");
    
    @Override
    public KafkaPrincipal build(AuthenticationContext authContext) {
        if (authContext instanceof SslAuthenticationContext) {
            SSLSession session = ((SslAuthenticationContext) authContext).session();
            try {
                Certificate[] peerCerts = session.getPeerCertificates();
                if (peerCerts == null || peerCerts.length == 0) {
                    System.err.println("❌ No peer certificates found");
                    return KafkaPrincipal.ANONYMOUS;
                }
                
                X509Certificate cert = findFirstX509Certificate(peerCerts);
                if (cert == null) {
                    System.err.println("❌ No X509 certificate found");
                    return KafkaPrincipal.ANONYMOUS;
                }
                
                String dn = cert.getSubjectX500Principal().getName();
                Matcher cnMatcher = CN_PATTERN.matcher(dn);
                
                String cn = cnMatcher.find() ? cnMatcher.group(1) : dn;
                
                // ════════════════════════════════════════════════════════════
                // THIS IS THE KEY OBSERVATION POINT
                // Each different CN proves the TLS credential supplier is working!
                // ════════════════════════════════════════════════════════════
                System.out.println("════════════════════════════════════════════════════════════");
                System.out.println("✅ CLIENT AUTHENTICATED via mTLS");
                System.out.println("   Certificate CN: " + cn);
                System.out.println("   Subject DN: " + dn);
                System.out.println("   Session: " + session.getProtocol() + " / " + session.getCipherSuite());
                System.out.println("════════════════════════════════════════════════════════════");
                
                return new KafkaPrincipal(KafkaPrincipal.USER_TYPE, cn);
                
            } catch (SSLPeerUnverifiedException e) {
                System.err.println("❌ SSL peer unverified: " + e.getMessage());
                return KafkaPrincipal.ANONYMOUS;
            }
        } else if (authContext instanceof PlaintextAuthenticationContext) {
            System.out.println("ℹ️  PLAINTEXT connection (no certificate)");
            return KafkaPrincipal.ANONYMOUS;
        }
        
        throw new IllegalArgumentException(
            "Unhandled authentication context type: " + authContext.getClass().getName());
    }
    
    private X509Certificate findFirstX509Certificate(Certificate[] peerCerts) {
        for (Certificate cert : peerCerts) {
            if (cert instanceof X509Certificate) {
                return (X509Certificate) cert;
            }
        }
        return null;
    }
    
    @Override
    public byte[] serialize(KafkaPrincipal principal) {
        if (principal == null) {
            throw new KafkaException("Cannot serialize a null KafkaPrincipal.");
        }
        String principalString = String.format("%s:%s", principal.getPrincipalType(), principal.getName());
        return principalString.getBytes(StandardCharsets.UTF_8);
    }

    @Override
    public KafkaPrincipal deserialize(byte[] bytes) {
        if (bytes == null || bytes.length == 0) {
            throw new KafkaException("Failed to deserialize principal. Empty or null byte array provided.");
        }

        try {
            String[] principal = new String(bytes, StandardCharsets.UTF_8).split(":", 2);
            return principal.length == 2 
                ? new KafkaPrincipal(principal[0], principal[1]) 
                : KafkaPrincipal.ANONYMOUS;
        } catch (Exception e) {
            throw new KafkaException("Failed to deserialize principal", e);
        }
    }
}
