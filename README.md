# PKI Certificate Generator v2.1 (Multi-Client)

> **Idempotentne generowanie certyfikatów SSL/TLS** z obsługą wielu klientów mTLS, wykorzystujące OpenSSL w Docker.

## Spis treści

- [Wprowadzenie](#wprowadzenie)
- [Szybki start](#szybki-start)
- [Architektura PKI](#architektura-pki)
- [Zarządzanie klientami](#zarządzanie-klientami)
- [Użycie](#użycie)
- [Konfiguracja](#konfiguracja)
- [Integracja z frameworkami](#integracja-z-frameworkami)
- [Kubernetes](#kubernetes)

## Wprowadzenie

Generator PKI v2.1 zapewnia kompletne rozwiązanie do tworzenia hierarchii certyfikatów X.509 z natywnym wsparciem dla **wielu klientów mTLS**:

```
                    Intermediate CA
                          │
          ┌───────────────┼───────────────┬───────────────┐
          │               │               │               │
          ▼               ▼               ▼               ▼
      server.crt     service-a       service-b        admin
      (1 serwer)     (klient)        (klient)        (klient)
```

**Kluczowe funkcje:**
- **Multi-Client** — jeden serwer, wielu klientów z unikalnymi CN
- **Idempotentność** — CA generowane raz, klienci dodawani wielokrotnie
- **Granularna kontrola** — osobne cele Makefile dla każdej operacji
- **Właściwe uprawnienia** — pliki tworzone jako bieżący użytkownik (nie root)
- **Kubernetes-ready** — automatyczne Secret manifesty dla każdego klienta

## Szybki start

```bash
# 1. Rozpakuj i przejdź do katalogu
unzip pki-docker-generator-v2.1.zip && cd pki-docker-generator

# 2. Wygeneruj CA (jednorazowo)
make ca

# 3. Wygeneruj certyfikat serwera
make server

# 4. Dodaj klientów
make client CLIENT_CN="service-a@mycompany.com"
make client CLIENT_CN="service-b@mycompany.com"
make client CLIENT_CN="admin@mycompany.com"

# 5. Sprawdź listę klientów
make list

# 6. Zweryfikuj
make verify
```

**Lub wszystko na raz:**

```bash
DEFAULT_CLIENTS="service-a,service-b,admin" make all
```

**Z niestandardowymi SANs (Subject Alternative Names):**

```bash
# Dodaj własne domeny i IP do certyfikatu serwera
ADD_SERVER_SANS="DNS:vm1.local,DNS:myapp.local,IP:192.168.122.100" make server

# Lub zastąp domyślne SANs
SERVER_SANS="DNS:myserver.local,DNS:api.local,IP:10.0.0.50,IP:127.0.0.1" make server
```

## Architektura PKI

```
┌─────────────────────────────────────────────────────────────────┐
│                      ROOT CA (Self-Signed)                       │
│                     Ważność: 20 lat                              │
└─────────────────────────┬───────────────────────────────────────┘
                          │ podpisuje
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     INTERMEDIATE CA                              │
│                     Ważność: 10 lat                              │
└──────────┬──────────────┼──────────────┬───────────────┬────────┘
           │              │              │               │
           ▼              ▼              ▼               ▼
    ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
    │  SERVER  │   │ CLIENT-A │   │ CLIENT-B │   │  ADMIN   │
    │  1 rok   │   │  1 rok   │   │  1 rok   │   │  1 rok   │
    └──────────┘   └──────────┘   └──────────┘   └──────────┘
```

## Zarządzanie klientami

### Dodawanie klientów

```bash
# Pojedynczo (zalecane dla kontroli)
make client CLIENT_CN="service-a@mycompany.com"
make client CLIENT_CN="service-b"
make client CLIENT_CN="admin"

# Lub przez zmienną środowiskową
CLIENT_CN="monitoring-agent" make client

# Wielu klientów na raz
DEFAULT_CLIENTS="svc-a,svc-b,svc-c,admin" make clients
```

### Listowanie klientów

```bash
make list
```

Wynik:
```
=== Lista certyfikatów klientów ===

  ● service-a@mycompany.com
    Katalog:  clients/service-a_mycompany.com/
    Keystore: java-keystores/client-service-a_mycompany.com-keystore.p12
    Wygasa:   Dec 28 12:00:00 2026 GMT

  ● service-b
    Katalog:  clients/service-b/
    Keystore: java-keystores/client-service-b-keystore.p12
    Wygasa:   Dec 28 12:00:00 2026 GMT

[INFO] Łącznie klientów: 2
```

### Szczegóły klienta

```bash
make show-client CLIENT_CN="service-a@mycompany.com"
```

### Usuwanie klientów

```bash
# Usuń konkretnego klienta
make clean-client CLIENT_CN="service-a@mycompany.com"

# Usuń wszystkich klientów (zachowaj CA i server)
make clean-clients
```

### Regeneracja klienta

```bash
# Usuń i wygeneruj ponownie
make clean-client CLIENT_CN="service-a"
make client CLIENT_CN="service-a"
```

## Użycie

### Makefile — pełna lista celów

| Cel | Opis |
|-----|------|
| `make ca` | Root CA + Intermediate CA (jednorazowo) |
| `make server` | Certyfikat serwera |
| `make client CLIENT_CN=x` | Dodaj nowego klienta |
| `make clients` | Domyślni klienci (DEFAULT_CLIENTS) |
| `make certs` | Server + domyślni klienci |
| `make all` | Pełna generacja |
| `make list` | Lista wszystkich klientów |
| `make verify` | Weryfikacja łańcuchów |
| `make clean-client CLIENT_CN=x` | Usuń klienta |
| `make force-certs` | Regeneruj certyfikaty (zachowaj CA) |

### Skrypt bezpośredni

```bash
# Pełna generacja
./scripts/generate-certificates.sh

# Tylko CA
./scripts/generate-certificates.sh ca

# Tylko serwer
./scripts/generate-certificates.sh server

# Dodaj klienta
./scripts/generate-certificates.sh client --cn "service-a"

# Lista klientów
./scripts/generate-certificates.sh list

# Pomoc
./scripts/generate-certificates.sh help
```

## Konfiguracja

### Zmienne środowiskowe

| Zmienna | Domyślnie | Opis |
|---------|-----------|------|
| `DEFAULT_CLIENTS` | `default-client` | Lista klientów (przecinek) |
| `CLIENT_CN` | (puste) | CN dla nowego klienta |
| `SERVER_CN` | `localhost` | CN serwera |
| `ORGANIZATION` | `MyCompany` | Nazwa organizacji |
| `KEYSTORE_PASSWORD` | `changeit` | Hasło keystores |
| `CLIENT_CERT_DAYS` | `365` | Ważność cert. klienta |
| `FORCE_REGENERATE_CERTS` | `false` | Wymuś regenerację |

### Struktura wygenerowanych plików

```
certs/
├── root-ca/
│   ├── certs/rootCA.crt
│   └── private/rootCA.key
├── intermediate-ca/
│   ├── certs/
│   │   ├── intermediateCA.crt
│   │   └── ca-chain.crt
│   └── private/intermediateCA.key
├── server/
│   ├── server.key
│   ├── server.crt
│   └── server-full-chain.crt
├── clients/
│   ├── service-a/
│   │   ├── client.key
│   │   ├── client.crt
│   │   └── CN.txt              # Oryginalny CN
│   ├── service-b/
│   │   ├── client.key
│   │   ├── client.crt
│   │   └── CN.txt
│   └── admin/
│       ├── client.key
│       ├── client.crt
│       └── CN.txt
├── java-keystores/
│   ├── server-keystore.p12
│   ├── truststore.p12
│   ├── client-service-a-keystore.p12
│   ├── client-service-b-keystore.p12
│   └── client-admin-keystore.p12
└── kubernetes/
    └── tls-secrets.yaml        # Wszystkie secrety
```

## Integracja z frameworkami

### Spring Boot — wybór klienta

```yaml
# application-service-a.yml
spring:
  profiles: service-a
  ssl:
    bundle:
      jks:
        client:
          keystore:
            location: classpath:client-service-a-keystore.p12
            password: ${SSL_KEYSTORE_PASSWORD:changeit}
          truststore:
            location: classpath:truststore.p12
            password: ${SSL_TRUSTSTORE_PASSWORD:changeit}

# Użycie w RestClient
mtls:
  client:
    keystore:
      path: classpath:client-service-a-keystore.p12
```

### Quarkus — named clients

```properties
# Service A
quarkus.rest-client."ServiceAClient".key-store=client-service-a-keystore.p12
quarkus.rest-client."ServiceAClient".key-store-password=${SSL_KEYSTORE_PASSWORD}

# Service B  
quarkus.rest-client."ServiceBClient".key-store=client-service-b-keystore.p12
quarkus.rest-client."ServiceBClient".key-store-password=${SSL_KEYSTORE_PASSWORD}
```

### Serwer — rozpoznawanie klientów po CN

```java
@GetMapping("/api/whoami")
public String whoami(HttpServletRequest request) {
    X509Certificate[] certs = (X509Certificate[]) 
        request.getAttribute("jakarta.servlet.request.X509Certificate");
    
    if (certs != null && certs.length > 0) {
        String dn = certs[0].getSubjectX500Principal().getName();
        // CN=service-a@mycompany.com,O=MyCompany,C=PL
        String cn = extractCN(dn);
        
        return switch (cn) {
            case "admin" -> handleAdminRequest();
            case "service-a" -> handleServiceARequest();
            default -> handleGenericRequest();
        };
    }
    return "Unknown client";
}
```

## Kubernetes

### Automatyczne Secret manifesty

Generator tworzy osobny Secret dla każdego klienta:

```yaml
# certs/kubernetes/tls-secrets.yaml

---
# Server TLS
apiVersion: v1
kind: Secret
metadata:
  name: tls-server
type: kubernetes.io/tls
data:
  tls.crt: ...
  tls.key: ...

---
# Client: service-a
apiVersion: v1
kind: Secret
metadata:
  name: mtls-client-service-a
  labels:
    pki.generator/client-cn: "service-a"
data:
  client.crt: ...
  client.key: ...
  client-keystore.p12: ...

---
# Client: service-b
apiVersion: v1
kind: Secret
metadata:
  name: mtls-client-service-b
data:
  client.crt: ...
  client.key: ...
```

### Deployment z wybranym klientem

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: service-a
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: SSL_KEYSTORE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mtls-client-service-a
                  key: keystore-password
          volumeMounts:
            - name: mtls-certs
              mountPath: /app/config/ssl
      volumes:
        - name: mtls-certs
          secret:
            secretName: mtls-client-service-a
            items:
              - key: client-keystore.p12
                path: client-keystore.p12
              - key: ca-chain.crt
                path: ca-chain.crt
```

## Typowe scenariusze

### Mikrousługi z mTLS

```bash
# 1. Wygeneruj CA i serwer
make ca
make server

# 2. Dodaj klienta dla każdej usługi
make client CLIENT_CN="user-service"
make client CLIENT_CN="order-service"
make client CLIENT_CN="payment-service"
make client CLIENT_CN="notification-service"

# 3. Wdróż na Kubernetes
kubectl apply -f certs/kubernetes/tls-secrets.yaml
```

### Rotacja certyfikatu jednego klienta

```bash
# Usuń stary certyfikat
make clean-client CLIENT_CN="payment-service"

# Wygeneruj nowy
make client CLIENT_CN="payment-service"

# Zaktualizuj Secret w K8s
kubectl apply -f certs/kubernetes/tls-secrets.yaml
```

### Środowisko developerskie vs produkcyjne

```bash
# Dev - prosty setup
make ca
make server
make client CLIENT_CN="dev-client"

# Prod - wielu klientów
DEFAULT_CLIENTS="api-gateway,auth-service,user-service,order-service" \
  ORGANIZATION="ACME Corp" \
  make all
```

## FAQ

**Q: Jak dodać nowego klienta bez regeneracji istniejących?**

A: Po prostu użyj `make client CLIENT_CN="nowy-klient"` — istniejące certyfikaty nie są modyfikowane.

**Q: Czy mogę mieć różne hasła dla różnych klientów?**

A: Obecnie wszystkie keystory używają tego samego hasła (`KEYSTORE_PASSWORD`). Dla różnych haseł zmodyfikuj skrypt lub użyj osobnych wywołań z różnymi zmiennymi.

**Q: Jak sprawdzić, który klient się łączy?**

A: W aplikacji Java wyciągnij CN z certyfikatu klienta (patrz sekcja "Serwer — rozpoznawanie klientów po CN").

**Q: Czy nazwy klientów mogą zawierać znaki specjalne?**

A: CN może zawierać dowolne znaki (np. `service-a@company.com`), ale nazwa katalogu jest sanityzowana do bezpiecznych znaków.

## Changelog

### v2.1.0
- Multi-client support
- Osobne katalogi i keystores dla każdego klienta
- Nowe cele: `make client`, `make list`, `make clean-client`
- Kubernetes Secrets per-client
- Plik CN.txt dla zachowania oryginalnego CN

### v2.0.0
- Idempotentne generowanie CA
- Podstawowa struktura PKI
