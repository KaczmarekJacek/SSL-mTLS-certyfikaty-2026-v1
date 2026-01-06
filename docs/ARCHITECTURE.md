# Architektura PKI - Dokumentacja techniczna

## Hierarchia certyfikatów

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ROOT CA                                         │
│                                                                              │
│  Subject:    CN=Root CA, O=MyCompany, C=PL                                  │
│  Issuer:     Self-signed                                                     │
│  Validity:   20 lat (7300 dni)                                               │
│  Key Usage:  Certificate Sign, CRL Sign                                      │
│  Basic:      CA:TRUE                                                         │
│                                                                              │
│  🔐 Klucz chroniony hasłem (AES-256)                                         │
│  📁 Lokalizacja: certs/root-ca/private/rootCA.key                           │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  │ podpisuje
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          INTERMEDIATE CA                                     │
│                                                                              │
│  Subject:    CN=Intermediate CA, O=MyCompany, C=PL                          │
│  Issuer:     Root CA                                                         │
│  Validity:   10 lat (3650 dni)                                               │
│  Key Usage:  Certificate Sign, CRL Sign                                      │
│  Basic:      CA:TRUE, pathlen:0                                              │
│                                                                              │
│  🔐 Klucz chroniony hasłem (AES-256)                                         │
│  📁 Lokalizacja: certs/intermediate-ca/private/intermediateCA.key           │
│                                                                              │
│  ⚡ pathlen:0 = może podpisywać tylko certyfikaty końcowe (nie inne CA)     │
└──────────────────┬──────────────────────────────────┬───────────────────────┘
                   │                                  │
                   │ podpisuje                        │ podpisuje
                   ▼                                  ▼
┌─────────────────────────────────┐  ┌─────────────────────────────────────────┐
│       SERVER CERTIFICATE         │  │         CLIENT CERTIFICATE               │
│                                  │  │                                          │
│  Subject:    CN=localhost        │  │  Subject:    CN=client@mycompany.com     │
│  Issuer:     Intermediate CA     │  │  Issuer:     Intermediate CA             │
│  Validity:   1 rok (365 dni)     │  │  Validity:   1 rok (365 dni)             │
│  Key Usage:  Digital Signature,  │  │  Key Usage:  Digital Signature,          │
│              Key Encipherment    │  │              Key Encipherment,           │
│  Ext Usage:  Server Auth         │  │              Non Repudiation             │
│  SAN:        DNS:localhost,      │  │  Ext Usage:  Client Auth, Email          │
│              DNS:*.svc.cluster,  │  │                                          │
│              IP:127.0.0.1        │  │                                          │
│                                  │  │                                          │
│  📁 certs/server/server.key     │  │  📁 certs/client/client.key              │
│  📁 certs/server/server.crt     │  │  📁 certs/client/client.crt              │
└─────────────────────────────────┘  └─────────────────────────────────────────┘
```

## Struktura plików

```
certs/
├── root-ca/
│   ├── certs/
│   │   └── rootCA.crt           # Certyfikat Root CA (publiczny)
│   ├── private/
│   │   └── rootCA.key           # Klucz prywatny Root CA (poufny!)
│   ├── crl/                     # Certificate Revocation Lists
│   ├── newcerts/                # Wydane certyfikaty (backup)
│   ├── index.txt                # Baza danych wydanych certyfikatów
│   ├── serial                   # Numer seryjny następnego certyfikatu
│   └── openssl.cnf              # Konfiguracja OpenSSL dla Root CA
│
├── intermediate-ca/
│   ├── certs/
│   │   ├── intermediateCA.crt   # Certyfikat Intermediate CA
│   │   └── ca-chain.crt         # Łańcuch: Intermediate + Root
│   ├── private/
│   │   └── intermediateCA.key   # Klucz prywatny Intermediate CA
│   ├── csr/
│   │   └── intermediateCA.csr   # CSR użyty do podpisania
│   ├── crl/
│   ├── newcerts/
│   ├── index.txt
│   ├── serial
│   ├── crlnumber
│   └── openssl.cnf              # Konfiguracja dla Intermediate CA
│
├── server/
│   ├── server.key               # Klucz prywatny serwera
│   ├── server.csr               # Certificate Signing Request
│   ├── server.crt               # Certyfikat serwera
│   └── server-full-chain.crt    # Pełny łańcuch: Server + Intermediate + Root
│
├── client/
│   ├── client.key               # Klucz prywatny klienta
│   ├── client.csr
│   └── client.crt               # Certyfikat klienta
│
├── java-keystores/
│   ├── server-keystore.p12      # PKCS12: server.key + server-full-chain.crt
│   ├── client-keystore.p12      # PKCS12: client.key + client.crt + ca-chain
│   └── truststore.p12           # PKCS12: ca-chain.crt (tylko certyfikaty CA)
│
└── kubernetes/
    └── tls-secrets.yaml         # Manifesty K8s Secret
