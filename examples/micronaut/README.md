# Micronaut 4+ - Konfiguracja mTLS

## Struktura plików

```
src/main/resources/
├── application.yml
├── server-keystore.p12      # Skopiuj z certs/java-keystores/
├── client-keystore.p12      # Skopiuj z certs/java-keystores/
└── truststore.p12           # Skopiuj z certs/java-keystores/
```

## application.yml

```yaml
micronaut:
  application:
    name: secure-service
    
  server:
    port: 8443
    ssl:
      enabled: true
      build-self-signed: false
      key-store:
        path: classpath:server-keystore.p12
        password: ${SSL_KEYSTORE_PASSWORD:changeit}
        type: PKCS12
      trust-store:
        path: classpath:truststore.p12
        password: ${SSL_TRUSTSTORE_PASSWORD:changeit}
        type: PKCS12
      # mTLS - wymagaj certyfikatu klienta
      client-authentication: need  # 'need' = required, 'want' = optional
      protocol: TLS
      protocols:
        - TLSv1.3
        - TLSv1.2
      ciphers:
        - TLS_AES_256_GCM_SHA384
        - TLS_AES_128_GCM_SHA256
        - TLS_CHACHA20_POLY1305_SHA256

  # HTTP Client z mTLS
  http:
    client:
      ssl:
        enabled: true
        key-store:
          path: classpath:client-keystore.p12
          password: ${SSL_KEYSTORE_PASSWORD:changeit}
          type: PKCS12
        trust-store:
          path: classpath:truststore.p12
          password: ${SSL_TRUSTSTORE_PASSWORD:changeit}
          type: PKCS12
      read-timeout: 30s
      connect-timeout: 10s

  # Security
  security:
    enabled: true
    x509:
      enabled: true
      subject-dn-regex: "CN=(.*?)(?:,|$)"

# Declarative HTTP Client
secure-api:
  url: https://secure-service:8443

# Logging
logger:
  levels:
    io.micronaut.http.client: DEBUG
    io.netty.handler.ssl: DEBUG
```

## SecureController.java

```java
package com.example.controller;

import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.Produces;
import io.micronaut.http.MediaType;
import io.micronaut.security.annotation.Secured;
import io.micronaut.security.authentication.Authentication;
import io.micronaut.security.rules.SecurityRule;

import java.security.Principal;
import java.util.Map;

@Controller("/api")
@Secured(SecurityRule.IS_AUTHENTICATED)
public class SecureController {

    @Get("/whoami")
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, Object> whoami(Principal principal, Authentication authentication) {
        return Map.of(
                "principal", principal.getName(),
                "attributes", authentication.getAttributes(),
                "roles", authentication.getRoles()
        );
    }

    @Get("/secure-data")
    @Produces(MediaType.APPLICATION_JSON)
    public SecureData getSecureData() {
        return new SecureData("Sensitive information", System.currentTimeMillis());
    }

    public record SecureData(String data, long timestamp) {}
}
```

## SecureApiClient.java (Declarative HTTP Client)

```java
package com.example.client;

import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.Post;
import io.micronaut.http.annotation.Body;
import io.micronaut.http.client.annotation.Client;

@Client(id = "secure-api")
public interface SecureApiClient {

    @Get("/api/secure-data")
    SecureData fetchSecureData();

    @Post("/api/secure-data")
    SecureData createSecureData(@Body SecureData data);

    record SecureData(String data, long timestamp) {}
}
```

## MtlsHttpClientFactory.java (programowe tworzenie klienta)

```java
package com.example.config;

import io.micronaut.context.annotation.Bean;
import io.micronaut.context.annotation.Factory;
import io.micronaut.context.annotation.Value;
import jakarta.inject.Named;
import jakarta.inject.Singleton;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.InputStream;
import java.net.http.HttpClient;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.time.Duration;

@Factory
public class MtlsHttpClientFactory {

    @Value("${mtls.client.keystore.path:classpath:client-keystore.p12}")
    private String keystorePath;

    @Value("${mtls.client.keystore.password:changeit}")
    private String keystorePassword;

    @Value("${mtls.client.truststore.path:classpath:truststore.p12}")
    private String truststorePath;

    @Value("${mtls.client.truststore.password:changeit}")
    private String truststorePassword;

    @Bean
    @Singleton
    @Named("mtlsClient")
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
        if (path.startsWith("classpath:")) {
            String resourcePath = path.substring("classpath:".length());
            InputStream is = getClass().getClassLoader().getResourceAsStream(resourcePath);
            if (is != null) {
                return is;
            }
            throw new IllegalArgumentException("Resource not found: " + resourcePath);
        }
        return Files.newInputStream(Path.of(path));
    }
}
```

## X509AuthenticationProvider.java (uwierzytelnianie przez certyfikat)

