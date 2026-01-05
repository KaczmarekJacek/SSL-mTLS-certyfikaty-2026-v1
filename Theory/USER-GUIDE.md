# PKI Docker Generator v2.1 — Dokumentacja użytkowa

> Kompletny przewodnik generowania certyfikatów SSL/TLS z obsługą wielu klientów mTLS.

## Spis treści

1. [Wprowadzenie](#wprowadzenie)
2. [Wymagania](#wymagania)
3. [Szybki start](#szybki-start)
4. [Struktura projektu](#struktura-projektu)
5. [Komendy Makefile](#komendy-makefile)
6. [Zarządzanie klientami](#zarządzanie-klientami)
7. [Zmienne konfiguracyjne](#zmienne-konfiguracyjne)
8. [Scenariusze użycia](#scenariusze-użycia)
9. [Integracja z frameworkami Java](#integracja-z-frameworkami-java)
10. [Kubernetes](#kubernetes)
11. [Weryfikacja i diagnostyka](#weryfikacja-i-diagnostyka)

---

## Wprowadzenie

PKI Docker Generator v2.1 to narzędzie do generowania kompletnej hierarchii certyfikatów X.509 z wykorzystaniem OpenSSL uruchamianego w kontenerze Docker.

### Kluczowe cechy

| Cecha | Opis |
|-------|------|
| **Multi-Client** | Jeden serwer, wielu klientów z unikalnymi CN |
| **Idempotentność** | CA generowane raz, klienci dodawani wielokrotnie |
| **Docker-based** | Nie wymaga lokalnej instalacji OpenSSL |
| **Java-ready** | Automatyczne keystores PKCS12 |
| **Kubernetes-ready** | Generowanie manifestów Secret |

### Kompatybilność

- Java 21, 25
- Spring Boot 3+, Spring Framework 7
- Quarkus 3+
- Micronaut 4+
- Kubernetes 1.25+

---

## Wymagania

- **Docker** — dowolna wersja obsługująca `docker run`
- **Bash 4.0+** — standardowo dostępny na Linux/macOS
- **Make** — opcjonalnie, dla wygodniejszego użycia
- **~50MB** wolnego miejsca na dysku

Generator automatycznie pobiera obraz Docker `alpine/openssl` przy pierwszym uruchomieniu.

---

## Szybki start

### Opcja 1: Krok po kroku (zalecane na początek)

```bash
# 1. Rozpakuj projekt
unzip pki-docker-generator-v2.1.zip
cd pki-docker-generator

# 2. Wygeneruj CA (jednorazowo)
make ca

# 3. Wygeneruj certyfikat serwera
make server

# 4. Dodaj klientów
make client CLIENT_CN="service-a"
make client CLIENT_CN="service-b"
make client CLIENT_CN="admin"

# 5. Sprawdź listę klientów
make list

# 6. Zweryfikuj poprawność
make verify
```

### Opcja 2: Wszystko na raz

```bash
# Generuj CA + server + wielu klientów jednym poleceniem
DEFAULT_CLIENTS="service-a,service-b,admin" make all
```

### Opcja 3: Skrypt bezpośredni (bez Make)

```bash
chmod +x scripts/generate-certificates.sh

# Pełna generacja
./scripts/generate-certificates.sh

# Tylko CA
./scripts/generate-certificates.sh ca

# Dodaj klienta
./scripts/generate-certificates.sh client --cn "service-a"

# Pomoc
./scripts/generate-certificates.sh help
```

---

## Struktura projektu

### Struktura źródłowa (przed generowaniem)

```
pki-docker-generator/
├── scripts/
│   └── generate-certificates.sh    # Główny skrypt generujący
├── examples/
│   ├── spring7/README.md           # Przykłady dla Spring
│   ├── quarkus/README.md           # Przykłady dla Quarkus
│   ├── micronaut/README.md         # Przykłady dla Micronaut
│   └── kubernetes/README.md        # Przykłady dla K8s
├── docs/
│   └── ARCHITECTURE.md             # Dokumentacja techniczna PKI
├── certs/                          # Katalog na wygenerowane certyfikaty
│   └── .gitkeep
├── Makefile                        # Cele automatyzacji
├── README.md                       # Dokumentacja
├── generate-certificates.sh        # Symlink do scripts/
└── .gitignore
```

### Struktura po wygenerowaniu certyfikatów

```
certs/
├── root-ca/
│   ├── certs/
│   │   └── rootCA.crt              # Certyfikat Root CA (publiczny)
│   ├── private/
│   │   └── rootCA.key              # Klucz prywatny Root CA (TAJNY!)
│   ├── index.txt                   # Baza wydanych certyfikatów
│   ├── serial                      # Numer seryjny
│   └── openssl.cnf                 # Konfiguracja OpenSSL
│
├── intermediate-ca/
│   ├── certs/
│   │   ├── intermediateCA.crt      # Certyfikat Intermediate CA
│   │   └── ca-chain.crt            # Łańcuch: Intermediate + Root
│   ├── private/
│   │   └── intermediateCA.key      # Klucz Intermediate CA (TAJNY!)
│   ├── csr/
│   │   └── intermediateCA.csr      # CSR użyty do podpisania
│   └── openssl.cnf
│
├── server/
│   ├── server.key                  # Klucz prywatny serwera
│   ├── server.csr                  # Certificate Signing Request
│   ├── server.crt                  # Certyfikat serwera
│   └── server-full-chain.crt       # Server + Intermediate + Root
│
├── clients/
│   ├── service-a/
│   │   ├── client.key              # Klucz prywatny klienta
│   │   ├── client.csr              # CSR klienta
│   │   ├── client.crt              # Certyfikat klienta
│   │   └── CN.txt                  # Oryginalny CN (do identyfikacji)
│   ├── service-b/
│   │   ├── client.key
│   │   ├── client.crt
│   │   └── CN.txt
│   └── admin/
│       ├── client.key
│       ├── client.crt
│       └── CN.txt
│
├── java-keystores/
│   ├── server-keystore.p12         # Keystore serwera (PKCS12)
│   ├── truststore.p12              # Truststore (wspólny dla wszystkich)
│   ├── client-service-a-keystore.p12
│   ├── client-service-b-keystore.p12
│   └── client-admin-keystore.p12
│
└── kubernetes/
    └── tls-secrets.yaml            # Manifesty K8s Secret
```

### Położenie kluczowych plików

| Plik | Ścieżka | Opis |
|------|---------|------|
| Root CA cert | `certs/root-ca/certs/rootCA.crt` | Certyfikat głównego CA |
| CA chain | `certs/intermediate-ca/certs/ca-chain.crt` | Łańcuch do weryfikacji |
| Server cert | `certs/server/server.crt` | Certyfikat serwera |
| Server keystore | `certs/java-keystores/server-keystore.p12` | Dla aplikacji Java |
| Truststore | `certs/java-keystores/truststore.p12` | Wspólny dla wszystkich |
| Client X keystore | `certs/java-keystores/client-X-keystore.p12` | Keystore klienta X |
| K8s secrets | `certs/kubernetes/tls-secrets.yaml` | Manifesty Kubernetes |

---

## Komendy Makefile

### Główne cele

| Komenda | Opis |
|---------|------|
| `make all` | Pełna regeneracja (CA + server + klienci) |
| `make ca` | Tylko Root CA + Intermediate CA |
| `make server` | Tylko certyfikat serwera |
| `make client CLIENT_CN=nazwa` | Dodaj nowego klienta |
| `make clients` | Wygeneruj domyślnych klientów |
| `make certs` | Server + domyślni klienci |
| `make keystores` | Wygeneruj Java Keystores |
| `make k8s` | Wygeneruj manifesty Kubernetes |

### Zarządzanie klientami

| Komenda | Opis |
|---------|------|
| `make client CLIENT_CN=nazwa` | Dodaj klienta |
| `make list` | Lista wszystkich klientów |
| `make show-client CLIENT_CN=nazwa` | Szczegóły klienta |
| `make clean-client CLIENT_CN=nazwa` | Usuń konkretnego klienta |
| `make clean-clients` | Usuń wszystkich klientów |

### Wymuszanie regeneracji

| Komenda | Opis |
|---------|------|
| `make force-all` | Usuń wszystko i wygeneruj od nowa |
| `make force-certs` | Regeneruj certyfikaty (zachowaj CA) |
| `make force-server` | Regeneruj tylko serwer |

### Czyszczenie

| Komenda | Opis |
|---------|------|
| `make clean` | Usuń wszystkie certyfikaty |
| `make clean-certs` | Usuń certyfikaty końcowe (zachowaj CA) |
| `make clean-server` | Usuń tylko serwer |
| `make clean-clients` | Usuń wszystkich klientów |

### Weryfikacja i diagnostyka

| Komenda | Opis |
|---------|------|
| `make verify` | Zweryfikuj łańcuchy certyfikatów |
| `make list` | Lista klientów z datami wygaśnięcia |
| `make check-expiry` | Daty wygaśnięcia wszystkich certyfikatów |
| `make show-server` | Szczegóły certyfikatu serwera |
| `make info` | Status konfiguracji |
| `make shell` | Interaktywna powłoka OpenSSL |
| `make test-mtls` | Test połączenia mTLS |

---

## Zarządzanie klientami

### Dodawanie klientów

```bash
# Metoda 1: Parametr CLIENT_CN
make client CLIENT_CN="service-a@mycompany.com"
make client CLIENT_CN="service-b"
make client CLIENT_CN="admin"

# Metoda 2: Zmienna środowiskowa
CLIENT_CN="monitoring-agent" make client

# Metoda 3: Wielu klientów na raz
DEFAULT_CLIENTS="svc-a,svc-b,svc-c,admin" make clients
```

### Konwencja nazewnictwa

CN klienta może zawierać dowolne znaki, ale nazwa katalogu jest sanityzowana:

| CN (oryginalny) | Katalog | Keystore |
|-----------------|---------|----------|
| `service-a@mycompany.com` | `clients/service-a_mycompany.com/` | `client-service-a_mycompany.com-keystore.p12` |
| `Service-B` | `clients/service-b/` | `client-service-b-keystore.p12` |
| `admin` | `clients/admin/` | `client-admin-keystore.p12` |

Oryginalny CN jest zachowany w pliku `CN.txt` w katalogu klienta.

### Listowanie klientów

```bash
make list
```

Przykładowy wynik:
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

  ● admin
    Katalog:  clients/admin/
    Keystore: java-keystores/client-admin-keystore.p12
    Wygasa:   Dec 28 12:00:00 2026 GMT

[INFO] Łącznie klientów: 3
```

### Usuwanie klientów

```bash
# Usuń konkretnego klienta
make clean-client CLIENT_CN="service-a@mycompany.com"

# Usuń wszystkich klientów (zachowaj CA i server)
make clean-clients
```

### Regeneracja certyfikatu klienta

```bash
# Usuń stary certyfikat
make clean-client CLIENT_CN="service-a"

# Wygeneruj nowy z tym samym CN
make client CLIENT_CN="service-a"
```

---

## Zmienne konfiguracyjne

### Zmienne środowiskowe

| Zmienna | Domyślnie | Opis |
|---------|-----------|------|
| `EXPORT_DIR` | `./certs` | Katalog wyjściowy |
| `DOCKER_IMAGE` | `alpine/openssl` | Obraz Docker z OpenSSL |
| `DEFAULT_CLIENTS` | `default-client` | Lista klientów (przecinek) |
| `CLIENT_CN` | (puste) | CN dla nowego klienta |

### Dane organizacji

| Zmienna | Domyślnie | Opis |
|---------|-----------|------|
| `COUNTRY` | `PL` | Kod kraju (2 litery) |
| `STATE` | `Mazowieckie` | Województwo/stan |
| `LOCALITY` | `Warszawa` | Miasto |
| `ORGANIZATION` | `MyCompany` | Nazwa organizacji |
| `ORG_UNIT` | `IT Department` | Jednostka organizacyjna |

### Certyfikat serwera

| Zmienna | Domyślnie | Opis |
|---------|-----------|------|
| `SERVER_CN` | `localhost` | Common Name serwera |
| `SERVER_SANS` | (patrz niżej) | Subject Alternative Names |

Domyślne SAN:
```
DNS:localhost,DNS:*.localhost,DNS:*.default.svc.cluster.local,
DNS:*.svc.cluster.local,IP:127.0.0.1,IP:10.0.0.1
```

### Ważność certyfikatów

| Zmienna | Domyślnie | Opis |
|---------|-----------|------|
| `ROOT_CA_DAYS` | `7300` | ~20 lat |
| `INTERMEDIATE_CA_DAYS` | `3650` | ~10 lat |
| `SERVER_CERT_DAYS` | `365` | 1 rok |
| `CLIENT_CERT_DAYS` | `365` | 1 rok |

### Hasła

| Zmienna | Domyślnie | Opis |
|---------|-----------|------|
| `ROOT_CA_PASSWORD` | `rootca-secret` | Hasło klucza Root CA |
| `INTERMEDIATE_CA_PASSWORD` | `intermediate-secret` | Hasło klucza Intermediate CA |
| `SERVER_KEY_PASSWORD` | `server-secret` | Hasło klucza serwera |
| `CLIENT_KEY_PASSWORD` | `client-secret` | Hasło klucza klienta |
| `KEYSTORE_PASSWORD` | `changeit` | Hasło keystores PKCS12 |

### Tryby pracy

| Zmienna | Domyślnie | Opis |
|---------|-----------|------|
| `FORCE_REGENERATE_CA` | `false` | Wymuś regenerację CA |
| `FORCE_REGENERATE_CERTS` | `false` | Wymuś regenerację certyfikatów |

### Przykłady użycia zmiennych

```bash
# Zmiana organizacji
ORGANIZATION="ACME Corp" COUNTRY="US" make all

# Własny katalog wyjściowy
EXPORT_DIR="./prod-certs" make all

# Dłuższa ważność certyfikatów
SERVER_CERT_DAYS=730 CLIENT_CERT_DAYS=730 make certs

# Wielu klientów z niestandardową konfiguracją
DEFAULT_CLIENTS="api,web,mobile" \
  ORGANIZATION="My Startup" \
  KEYSTORE_PASSWORD="super-secret" \
  make all
```

---

## Scenariusze użycia

### Scenariusz 1: Środowisko developerskie

```bash
# Prosty setup - jeden klient
make ca
make server
make client CLIENT_CN="dev-client"

# Kopiuj keystores do projektu
cp certs/java-keystores/*.p12 src/main/resources/
```

### Scenariusz 2: Mikrousługi z mTLS

```bash
# 1. Wygeneruj CA i serwer
make ca
make server

# 2. Dodaj klienta dla każdej usługi
make client CLIENT_CN="user-service"
make client CLIENT_CN="order-service"
make client CLIENT_CN="payment-service"
make client CLIENT_CN="notification-service"

# 3. Sprawdź
make list

# 4. Wdróż na Kubernetes
kubectl apply -f certs/kubernetes/tls-secrets.yaml
```

### Scenariusz 3: CI/CD Pipeline

```bash
# Pipeline zawsze generuje od zera dla determinizmu
make clean
DEFAULT_CLIENTS="service-a,service-b,service-c" make all
make verify

# Artefakty do deploymentu
cp certs/kubernetes/tls-secrets.yaml deployment/
```

### Scenariusz 4: Rotacja certyfikatu jednego klienta

```bash
# Usuń stary certyfikat
make clean-client CLIENT_CN="payment-service"

# Wygeneruj nowy
make client CLIENT_CN="payment-service"

# Zaktualizuj Secret w K8s
kubectl apply -f certs/kubernetes/tls-secrets.yaml

# Restart poda
kubectl rollout restart deployment/payment-service
```

### Scenariusz 5: Dodanie nowego klienta do istniejącej infrastruktury

```bash
# CA i server już istnieją - dodaj tylko nowego klienta
make client CLIENT_CN="new-service"

# Keystores i K8s manifesty są automatycznie zaktualizowane
kubectl apply -f certs/kubernetes/tls-secrets.yaml
```

---

## Integracja z frameworkami Java

### Spring Boot 3+ / Spring Framework 7

**application.yml:**
```yaml
server:
  port: 8443
  ssl:
    enabled: true
    key-store: classpath:server-keystore.p12
    key-store-password: ${SSL_KEYSTORE_PASSWORD:changeit}
    key-store-type: PKCS12
    client-auth: need  # mTLS required
    trust-store: classpath:truststore.p12
    trust-store-password: ${SSL_TRUSTSTORE_PASSWORD:changeit}
    trust-store-type: PKCS12
```

**Klient REST z mTLS:**
```yaml
mtls:
  client:
    keystore:
      path: classpath:client-service-a-keystore.p12
      password: ${SSL_KEYSTORE_PASSWORD:changeit}
    truststore:
      path: classpath:truststore.p12
      password: ${SSL_TRUSTSTORE_PASSWORD:changeit}
```

### Quarkus 3+

**application.properties:**
```properties
# Server
quarkus.http.ssl-port=8443
quarkus.http.ssl.certificate.key-store-file=server-keystore.p12
quarkus.http.ssl.certificate.key-store-password=${SSL_KEYSTORE_PASSWORD:changeit}
quarkus.http.ssl.certificate.trust-store-file=truststore.p12
quarkus.http.ssl.certificate.trust-store-password=${SSL_TRUSTSTORE_PASSWORD:changeit}
quarkus.http.ssl.client-auth=required

# REST Client
quarkus.rest-client."ServiceAClient".key-store=client-service-a-keystore.p12
quarkus.rest-client."ServiceAClient".key-store-password=${SSL_KEYSTORE_PASSWORD}
quarkus.rest-client."ServiceAClient".trust-store=truststore.p12
```

### Micronaut 4+

**application.yml:**
```yaml
micronaut:
  server:
    ssl:
      enabled: true
      key-store:
        path: classpath:server-keystore.p12
        password: ${SSL_KEYSTORE_PASSWORD:changeit}
        type: PKCS12
      trust-store:
        path: classpath:truststore.p12
        password: ${SSL_TRUSTSTORE_PASSWORD:changeit}
      client-authentication: need
```

---

## Kubernetes

### Automatycznie generowane Secrets

Generator tworzy plik `certs/kubernetes/tls-secrets.yaml` zawierający:

1. **ConfigMap `ca-certificates`** — publiczny łańcuch CA
2. **Secret `tls-server`** — certyfikat i klucz serwera
3. **Secret `java-server-keystore`** — keystores serwera
4. **Secret `mtls-client-{nazwa}`** — osobny Secret dla każdego klienta

### Wdrożenie

```bash
# Zastosuj wszystkie secrety
kubectl apply -f certs/kubernetes/tls-secrets.yaml

# Sprawdź
kubectl get secrets | grep -E "(tls-|mtls-)"
```

### Użycie w Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
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
              readOnly: true
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

---

## Weryfikacja i diagnostyka

### Weryfikacja łańcuchów certyfikatów

```bash
make verify
```

### Sprawdzenie dat wygaśnięcia

```bash
make check-expiry
```

### Szczegóły certyfikatu

```bash
# Serwer
make show-server

# Klient
make show-client CLIENT_CN="service-a"
```

### Interaktywna powłoka OpenSSL

```bash
make shell

# W powłoce:
openssl x509 -noout -text -in /export/server/server.crt
```

### Test połączenia mTLS

```bash
# Z domyślnym klientem
make test-mtls

# Z konkretnym klientem
make test-mtls CLIENT_CN="service-a"
```

### Ręczny test z curl

```bash
curl --cert certs/clients/service-a/client.crt \
     --key certs/clients/service-a/client.key \
     --cacert certs/intermediate-ca/certs/ca-chain.crt \
     https://localhost:8443/api/test
```

---

## Rozwiązywanie problemów

### Problem: "Docker nie jest uruchomiony"

```bash
# Sprawdź status Docker
docker info

# Uruchom Docker (Linux)
sudo systemctl start docker
```

### Problem: "Certyfikat już istnieje"

```bash
# Wymuś regenerację
FORCE_REGENERATE_CERTS=true make client CLIENT_CN="service-a"

# Lub usuń i wygeneruj ponownie
make clean-client CLIENT_CN="service-a"
make client CLIENT_CN="service-a"
```

### Problem: "CA nie istnieje"

```bash
# Najpierw wygeneruj CA
make ca

# Potem certyfikaty
make server
make client CLIENT_CN="service-a"
```

### Problem: "Handshake failure" przy połączeniu mTLS

1. Sprawdź czy truststore zawiera właściwy CA:
   ```bash
   make check-keystore
   ```

2. Sprawdź czy certyfikat klienta jest podpisany przez właściwe CA:
   ```bash
   make verify
   ```

3. Sprawdź daty wygaśnięcia:
   ```bash
   make check-expiry
   ```

---

## Licencja

MIT License — używaj dowolnie w projektach komercyjnych i open-source.