```

## Przepływ kryptograficzny

### 1. Generowanie Root CA

```
┌─────────────────────────────────────────────────────────────────┐
│                    GENEROWANIE ROOT CA                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Generowanie klucza RSA-4096:                                │
│     openssl genrsa -aes256 -out rootCA.key 4096                 │
│                     ↓                                            │
│  2. Self-signed certificate:                                     │
│     openssl req -x509 -new -key rootCA.key                      │
│                 -sha384 -days 7300                               │
│                 -out rootCA.crt                                  │
│                                                                  │
│  Wynik: rootCA.key (zaszyfrowany) + rootCA.crt                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2. Podpisywanie Intermediate CA

```
┌─────────────────────────────────────────────────────────────────┐
│               PODPISYWANIE INTERMEDIATE CA                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Generowanie klucza Intermediate:                             │
│     openssl genrsa -aes256 -out intermediateCA.key 4096         │
│                     ↓                                            │
│  2. Utworzenie CSR:                                              │
│     openssl req -new -key intermediateCA.key                    │
│                 -out intermediateCA.csr                          │
│                     ↓                                            │
│  3. Root CA podpisuje CSR:                                       │
│     openssl ca -config root-ca/openssl.cnf                      │
│                -extensions v3_intermediate_ca                    │
│                -in intermediateCA.csr                            │
│                -out intermediateCA.crt                           │
│                                                                  │
│  Wynik: intermediateCA.key + intermediateCA.crt                 │
│         (podpisany przez Root CA)                                │
└─────────────────────────────────────────────────────────────────┘
```

### 3. Wydawanie certyfikatów końcowych

```
┌─────────────────────────────────────────────────────────────────┐
│              WYDAWANIE CERTYFIKATU SERWERA                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Generowanie klucza serwera:                                  │
│     openssl genrsa -aes256 -out server.key 4096                 │
│                     ↓                                            │
│  2. Utworzenie CSR z SAN:                                        │
│     openssl req -new -key server.key                            │
│                 -out server.csr                                  │
│                     ↓                                            │
│  3. Intermediate CA podpisuje CSR:                               │
│     openssl ca -config intermediate-ca/openssl.cnf              │
│                -extensions server_cert                           │
│                -in server.csr                                    │
│                -out server.crt                                   │
│                     ↓                                            │
│  4. Utworzenie pełnego łańcucha:                                 │
│     cat server.crt intermediateCA.crt rootCA.crt                │
│         > server-full-chain.crt                                  │
│                                                                  │
│  Wynik: server.key + server.crt + server-full-chain.crt         │
└─────────────────────────────────────────────────────────────────┘
```

## Weryfikacja łańcucha zaufania

```
┌─────────────────────────────────────────────────────────────────┐
│                WERYFIKACJA CERTYFIKATU                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Klient otrzymuje: server.crt                                    │
│                                                                  │
│  1. Sprawdź podpis server.crt:                                   │
│     Issuer = "Intermediate CA"                                   │
│     → Znajdź certyfikat Intermediate CA                          │
│                                                                  │
│  2. Sprawdź podpis intermediateCA.crt:                           │
│     Issuer = "Root CA"                                           │
│     → Znajdź certyfikat Root CA                                  │
│                                                                  │
│  3. Sprawdź rootCA.crt:                                          │
│     Issuer = Subject (self-signed)                               │
│     → Root CA w truststore? ✓                                    │
│                                                                  │
│  Łańcuch zweryfikowany: server → intermediate → root             │
└─────────────────────────────────────────────────────────────────┘
```

## TLS Handshake z mTLS

