# Quarkus 3+ - Konfiguracja mTLS

## Struktura plików

```
src/main/resources/
├── application.properties
├── server-keystore.p12      # Skopiuj z certs/java-keystores/
├── client-keystore.p12      # Skopiuj z certs/java-keystores/
└── truststore.p12           # Skopiuj z certs/java-keystores/
```

## application.properties

```properties
# =============================================================================
# Server TLS Configuration
# =============================================================================
quarkus.http.port=8080
quarkus.http.ssl-port=8443
quarkus.http.insecure-requests=redirect

# Keystore (server certificate + key)
quarkus.http.ssl.certificate.key-store-file=server-keystore.p12
quarkus.http.ssl.certificate.key-store-password=${SSL_KEYSTORE_PASSWORD:changeit}
quarkus.http.ssl.certificate.key-store-file-type=PKCS12

# Truststore (CA certificates for client verification)
quarkus.http.ssl.certificate.trust-store-file=truststore.p12
quarkus.http.ssl.certificate.trust-store-password=${SSL_TRUSTSTORE_PASSWORD:changeit}
quarkus.http.ssl.certificate.trust-store-file-type=PKCS12

# mTLS - require client certificate
quarkus.http.ssl.client-auth=required

# TLS protocols
quarkus.http.ssl.protocols=TLSv1.3,TLSv1.2

# =============================================================================
# TLS Registry (Quarkus 3.9+) - zalecane podejście
# =============================================================================
quarkus.tls.server.key-store.p12.path=server-keystore.p12
quarkus.tls.server.key-store.p12.password=${SSL_KEYSTORE_PASSWORD:changeit}
quarkus.tls.server.trust-store.p12.path=truststore.p12
quarkus.tls.server.trust-store.p12.password=${SSL_TRUSTSTORE_PASSWORD:changeit}

# =============================================================================
# REST Client mTLS Configuration
# =============================================================================
# Dla interfejsu SecureApiClient
quarkus.rest-client."com.example.client.SecureApiClient".url=https://secure-service:8443
quarkus.rest-client."com.example.client.SecureApiClient".key-store=client-keystore.p12
quarkus.rest-client."com.example.client.SecureApiClient".key-store-password=${SSL_KEYSTORE_PASSWORD:changeit}
quarkus.rest-client."com.example.client.SecureApiClient".trust-store=truststore.p12
quarkus.rest-client."com.example.client.SecureApiClient".trust-store-password=${SSL_TRUSTSTORE_PASSWORD:changeit}
quarkus.rest-client."com.example.client.SecureApiClient".hostname-verifier=io.quarkus.restclient.NoopHostnameVerifier

# Timeout configuration
quarkus.rest-client."com.example.client.SecureApiClient".connect-timeout=5000
quarkus.rest-client."com.example.client.SecureApiClient".read-timeout=30000

# =============================================================================
# Logging
# =============================================================================
quarkus.log.category."io.quarkus.vertx.http.runtime.options".level=DEBUG
quarkus.log.category."javax.net.ssl".level=DEBUG
```

## SecureApiClient.java (REST Client interface)

```java
package com.example.client;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/api")
@RegisterRestClient(configKey = "com.example.client.SecureApiClient")
public interface SecureApiClient {

    @GET
    @Path("/secure-data")
    @Produces(MediaType.APPLICATION_JSON)
    SecureData fetchSecureData();

    @POST
    @Path("/secure-data")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    SecureData createSecureData(SecureData data);
}
```

## SecureResource.java (endpoint z mTLS)

```java
package com.example.resource;

import io.quarkus.security.identity.SecurityIdentity;
import io.vertx.ext.web.RoutingContext;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.security.cert.X509Certificate;

@Path("/api")
public class SecureResource {

    @Inject
    SecurityIdentity securityIdentity;

    @Inject
    RoutingContext routingContext;

    @GET
    @Path("/whoami")
    @Produces(MediaType.APPLICATION_JSON)
    public ClientInfo whoami() {
        // Pobierz certyfikat klienta z mTLS
        X509Certificate clientCert = extractClientCertificate();
        
        String cn = "unknown";
        if (clientCert != null) {
            cn = extractCN(clientCert.getSubjectX500Principal().getName());
        }

        return new ClientInfo(
                cn,
                securityIdentity.getPrincipal().getName(),
                securityIdentity.getRoles()
        );
    }

    @GET
    @Path("/secure-data")
    @Produces(MediaType.APPLICATION_JSON)
    public SecureData getSecureData() {
        return new SecureData("Sensitive information", System.currentTimeMillis());
    }

    private X509Certificate extractClientCertificate() {
        try {
            var sslSession = routingContext.request().sslSession();
            if (sslSession != null) {
                var certs = sslSession.getPeerCertificates();
                if (certs != null && certs.length > 0) {
                    return (X509Certificate) certs[0];
                }
            }
        } catch (Exception e) {
            // No client certificate
        }
        return null;
    }

    private String extractCN(String dn) {
        for (String part : dn.split(",")) {
            if (part.trim().startsWith("CN=")) {
                return part.trim().substring(3);
            }
        }
        return dn;
    }

    public record ClientInfo(String commonName, String principal, java.util.Set<String> roles) {}
    public record SecureData(String data, long timestamp) {}
}
```