```java
package com.example.security;

import io.micronaut.context.annotation.Requires;
import io.micronaut.http.HttpRequest;
import io.micronaut.security.authentication.AuthenticationFailureReason;
import io.micronaut.security.authentication.AuthenticationRequest;
import io.micronaut.security.authentication.AuthenticationResponse;
import io.micronaut.security.authentication.provider.HttpRequestAuthenticationProvider;
import jakarta.inject.Singleton;

import java.security.cert.X509Certificate;
import java.util.List;

@Singleton
@Requires(property = "micronaut.security.x509.enabled", value = "true")
public class X509AuthenticationProvider<B> implements HttpRequestAuthenticationProvider<B> {

    @Override
    public AuthenticationResponse authenticate(
            HttpRequest<B> httpRequest,
            AuthenticationRequest<String, String> authenticationRequest
    ) {
        // W mTLS, certyfikat jest już zweryfikowany przez SSL layer
        // Tu tylko wyciągamy CN jako identity
        
        String identity = authenticationRequest.getIdentity();
        
        if (identity != null && !identity.isBlank()) {
            return AuthenticationResponse.success(
                    identity,
                    List.of("ROLE_USER", "ROLE_CLIENT")
            );
        }
        
        return AuthenticationResponse.failure(AuthenticationFailureReason.CREDENTIALS_DO_NOT_MATCH);
    }
}
```

## Dockerfile

```dockerfile
FROM eclipse-temurin:25-jre-alpine

WORKDIR /app

# Kopiuj aplikację
COPY --chown=1000:1000 target/secure-service-*.jar app.jar
COPY --chown=1000:1000 src/main/resources/*.p12 /app/config/

USER 1000

ENV SSL_KEYSTORE_PASSWORD=changeit
ENV SSL_TRUSTSTORE_PASSWORD=changeit
ENV MICRONAUT_SERVER_SSL_KEY_STORE_PATH=file:/app/config/server-keystore.p12
ENV MICRONAUT_SERVER_SSL_TRUST_STORE_PATH=file:/app/config/truststore.p12

EXPOSE 8443

ENTRYPOINT ["java", "-jar", "app.jar"]
```

## build.gradle.kts (dependencies)

```kotlin
dependencies {
    annotationProcessor("io.micronaut:micronaut-http-validation")
    annotationProcessor("io.micronaut.security:micronaut-security-annotations")
    annotationProcessor("io.micronaut.serde:micronaut-serde-processor")
    
    implementation("io.micronaut:micronaut-http-client")
    implementation("io.micronaut:micronaut-http-server-netty")
    implementation("io.micronaut.security:micronaut-security")
    implementation("io.micronaut.serde:micronaut-serde-jackson")
    
    runtimeOnly("ch.qos.logback:logback-classic")
    runtimeOnly("org.yaml:snakeyaml")
}
```

## pom.xml (dependencies dla Maven)

```xml
<dependencies>
    <dependency>
        <groupId>io.micronaut</groupId>
        <artifactId>micronaut-http-server-netty</artifactId>
    </dependency>
    <dependency>
        <groupId>io.micronaut</groupId>
        <artifactId>micronaut-http-client</artifactId>
    </dependency>
    <dependency>
        <groupId>io.micronaut.security</groupId>
        <artifactId>micronaut-security</artifactId>
    </dependency>
    <dependency>
        <groupId>io.micronaut.serde</groupId>
        <artifactId>micronaut-serde-jackson</artifactId>
    </dependency>
    <dependency>
        <groupId>ch.qos.logback</groupId>
        <artifactId>logback-classic</artifactId>
        <scope>runtime</scope>
    </dependency>
</dependencies>
```

## Testowanie

```bash
# Build (Gradle)
./gradlew build

# Build (Maven)
./mvnw package

# Run
SSL_KEYSTORE_PASSWORD=changeit SSL_TRUSTSTORE_PASSWORD=changeit \
  java -jar target/secure-service-*.jar

# Test mTLS
curl --cert certs/client/client.crt \
     --key certs/client/client.key \
     --cacert certs/intermediate-ca/certs/ca-chain.crt \
     https://localhost:8443/api/whoami

# Test bez certyfikatu (powinien być odrzucony)
curl --cacert certs/intermediate-ca/certs/ca-chain.crt \
     https://localhost:8443/api/whoami
# Expected: SSL handshake error
```

## GraalVM Native Image

Dla native image dodaj konfigurację SSL:

**src/main/resources/META-INF/native-image/reflect-config.json:**

```json
[
  {
    "name": "sun.security.ssl.SSLContextImpl$TLS13Context",
    "methods": [{"name": "<init>", "parameterTypes": []}]
  },
  {
    "name": "sun.security.provider.X509Factory",
    "methods": [{"name": "<init>", "parameterTypes": []}]
  }
]
```

**build.gradle.kts:**

```kotlin
graalvmNative {
    binaries {
        named("main") {
            buildArgs.add("--enable-https")
            buildArgs.add("--enable-all-security-services")
        }
    }
}
```
