# Spring Framework 7 / Spring Boot 3+ - Konfiguracja mTLS

## Struktura plików

```
src/main/resources/
├── application.yml
├── application-mtls.yml
├── server-keystore.p12      # Skopiuj z certs/java-keystores/
├── client-keystore.p12      # Skopiuj z certs/java-keystores/
└── truststore.p12           # Skopiuj z certs/java-keystores/
```

## application.yml

```yaml
spring:
  application:
    name: secure-service
  profiles:
    active: mtls

server:
  port: 8443
  ssl:
    enabled: true
    key-store: classpath:server-keystore.p12
    key-store-password: ${SSL_KEYSTORE_PASSWORD:changeit}
    key-store-type: PKCS12
    key-alias: server
    # mTLS - wymagaj certyfikatu klienta
    client-auth: need  # 'need' = wymagany, 'want' = opcjonalny
    trust-store: classpath:truststore.p12
    trust-store-password: ${SSL_TRUSTSTORE_PASSWORD:changeit}
    trust-store-type: PKCS12
    # TLS 1.3 jako preferowany
    protocol: TLS
    enabled-protocols: TLSv1.3,TLSv1.2
    ciphers:
      - TLS_AES_256_GCM_SHA384
      - TLS_AES_128_GCM_SHA256
      - TLS_CHACHA20_POLY1305_SHA256

logging:
  level:
    javax.net.ssl: DEBUG  # Włącz dla debugowania TLS handshake
```

## application-mtls.yml (profil produkcyjny)

```yaml
server:
  ssl:
    key-store: file:/etc/ssl/server-keystore.p12
    trust-store: file:/etc/ssl/truststore.p12
```

## MtlsRestClientConfig.java

```java
package com.example.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.io.Resource;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.net.http.HttpClient;
import java.security.KeyStore;
import java.time.Duration;

/**
 * Konfiguracja RestClient z obsługą mTLS dla Java 25.
 * Używa nowoczesnego HttpClient z JDK zamiast Apache HttpClient.
 */
@Configuration
public class MtlsRestClientConfig {

    @Value("${mtls.client.keystore.path:classpath:client-keystore.p12}")
    private Resource keystoreResource;

    @Value("${mtls.client.keystore.password:changeit}")
    private String keystorePassword;

    @Value("${mtls.client.truststore.path:classpath:truststore.p12}")
    private Resource truststoreResource;

    @Value("${mtls.client.truststore.password:changeit}")
    private String truststorePassword;

    @Value("${mtls.client.base-url:https://localhost:8443}")
    private String baseUrl;

    @Bean
    public RestClient mtlsRestClient() throws Exception {
        SSLContext sslContext = createSslContext();

        HttpClient httpClient = HttpClient.newBuilder()
                .sslContext(sslContext)
                .connectTimeout(Duration.ofSeconds(10))
                .version(HttpClient.Version.HTTP_2)
                .build();

        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory(httpClient);
        requestFactory.setReadTimeout(Duration.ofSeconds(30));

        return RestClient.builder()
                .requestFactory(requestFactory)
                .baseUrl(baseUrl)
                .defaultHeader("Content-Type", "application/json")
                .build();
    }

    private SSLContext createSslContext() throws Exception {
        // Load client keystore (certificate + private key)
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (var is = keystoreResource.getInputStream()) {
            keyStore.load(is, keystorePassword.toCharArray());
        }

        KeyManagerFactory kmf = KeyManagerFactory.getInstance(
                KeyManagerFactory.getDefaultAlgorithm()
        );
        kmf.init(keyStore, keystorePassword.toCharArray());

        // Load truststore (CA certificates)
        KeyStore trustStore = KeyStore.getInstance("PKCS12");
        try (var is = truststoreResource.getInputStream()) {
            trustStore.load(is, truststorePassword.toCharArray());
        }

        TrustManagerFactory tmf = TrustManagerFactory.getInstance(
                TrustManagerFactory.getDefaultAlgorithm()
        );
        tmf.init(trustStore);

        // Initialize SSL context
        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);

        return sslContext;
    }
}
```

## SecureApiClient.java

```java
package com.example.client;

import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

@Component
public class SecureApiClient {

    private final RestClient mtlsRestClient;

    public SecureApiClient(RestClient mtlsRestClient) {
        this.mtlsRestClient = mtlsRestClient;
    }

    public String fetchSecureData() {
        return mtlsRestClient.get()
                .uri("/api/secure-data")
                .retrieve()
                .body(String.class);
    }

    public <T> T post(String path, Object body, Class<T> responseType) {
        return mtlsRestClient.post()
                .uri(path)
                .body(body)
                .retrieve()
                .body(responseType);
    }
}
```

## MtlsSecurityConfig.java (ekstrakcja CN z certyfikatu)

```java
package com.example.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.web.SecurityFilterChain;

import java.security.cert.X509Certificate;

@Configuration
@EnableWebSecurity
public class MtlsSecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        return http
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/health", "/actuator/**").permitAll()
                        .anyRequest().authenticated()
                )
                .x509(x509 -> x509
                        .subjectPrincipalRegex("CN=(.*?)(?:,|$)")
                        .userDetailsService(x509UserDetailsService())
                )
                .csrf(csrf -> csrf.disable())
                .build();
    }

    @Bean
    public UserDetailsService x509UserDetailsService() {
        return username -> User.withUsername(username)
                .password("")
                .authorities("ROLE_USER", "ROLE_CLIENT")
                .build();
    }
}
```

## Dockerfile

```dockerfile
FROM eclipse-temurin:25-jre-alpine

WORKDIR /app

# Kopiuj keystores
COPY --chown=1000:1000 target/*.jar app.jar
COPY --chown=1000:1000 src/main/resources/*.p12 /app/config/

# Użytkownik nie-root
USER 1000

ENV SSL_KEYSTORE_PASSWORD=changeit
ENV SSL_TRUSTSTORE_PASSWORD=changeit

EXPOSE 8443

ENTRYPOINT ["java", \
  "-Dspring.profiles.active=mtls", \
  "-Dserver.ssl.key-store=file:/app/config/server-keystore.p12", \
  "-Dserver.ssl.trust-store=file:/app/config/truststore.p12", \
  "-jar", "app.jar"]
```

## pom.xml (dependencies)

```xml
<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-security</artifactId>
    </dependency>
    <!-- Brak potrzeby dodatkowych zależności dla SSL - 
         Java 25 HttpClient obsługuje wszystko natywnie -->
</dependencies>
```

## Testowanie

```bash
# Test połączenia z certyfikatem klienta
curl --cert certs/client/client.crt \
     --key certs/client/client.key \
     --cacert certs/intermediate-ca/certs/ca-chain.crt \
     https://localhost:8443/api/test

# Lub z keystore PKCS12
curl --cert-type P12 \
     --cert certs/java-keystores/client-keystore.p12:changeit \
     --cacert certs/intermediate-ca/certs/ca-chain.crt \
     https://localhost:8443/api/test
```