## MtlsClientProducer.java (programowe tworzenie klienta)

```java
package com.example.config;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;
import jakarta.inject.Named;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.InputStream;
import java.net.http.HttpClient;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.time.Duration;

@ApplicationScoped
public class MtlsClientProducer {

    @ConfigProperty(name = "mtls.client.keystore.path", defaultValue = "client-keystore.p12")
    String keystorePath;

    @ConfigProperty(name = "mtls.client.keystore.password", defaultValue = "changeit")
    String keystorePassword;

    @ConfigProperty(name = "mtls.client.truststore.path", defaultValue = "truststore.p12")
    String truststorePath;

    @ConfigProperty(name = "mtls.client.truststore.password", defaultValue = "changeit")
    String truststorePassword;

    @Produces
    @Named("mtlsHttpClient")
    public HttpClient mtlsHttpClient() throws Exception {
        SSLContext sslContext = createSslContext();

        return HttpClient.newBuilder()
                .sslContext(sslContext)
                .connectTimeout(Duration.ofSeconds(10))
                .version(HttpClient.Version.HTTP_2)
                .build();
    }

    private SSLContext createSslContext() throws Exception {
        // KeyStore
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (InputStream is = loadResource(keystorePath)) {
            keyStore.load(is, keystorePassword.toCharArray());
        }

        KeyManagerFactory kmf = KeyManagerFactory.getInstance(
                KeyManagerFactory.getDefaultAlgorithm()
        );
        kmf.init(keyStore, keystorePassword.toCharArray());

        // TrustStore
        KeyStore trustStore = KeyStore.getInstance("PKCS12");
        try (InputStream is = loadResource(truststorePath)) {
            trustStore.load(is, truststorePassword.toCharArray());
        }

        TrustManagerFactory tmf = TrustManagerFactory.getInstance(
                TrustManagerFactory.getDefaultAlgorithm()
        );
        tmf.init(trustStore);

        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);

        return sslContext;
    }

    private InputStream loadResource(String path) throws Exception {
        // Try classpath first
        InputStream is = getClass().getClassLoader().getResourceAsStream(path);
        if (is != null) {
            return is;
        }
        // Fall back to file system
        return Files.newInputStream(Path.of(path));
    }
}
```

## Dockerfile.jvm

```dockerfile
FROM registry.access.redhat.com/ubi8/openjdk-25-runtime:latest

ENV LANGUAGE='en_US:en'

WORKDIR /app

# Kopiuj aplikację
COPY --chown=185 target/quarkus-app/lib/ /app/lib/
COPY --chown=185 target/quarkus-app/*.jar /app/
COPY --chown=185 target/quarkus-app/app/ /app/app/
COPY --chown=185 target/quarkus-app/quarkus/ /app/quarkus/

# Kopiuj keystores
COPY --chown=185 src/main/resources/*.p12 /app/config/

USER 185

ENV SSL_KEYSTORE_PASSWORD=changeit
ENV SSL_TRUSTSTORE_PASSWORD=changeit
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/app/quarkus-run.jar"

EXPOSE 8443

ENTRYPOINT [ "/opt/jboss/container/java/run/run-java.sh" ]
```

## Dockerfile.native

```dockerfile
FROM quay.io/quarkus/quarkus-micro-image:2.0

WORKDIR /work/

# Kopiuj native executable
COPY --chown=1001:root target/*-runner /work/application

# Kopiuj keystores
COPY --chown=1001:root src/main/resources/*.p12 /work/config/

USER 1001

ENV SSL_KEYSTORE_PASSWORD=changeit
ENV SSL_TRUSTSTORE_PASSWORD=changeit

EXPOSE 8443

CMD ["./application", "-Dquarkus.http.host=0.0.0.0"]
```

## pom.xml (dependencies)

```xml
<dependencies>
    <dependency>
        <groupId>io.quarkus</groupId>
        <artifactId>quarkus-rest</artifactId>
    </dependency>
    <dependency>
        <groupId>io.quarkus</groupId>
        <artifactId>quarkus-rest-client</artifactId>
    </dependency>
    <dependency>
        <groupId>io.quarkus</groupId>
        <artifactId>quarkus-rest-jackson</artifactId>
    </dependency>
    <dependency>
        <groupId>io.quarkus</groupId>
        <artifactId>quarkus-security</artifactId>
    </dependency>
    <dependency>
        <groupId>io.quarkus</groupId>
        <artifactId>quarkus-tls-registry</artifactId>
    </dependency>
</dependencies>
```

## Testowanie

```bash
# Build
./mvnw package

# Run
SSL_KEYSTORE_PASSWORD=changeit SSL_TRUSTSTORE_PASSWORD=changeit \
  java -jar target/quarkus-app/quarkus-run.jar

# Test mTLS
curl --cert certs/client/client.crt \
     --key certs/client/client.key \
     --cacert certs/intermediate-ca/certs/ca-chain.crt \
     https://localhost:8443/api/whoami
```