```
┌──────────┐                                          ┌──────────┐
│  CLIENT  │                                          │  SERVER  │
└────┬─────┘                                          └────┬─────┘
     │                                                     │
     │  1. ClientHello                                     │
     │     - Supported TLS versions                        │
     │     - Cipher suites                                 │
     │     - Random bytes                                  │
     │ ─────────────────────────────────────────────────► │
     │                                                     │
     │  2. ServerHello                                     │
     │     - Selected TLS version (1.3)                    │
     │     - Selected cipher suite                         │
     │     - Random bytes                                  │
     │ ◄───────────────────────────────────────────────── │
     │                                                     │
     │  3. Server Certificate                              │
     │     - server.crt                                    │
     │     - intermediateCA.crt                            │
     │ ◄───────────────────────────────────────────────── │
     │                                                     │
     │  4. CertificateRequest (mTLS)                       │
     │     - "Wyślij swój certyfikat"                      │
     │ ◄───────────────────────────────────────────────── │
     │                                                     │
     │  5. Client Certificate (mTLS)                       │
     │     - client.crt                                    │
     │ ─────────────────────────────────────────────────► │
     │                                                     │
     │  6. CertificateVerify (mTLS)                        │
     │     - Podpis kluczem prywatnym klienta             │
     │ ─────────────────────────────────────────────────► │
     │                                                     │
     │  7. Key Exchange                                    │
     │     - (ECDHE/DHE)                                   │
     │ ◄──────────────────────────────────────────────── │
     │                                                     │
     │  8. Finished (encrypted)                            │
     │ ◄──────────────────────────────────────────────── │
     │                                                     │
     │  ═══════════════════════════════════════════════   │
     │         ENCRYPTED APPLICATION DATA                  │
     │  ═══════════════════════════════════════════════   │
```

## Konwersja do PKCS12

```
┌─────────────────────────────────────────────────────────────────┐
│                    PKCS12 KEYSTORE                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  server-keystore.p12:                                            │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Entry: "server"                                         │    │
│  │  ├── Private Key: server.key                             │    │
│  │  └── Certificate Chain:                                  │    │
│  │      ├── server.crt                                      │    │
│  │      ├── intermediateCA.crt                              │    │
│  │      └── rootCA.crt                                      │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  truststore.p12:                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Entry: "ca-chain"                                       │    │
│  │  └── Trusted Certificates:                               │    │
│  │      ├── intermediateCA.crt                              │    │
│  │      └── rootCA.crt                                      │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  Komenda:                                                        │
│  openssl pkcs12 -export                                          │
│          -in server-full-chain.crt                               │
│          -inkey server.key                                       │
│          -name "server"                                          │
│          -out server-keystore.p12                                │
└─────────────────────────────────────────────────────────────────┘
```

## Parametry kryptograficzne

| Element | Wartość | Uzasadnienie |
|---------|---------|--------------|
| Algorytm klucza | RSA | Szeroka kompatybilność |
| Długość klucza | 4096 bit | NIST zaleca min. 2048; 4096 dla długowieczności |
| Hash | SHA-384 | Silniejszy niż SHA-256, bez overhead SHA-512 |
| Szyfrowanie klucza | AES-256 | Standard branżowy |
| TLS | 1.3 (preferowany), 1.2 (fallback) | 1.3 usuwa słabe cipher suites |

## Rozszerzenia X.509

### Root CA

```
X509v3 Basic Constraints: critical
    CA:TRUE
X509v3 Key Usage: critical
    Certificate Sign, CRL Sign
X509v3 Subject Key Identifier:
    <hash of public key>
```

### Intermediate CA

```
X509v3 Basic Constraints: critical
    CA:TRUE, pathlen:0
X509v3 Key Usage: critical
    Certificate Sign, CRL Sign
X509v3 Authority Key Identifier:
    keyid:<Root CA SKI>
X509v3 Subject Key Identifier:
    <hash of public key>
```

### Server Certificate

```
X509v3 Basic Constraints:
    CA:FALSE
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment
X509v3 Extended Key Usage:
    TLS Web Server Authentication
X509v3 Subject Alternative Name:
    DNS:localhost, DNS:*.svc.cluster.local, IP:127.0.0.1
X509v3 Authority Key Identifier:
    keyid:<Intermediate CA SKI>
```

### Client Certificate

```
X509v3 Basic Constraints:
    CA:FALSE
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment, Non Repudiation
X509v3 Extended Key Usage:
    TLS Web Client Authentication, E-mail Protection
X509v3 Authority Key Identifier:
    keyid:<Intermediate CA SKI>
```
