#!/bin/bash
#===============================================================================
# PKI Certificate Generator using OpenSSL in Docker
# 
# Idempotentny skrypt: Root CA i Intermediate CA są generowane tylko raz,
# certyfikaty server/client mogą być regenerowane wielokrotnie.
# Obsługuje wielu klientów dla mTLS.
#
# Wersja: 2.1.0
# Kompatybilność: Java 25, Spring 7, Quarkus 3+, Micronaut 4+, Kubernetes
#===============================================================================

set -euo pipefail

# Kolory dla lepszej czytelności
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# KONFIGURACJA - dostosuj do swoich potrzeb
#-------------------------------------------------------------------------------
EXPORT_DIR="${EXPORT_DIR:-./certs}"
DOCKER_IMAGE="${DOCKER_IMAGE:-alpine/openssl}"

# Dane organizacji
COUNTRY="${COUNTRY:-PL}"
STATE="${STATE:-Mazowieckie}"
LOCALITY="${LOCALITY:-Warszawa}"
ORGANIZATION="${ORGANIZATION:-MyCompany}"
ORG_UNIT="${ORG_UNIT:-IT Department}"

# Nazwy hostów dla certyfikatu serwera (Kubernetes-ready)
SERVER_CN="${SERVER_CN:-localhost}"

# Subject Alternative Names (SANs) - można nadpisać lub rozszerzyć
# Format: "DNS:nazwa1,DNS:nazwa2,IP:1.2.3.4,IP:5.6.7.8"
DEFAULT_SERVER_SANS="DNS:localhost,DNS:*.localhost,IP:127.0.0.1"
SERVER_SANS="${SERVER_SANS:-${DEFAULT_SERVER_SANS}}"

# Dodatkowe SANy (dodawane do SERVER_SANS zamiast zastępowania)
ADD_SERVER_SANS="${ADD_SERVER_SANS:-}"

# Domyślni klienci (można nadpisać przez DEFAULT_CLIENTS)
# Format: "cn1,cn2,cn3" lub pojedyncza wartość
DEFAULT_CLIENTS="${DEFAULT_CLIENTS:-default-client}"

# Ważność certyfikatów (w dniach)
ROOT_CA_DAYS="${ROOT_CA_DAYS:-7300}"        # ~20 lat
INTERMEDIATE_CA_DAYS="${INTERMEDIATE_CA_DAYS:-3650}" # ~10 lat
SERVER_CERT_DAYS="${SERVER_CERT_DAYS:-365}"  # 1 rok
CLIENT_CERT_DAYS="${CLIENT_CERT_DAYS:-365}"  # 1 rok

# Długość klucza RSA
KEY_SIZE="${KEY_SIZE:-4096}"

# Hasła (w produkcji użyj bezpiecznych haseł lub HSM!)
ROOT_CA_PASSWORD="${ROOT_CA_PASSWORD:-rootca-secret}"
INTERMEDIATE_CA_PASSWORD="${INTERMEDIATE_CA_PASSWORD:-intermediate-secret}"
SERVER_KEY_PASSWORD="${SERVER_KEY_PASSWORD:-server-secret}"
CLIENT_KEY_PASSWORD="${CLIENT_KEY_PASSWORD:-client-secret}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-changeit}"

# Tryby pracy
FORCE_REGENERATE_CA="${FORCE_REGENERATE_CA:-false}"
FORCE_REGENERATE_CERTS="${FORCE_REGENERATE_CERTS:-false}"
VERBOSE="${VERBOSE:-false}"

#-------------------------------------------------------------------------------
# Funkcje pomocnicze
#-------------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "\n${CYAN}=== $1 ===${NC}"
}

run_openssl() {
    # Uruchamiamy Docker z UID/GID bieżącego użytkownika
    # aby pliki były tworzone z właściwymi uprawnieniami (nie root:root)
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -v "$(pwd)/${EXPORT_DIR}:/export" \
        "${DOCKER_IMAGE}" "$@"
}

check_docker() {
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker nie jest uruchomiony lub niedostępny"
        exit 1
    fi
}

file_exists() {
    [[ -f "$1" ]]
}

# Konwertuje CN na bezpieczną nazwę katalogu/pliku
sanitize_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9._-]/_/g' | tr '[:upper:]' '[:lower:]'
}

#-------------------------------------------------------------------------------
# Generowanie sekcji alt_names dla OpenSSL
#-------------------------------------------------------------------------------
generate_san_config() {
    local sans="$1"
    local dns_count=0
    local ip_count=0
    
    # Jeśli ADD_SERVER_SANS jest ustawione, dołącz do głównych SANs
    if [[ -n "${ADD_SERVER_SANS}" ]]; then
        sans="${sans},${ADD_SERVER_SANS}"
    fi
    
    echo "[ alt_names ]"
    
    # Parsuj listę SANs (rozdzielonych przecinkami)
    IFS=',' read -ra SAN_ARRAY <<< "$sans"
    
    for san in "${SAN_ARRAY[@]}"; do
        # Trim whitespace
        san=$(echo "$san" | xargs)
        
        if [[ "$san" == DNS:* ]]; then
            ((dns_count++))
            local value="${san#DNS:}"
            echo "DNS.${dns_count} = ${value}"
        elif [[ "$san" == IP:* ]]; then
            ((ip_count++))
            local value="${san#IP:}"
            echo "IP.${ip_count} = ${value}"
        elif [[ -n "$san" ]]; then
            # Jeśli nie ma prefiksu, traktuj jako DNS
            ((dns_count++))
            echo "DNS.${dns_count} = ${san}"
        fi
    done
}

# Wyświetl skonfigurowane SANs
show_configured_sans() {
    local sans="$SERVER_SANS"
    if [[ -n "${ADD_SERVER_SANS}" ]]; then
        sans="${sans},${ADD_SERVER_SANS}"
    fi
    
    log_info "Skonfigurowane SANs dla serwera:"
    IFS=',' read -ra SAN_ARRAY <<< "$sans"
    for san in "${SAN_ARRAY[@]}"; do
        san=$(echo "$san" | xargs)
        if [[ -n "$san" ]]; then
            echo "    - ${san}"
        fi
    done
}

#-------------------------------------------------------------------------------
# Sprawdzenie czy certyfikaty CA istnieją
#-------------------------------------------------------------------------------
check_root_ca_exists() {
    file_exists "${EXPORT_DIR}/root-ca/certs/rootCA.crt" && \
    file_exists "${EXPORT_DIR}/root-ca/private/rootCA.key"
}

check_intermediate_ca_exists() {
    file_exists "${EXPORT_DIR}/intermediate-ca/certs/intermediateCA.crt" && \
    file_exists "${EXPORT_DIR}/intermediate-ca/private/intermediateCA.key"
}

check_server_cert_exists() {
    file_exists "${EXPORT_DIR}/server/server.crt" && \
    file_exists "${EXPORT_DIR}/server/server.key"
}

check_client_cert_exists() {
    local client_name="$1"
    local safe_name=$(sanitize_name "$client_name")
    file_exists "${EXPORT_DIR}/clients/${safe_name}/client.crt" && \
    file_exists "${EXPORT_DIR}/clients/${safe_name}/client.key"
}

#-------------------------------------------------------------------------------
# Inicjalizacja struktury katalogów
#-------------------------------------------------------------------------------
init_directory_structure() {
    log_step "Inicjalizacja struktury katalogów"
    
    mkdir -p "${EXPORT_DIR}/root-ca"/{certs,crl,newcerts,private}
    mkdir -p "${EXPORT_DIR}/intermediate-ca"/{certs,crl,csr,newcerts,private}
    mkdir -p "${EXPORT_DIR}/server"
    mkdir -p "${EXPORT_DIR}/clients"
    mkdir -p "${EXPORT_DIR}/java-keystores"
    mkdir -p "${EXPORT_DIR}/kubernetes"
    
    # Pliki indeksowe (tylko jeśli nie istnieją)
    [[ -f "${EXPORT_DIR}/root-ca/index.txt" ]] || touch "${EXPORT_DIR}/root-ca/index.txt"
    [[ -f "${EXPORT_DIR}/intermediate-ca/index.txt" ]] || touch "${EXPORT_DIR}/intermediate-ca/index.txt"
    [[ -f "${EXPORT_DIR}/root-ca/serial" ]] || echo "1000" > "${EXPORT_DIR}/root-ca/serial"
    [[ -f "${EXPORT_DIR}/intermediate-ca/serial" ]] || echo "1000" > "${EXPORT_DIR}/intermediate-ca/serial"
    [[ -f "${EXPORT_DIR}/intermediate-ca/crlnumber" ]] || echo "1000" > "${EXPORT_DIR}/intermediate-ca/crlnumber"
    
    log_success "Struktura katalogów gotowa"
}

#-------------------------------------------------------------------------------
# Konfiguracja OpenSSL
#-------------------------------------------------------------------------------
create_openssl_config() {
    log_step "Tworzenie konfiguracji OpenSSL"
    
    # Konfiguracja Root CA
    cat > "${EXPORT_DIR}/root-ca/openssl.cnf" << EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /export/root-ca
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
private_key       = \$dir/private/rootCA.key
certificate       = \$dir/certs/rootCA.crt
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/rootCA.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha384
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 375
preserve          = no
policy            = policy_strict

[ policy_strict ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = ${KEY_SIZE}
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha384
x509_extensions     = v3_ca

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name
emailAddress                    = Email Address

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF

    # Konfiguracja Intermediate CA
    cat > "${EXPORT_DIR}/intermediate-ca/openssl.cnf" << EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /export/intermediate-ca
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
private_key       = \$dir/private/intermediateCA.key
certificate       = \$dir/certs/intermediateCA.crt
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/intermediateCA.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha384
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 375
preserve          = no
policy            = policy_loose

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = ${KEY_SIZE}
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha384

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name
emailAddress                    = Email Address

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ client_cert ]
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection

[ alt_names ]
# Generowane dynamicznie - patrz poniżej

[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF

    # Generuj dynamiczną sekcję alt_names
    local san_config=$(generate_san_config "$SERVER_SANS")
    
    # Zastąp placeholder rzeczywistą konfiguracją
    # Używamy sed do zastąpienia sekcji alt_names
    local temp_file="${EXPORT_DIR}/intermediate-ca/openssl_temp.cnf"
    sed '/^\[ alt_names \]/,/^\[/{/^\[ alt_names \]/!{/^\[/!d}}' \
        "${EXPORT_DIR}/intermediate-ca/openssl.cnf" > "$temp_file"
    
    # Wstaw nową sekcję alt_names przed [ crl_ext ]
    awk -v san="$san_config" '
        /^\[ crl_ext \]/ { print san; print "" }
        { print }
    ' "$temp_file" > "${EXPORT_DIR}/intermediate-ca/openssl.cnf"
    
    rm -f "$temp_file"

    log_success "Konfiguracja OpenSSL utworzona"
    show_configured_sans
}

#===============================================================================
# GENEROWANIE ROOT CA
#===============================================================================
generate_root_ca() {
    if check_root_ca_exists && [[ "${FORCE_REGENERATE_CA}" != "true" ]]; then
        log_warning "Root CA już istnieje - pomijam (użyj FORCE_REGENERATE_CA=true aby wymusić)"
        return 0
    fi
    
    log_step "Generowanie Root CA"
    
    # Generowanie klucza prywatnego Root CA
    log_info "Generowanie klucza prywatnego Root CA (${KEY_SIZE} bit)..."
    run_openssl genrsa -aes256 \
        -passout "pass:${ROOT_CA_PASSWORD}" \
        -out /export/root-ca/private/rootCA.key "${KEY_SIZE}"
    
    chmod 400 "${EXPORT_DIR}/root-ca/private/rootCA.key"
    
    # Generowanie certyfikatu Root CA (self-signed)
    log_info "Generowanie certyfikatu Root CA (self-signed)..."
    run_openssl req -config /export/root-ca/openssl.cnf \
        -key /export/root-ca/private/rootCA.key \
        -new -x509 -days "${ROOT_CA_DAYS}" -sha384 \
        -extensions v3_ca \
        -passin "pass:${ROOT_CA_PASSWORD}" \
        -out /export/root-ca/certs/rootCA.crt \
        -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCALITY}/O=${ORGANIZATION}/OU=${ORG_UNIT}/CN=Root CA"
    
    log_success "Root CA wygenerowany pomyślnie"
}

#===============================================================================
# GENEROWANIE INTERMEDIATE CA
#===============================================================================
generate_intermediate_ca() {
    if check_intermediate_ca_exists && [[ "${FORCE_REGENERATE_CA}" != "true" ]]; then
        log_warning "Intermediate CA już istnieje - pomijam (użyj FORCE_REGENERATE_CA=true aby wymusić)"
        return 0
    fi
    
    if ! check_root_ca_exists; then
        log_error "Root CA nie istnieje - najpierw wygeneruj Root CA"
        exit 1
    fi
    
    log_step "Generowanie Intermediate CA"
    
    # Generowanie klucza prywatnego Intermediate CA
    log_info "Generowanie klucza prywatnego Intermediate CA..."
    run_openssl genrsa -aes256 \
        -passout "pass:${INTERMEDIATE_CA_PASSWORD}" \
        -out /export/intermediate-ca/private/intermediateCA.key "${KEY_SIZE}"
    
    chmod 400 "${EXPORT_DIR}/intermediate-ca/private/intermediateCA.key"
    
    # Generowanie CSR dla Intermediate CA
    log_info "Generowanie CSR dla Intermediate CA..."
    run_openssl req -config /export/intermediate-ca/openssl.cnf \
        -new -sha384 \
        -key /export/intermediate-ca/private/intermediateCA.key \
        -passin "pass:${INTERMEDIATE_CA_PASSWORD}" \
        -out /export/intermediate-ca/csr/intermediateCA.csr \
        -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCALITY}/O=${ORGANIZATION}/OU=${ORG_UNIT}/CN=Intermediate CA"
    
    # Podpisanie CSR przez Root CA
    log_info "Podpisywanie Intermediate CA przez Root CA..."
    run_openssl ca -config /export/root-ca/openssl.cnf \
        -extensions v3_intermediate_ca \
        -days "${INTERMEDIATE_CA_DAYS}" -notext -md sha384 \
        -batch \
        -passin "pass:${ROOT_CA_PASSWORD}" \
        -in /export/intermediate-ca/csr/intermediateCA.csr \
        -out /export/intermediate-ca/certs/intermediateCA.crt
    
    # Utworzenie łańcucha certyfikatów
    log_info "Tworzenie łańcucha certyfikatów CA..."
    cat "${EXPORT_DIR}/intermediate-ca/certs/intermediateCA.crt" \
        "${EXPORT_DIR}/root-ca/certs/rootCA.crt" \
        > "${EXPORT_DIR}/intermediate-ca/certs/ca-chain.crt"
    
    log_success "Intermediate CA wygenerowany i podpisany pomyślnie"
}

#===============================================================================
# GENEROWANIE CERTYFIKATU SERWERA
#===============================================================================
generate_server_cert() {
    if check_server_cert_exists && [[ "${FORCE_REGENERATE_CERTS}" != "true" ]]; then
        log_warning "Certyfikat serwera już istnieje - pomijam (użyj FORCE_REGENERATE_CERTS=true aby wymusić)"
        return 0
    fi
    
    if ! check_intermediate_ca_exists; then
        log_error "Intermediate CA nie istnieje - najpierw wygeneruj CA"
        exit 1
    fi
    
    log_step "Generowanie certyfikatu serwera"
    
    # Generowanie klucza prywatnego serwera
    log_info "Generowanie klucza prywatnego serwera..."
    run_openssl genrsa -aes256 \
        -passout "pass:${SERVER_KEY_PASSWORD}" \
        -out /export/server/server.key "${KEY_SIZE}"
    
    # Generowanie CSR serwera
    log_info "Generowanie CSR serwera..."
    run_openssl req -config /export/intermediate-ca/openssl.cnf \
        -key /export/server/server.key \
        -passin "pass:${SERVER_KEY_PASSWORD}" \
        -new -sha384 \
        -out /export/server/server.csr \
        -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCALITY}/O=${ORGANIZATION}/OU=${ORG_UNIT}/CN=${SERVER_CN}"
    
    # Podpisanie certyfikatu serwera
    log_info "Podpisywanie certyfikatu serwera przez Intermediate CA..."
    run_openssl ca -config /export/intermediate-ca/openssl.cnf \
        -extensions server_cert \
        -days "${SERVER_CERT_DAYS}" -notext -md sha384 \
        -batch \
        -passin "pass:${INTERMEDIATE_CA_PASSWORD}" \
        -in /export/server/server.csr \
        -out /export/server/server.crt
    
    # Pełny łańcuch certyfikatów serwera
    cat "${EXPORT_DIR}/server/server.crt" \
        "${EXPORT_DIR}/intermediate-ca/certs/ca-chain.crt" \
        > "${EXPORT_DIR}/server/server-full-chain.crt"
    
    log_success "Certyfikat serwera wygenerowany pomyślnie"
}

#===============================================================================
# GENEROWANIE CERTYFIKATU KLIENTA (parametryczne)
#===============================================================================
generate_client_cert() {
    local client_cn="$1"
    local force="${2:-false}"
    local safe_name=$(sanitize_name "$client_cn")
    local client_dir="${EXPORT_DIR}/clients/${safe_name}"
    
    if check_client_cert_exists "$client_cn" && [[ "$force" != "true" ]] && [[ "${FORCE_REGENERATE_CERTS}" != "true" ]]; then
        log_warning "Certyfikat klienta '${client_cn}' już istnieje - pomijam"
        return 0
    fi
    
    if ! check_intermediate_ca_exists; then
        log_error "Intermediate CA nie istnieje - najpierw wygeneruj CA"
        exit 1
    fi
    
    log_step "Generowanie certyfikatu klienta: ${client_cn}"
    
    # Tworzenie katalogu klienta
    mkdir -p "$client_dir"
    
    # Generowanie klucza prywatnego klienta
    log_info "Generowanie klucza prywatnego klienta..."
    run_openssl genrsa -aes256 \
        -passout "pass:${CLIENT_KEY_PASSWORD}" \
        -out "/export/clients/${safe_name}/client.key" "${KEY_SIZE}"
    
    # Generowanie CSR klienta
    log_info "Generowanie CSR klienta..."
    run_openssl req -config /export/intermediate-ca/openssl.cnf \
        -key "/export/clients/${safe_name}/client.key" \
        -passin "pass:${CLIENT_KEY_PASSWORD}" \
        -new -sha384 \
        -out "/export/clients/${safe_name}/client.csr" \
        -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCALITY}/O=${ORGANIZATION}/OU=${ORG_UNIT}/CN=${client_cn}"
    
    # Podpisanie certyfikatu klienta
    log_info "Podpisywanie certyfikatu klienta przez Intermediate CA..."
    run_openssl ca -config /export/intermediate-ca/openssl.cnf \
        -extensions client_cert \
        -days "${CLIENT_CERT_DAYS}" -notext -md sha384 \
        -batch \
        -passin "pass:${INTERMEDIATE_CA_PASSWORD}" \
        -in "/export/clients/${safe_name}/client.csr" \
        -out "/export/clients/${safe_name}/client.crt"
    
    # Zapisz CN do pliku dla łatwiejszej identyfikacji
    echo "$client_cn" > "$client_dir/CN.txt"
    
    log_success "Certyfikat klienta '${client_cn}' wygenerowany pomyślnie"
}

#===============================================================================
# GENEROWANIE WIELU KLIENTÓW
#===============================================================================
generate_all_clients() {
    log_step "Generowanie certyfikatów klientów"
    
    # Parsowanie listy klientów (rozdzielonych przecinkami)
    IFS=',' read -ra CLIENTS <<< "$DEFAULT_CLIENTS"
    
    for client_cn in "${CLIENTS[@]}"; do
        # Trim whitespace
        client_cn=$(echo "$client_cn" | xargs)
        if [[ -n "$client_cn" ]]; then
            generate_client_cert "$client_cn"
        fi
    done
    
    log_success "Wszystkie certyfikaty klientów wygenerowane"
}

#===============================================================================
# GENEROWANIE JAVA KEYSTORES (PKCS12)
#===============================================================================
generate_java_keystores() {
    log_step "Generowanie Java Keystores (PKCS12)"
    
    # Server Keystore
    if [[ -f "${EXPORT_DIR}/server/server-full-chain.crt" ]]; then
        log_info "Tworzenie server-keystore.p12..."
        run_openssl pkcs12 -export \
            -in /export/server/server-full-chain.crt \
            -inkey /export/server/server.key \
            -passin "pass:${SERVER_KEY_PASSWORD}" \
            -name "server" \
            -out /export/java-keystores/server-keystore.p12 \
            -passout "pass:${KEYSTORE_PASSWORD}"
    fi
    
    # Truststore (zawiera CA chain)
    if [[ -f "${EXPORT_DIR}/intermediate-ca/certs/ca-chain.crt" ]]; then
        log_info "Tworzenie truststore.p12..."
        run_openssl pkcs12 -export \
            -nokeys \
            -in /export/intermediate-ca/certs/ca-chain.crt \
            -name "ca-chain" \
            -out /export/java-keystores/truststore.p12 \
            -passout "pass:${KEYSTORE_PASSWORD}"
    fi
    
    # Client Keystores - dla każdego klienta osobno
    log_info "Tworzenie keystores dla klientów..."
    
    if [[ -d "${EXPORT_DIR}/clients" ]]; then
        for client_dir in "${EXPORT_DIR}/clients"/*/; do
            if [[ -d "$client_dir" ]] && [[ -f "${client_dir}/client.crt" ]]; then
                local safe_name=$(basename "$client_dir")
                local client_cn="$safe_name"
                
                # Odczytaj oryginalny CN jeśli istnieje
                if [[ -f "${client_dir}/CN.txt" ]]; then
                    client_cn=$(cat "${client_dir}/CN.txt")
                fi
                
                log_info "Tworzenie client-${safe_name}-keystore.p12..."
                run_openssl pkcs12 -export \
                    -in "/export/clients/${safe_name}/client.crt" \
                    -inkey "/export/clients/${safe_name}/client.key" \
                    -passin "pass:${CLIENT_KEY_PASSWORD}" \
                    -certfile /export/intermediate-ca/certs/ca-chain.crt \
                    -name "${client_cn}" \
                    -out "/export/java-keystores/client-${safe_name}-keystore.p12" \
                    -passout "pass:${KEYSTORE_PASSWORD}"
            fi
        done
    fi
    
    log_success "Java Keystores utworzone pomyślnie"
}

#===============================================================================
# GENEROWANIE KUBERNETES SECRETS (YAML)
#===============================================================================
generate_kubernetes_manifests() {
    log_step "Generowanie manifestów Kubernetes"
    
    # Sprawdź czy pliki istnieją
    if [[ ! -f "${EXPORT_DIR}/intermediate-ca/certs/ca-chain.crt" ]]; then
        log_warning "Brak certyfikatów CA - pomiń generowanie K8s manifests"
        return 0
    fi
    
    # Base64 encode certyfikatów
    local CA_CHAIN_B64=$(base64 -w0 "${EXPORT_DIR}/intermediate-ca/certs/ca-chain.crt")
    local TRUSTSTORE_B64=$(base64 -w0 "${EXPORT_DIR}/java-keystores/truststore.p12" 2>/dev/null || echo "")
    
    # Główny plik z secrets
    cat > "${EXPORT_DIR}/kubernetes/tls-secrets.yaml" << EOF
# PKI Generator - Kubernetes Secrets
# Wygenerowano: $(date -Iseconds)
---
# CA Chain ConfigMap (publiczny)
apiVersion: v1
kind: ConfigMap
metadata:
  name: ca-certificates
  labels:
    app.kubernetes.io/component: security
    app.kubernetes.io/managed-by: pki-generator
data:
  ca-chain.crt: |
$(sed 's/^/    /' "${EXPORT_DIR}/intermediate-ca/certs/ca-chain.crt")
EOF

    # Server TLS Secret (jeśli istnieje)
    if [[ -f "${EXPORT_DIR}/server/server.crt" ]]; then
        local SERVER_CRT_B64=$(base64 -w0 "${EXPORT_DIR}/server/server.crt")
        local SERVER_KEY_B64=$(base64 -w0 "${EXPORT_DIR}/server/server.key")
        local SERVER_KEYSTORE_B64=$(base64 -w0 "${EXPORT_DIR}/java-keystores/server-keystore.p12" 2>/dev/null || echo "")
        
        cat >> "${EXPORT_DIR}/kubernetes/tls-secrets.yaml" << EOF
---
# TLS Server Certificate Secret
apiVersion: v1
kind: Secret
metadata:
  name: tls-server
  labels:
    app.kubernetes.io/component: security
    app.kubernetes.io/managed-by: pki-generator
type: kubernetes.io/tls
data:
  tls.crt: ${SERVER_CRT_B64}
  tls.key: ${SERVER_KEY_B64}
  ca.crt: ${CA_CHAIN_B64}
---
# Java Server Keystore Secret
apiVersion: v1
kind: Secret
metadata:
  name: java-server-keystore
  labels:
    app.kubernetes.io/component: security
    app.kubernetes.io/managed-by: pki-generator
type: Opaque
data:
  server-keystore.p12: ${SERVER_KEYSTORE_B64}
  truststore.p12: ${TRUSTSTORE_B64}
stringData:
  keystore-password: "${KEYSTORE_PASSWORD}"
EOF
    fi

    # Secrets dla każdego klienta
    if [[ -d "${EXPORT_DIR}/clients" ]]; then
        for client_dir in "${EXPORT_DIR}/clients"/*/; do
            if [[ -d "$client_dir" ]] && [[ -f "${client_dir}/client.crt" ]]; then
                local safe_name=$(basename "$client_dir")
                local client_cn="$safe_name"
                
                if [[ -f "${client_dir}/CN.txt" ]]; then
                    client_cn=$(cat "${client_dir}/CN.txt")
                fi
                
                local CLIENT_CRT_B64=$(base64 -w0 "${client_dir}/client.crt")
                local CLIENT_KEY_B64=$(base64 -w0 "${client_dir}/client.key")
                local CLIENT_KEYSTORE_B64=$(base64 -w0 "${EXPORT_DIR}/java-keystores/client-${safe_name}-keystore.p12" 2>/dev/null || echo "")
                
                cat >> "${EXPORT_DIR}/kubernetes/tls-secrets.yaml" << EOF
---
# Client mTLS Secret: ${client_cn}
apiVersion: v1
kind: Secret
metadata:
  name: mtls-client-${safe_name}
  labels:
    app.kubernetes.io/component: security
    app.kubernetes.io/managed-by: pki-generator
    pki.generator/client-cn: "${safe_name}"
  annotations:
    pki.generator/original-cn: "${client_cn}"
type: Opaque
data:
  client.crt: ${CLIENT_CRT_B64}
  client.key: ${CLIENT_KEY_B64}
  client-keystore.p12: ${CLIENT_KEYSTORE_B64}
  ca-chain.crt: ${CA_CHAIN_B64}
stringData:
  keystore-password: "${KEYSTORE_PASSWORD}"
  client-cn: "${client_cn}"
EOF
            fi
        done
    fi

    log_success "Manifesty Kubernetes wygenerowane: ${EXPORT_DIR}/kubernetes/tls-secrets.yaml"
}

#===============================================================================
# WERYFIKACJA
#===============================================================================
verify_certificates() {
    log_step "Weryfikacja certyfikatów"
    
    if ! check_intermediate_ca_exists; then
        log_error "Brak certyfikatów CA do weryfikacji"
        return 1
    fi
    
    log_info "Weryfikacja łańcucha Root CA -> Intermediate CA..."
    run_openssl verify -CAfile /export/root-ca/certs/rootCA.crt \
        /export/intermediate-ca/certs/intermediateCA.crt
    
    if [[ -f "${EXPORT_DIR}/server/server.crt" ]]; then
        log_info "Weryfikacja łańcucha CA -> Server Certificate..."
        run_openssl verify -CAfile /export/intermediate-ca/certs/ca-chain.crt \
            /export/server/server.crt
    fi
    
    # Weryfikacja wszystkich klientów
    if [[ -d "${EXPORT_DIR}/clients" ]]; then
        for client_dir in "${EXPORT_DIR}/clients"/*/; do
            if [[ -d "$client_dir" ]] && [[ -f "${client_dir}/client.crt" ]]; then
                local safe_name=$(basename "$client_dir")
                log_info "Weryfikacja łańcucha CA -> Client Certificate (${safe_name})..."
                run_openssl verify -CAfile /export/intermediate-ca/certs/ca-chain.crt \
                    "/export/clients/${safe_name}/client.crt"
            fi
        done
    fi
    
    log_success "Wszystkie certyfikaty zweryfikowane pomyślnie"
}

#===============================================================================
# LISTA KLIENTÓW
#===============================================================================
list_clients() {
    log_step "Lista certyfikatów klientów"
    
    if [[ -d "${EXPORT_DIR}/clients" ]]; then
        local count=0
        for client_dir in "${EXPORT_DIR}/clients"/*/; do
            if [[ -d "$client_dir" ]] && [[ -f "${client_dir}/client.crt" ]]; then
                local safe_name=$(basename "$client_dir")
                local client_cn="$safe_name"
                
                if [[ -f "${client_dir}/CN.txt" ]]; then
                    client_cn=$(cat "${client_dir}/CN.txt")
                fi
                
                # Pobierz datę wygaśnięcia
                local expiry=$(run_openssl x509 -noout -enddate -in "/export/clients/${safe_name}/client.crt" 2>/dev/null | cut -d= -f2)
                
                echo -e "  ${GREEN}●${NC} ${client_cn}"
                echo -e "    Katalog:  clients/${safe_name}/"
                echo -e "    Keystore: java-keystores/client-${safe_name}-keystore.p12"
                echo -e "    Wygasa:   ${expiry}"
                echo ""
                ((count++))
            fi
        done
        
        if [[ $count -eq 0 ]]; then
            log_warning "Brak wygenerowanych certyfikatów klientów"
        else
            log_info "Łącznie klientów: ${count}"
        fi
    else
        log_warning "Katalog clients/ nie istnieje"
    fi
}

#===============================================================================
# PODSUMOWANIE
#===============================================================================
print_summary() {
    log_step "Podsumowanie"
    
    echo -e "\n${GREEN}Wygenerowane pliki:${NC}"
    echo -e "\n${BLUE}Root CA:${NC}"
    echo "  - ${EXPORT_DIR}/root-ca/private/rootCA.key"
    echo "  - ${EXPORT_DIR}/root-ca/certs/rootCA.crt"
    
    echo -e "\n${BLUE}Intermediate CA:${NC}"
    echo "  - ${EXPORT_DIR}/intermediate-ca/private/intermediateCA.key"
    echo "  - ${EXPORT_DIR}/intermediate-ca/certs/intermediateCA.crt"
    echo "  - ${EXPORT_DIR}/intermediate-ca/certs/ca-chain.crt"
    
    if [[ -f "${EXPORT_DIR}/server/server.crt" ]]; then
        echo -e "\n${BLUE}Server Certificate:${NC}"
        echo "  - ${EXPORT_DIR}/server/server.key"
        echo "  - ${EXPORT_DIR}/server/server.crt"
        echo "  - ${EXPORT_DIR}/server/server-full-chain.crt"
    fi
    
    echo -e "\n${BLUE}Client Certificates:${NC}"
    if [[ -d "${EXPORT_DIR}/clients" ]]; then
        for client_dir in "${EXPORT_DIR}/clients"/*/; do
            if [[ -d "$client_dir" ]] && [[ -f "${client_dir}/client.crt" ]]; then
                local safe_name=$(basename "$client_dir")
                local client_cn="$safe_name"
                if [[ -f "${client_dir}/CN.txt" ]]; then
                    client_cn=$(cat "${client_dir}/CN.txt")
                fi
                echo "  - ${EXPORT_DIR}/clients/${safe_name}/ (CN: ${client_cn})"
            fi
        done
    else
        echo "  (brak)"
    fi
    
    echo -e "\n${BLUE}Java Keystores (PKCS12):${NC}"
    [[ -f "${EXPORT_DIR}/java-keystores/server-keystore.p12" ]] && echo "  - ${EXPORT_DIR}/java-keystores/server-keystore.p12"
    [[ -f "${EXPORT_DIR}/java-keystores/truststore.p12" ]] && echo "  - ${EXPORT_DIR}/java-keystores/truststore.p12"
    if [[ -d "${EXPORT_DIR}/clients" ]]; then
        for client_dir in "${EXPORT_DIR}/clients"/*/; do
            if [[ -d "$client_dir" ]]; then
                local safe_name=$(basename "$client_dir")
                [[ -f "${EXPORT_DIR}/java-keystores/client-${safe_name}-keystore.p12" ]] && \
                    echo "  - ${EXPORT_DIR}/java-keystores/client-${safe_name}-keystore.p12"
            fi
        done
    fi
    echo "  - Hasło: ${KEYSTORE_PASSWORD}"
    
    echo -e "\n${BLUE}Kubernetes:${NC}"
    echo "  - ${EXPORT_DIR}/kubernetes/tls-secrets.yaml"
    
    echo -e "\n${YELLOW}Ważność certyfikatów:${NC}"
    echo "  - Root CA:         ${ROOT_CA_DAYS} dni (~$((ROOT_CA_DAYS/365)) lat)"
    echo "  - Intermediate CA: ${INTERMEDIATE_CA_DAYS} dni (~$((INTERMEDIATE_CA_DAYS/365)) lat)"
    echo "  - Server/Client:   ${SERVER_CERT_DAYS} dni"
}

#===============================================================================
# POMOC
#===============================================================================
print_usage() {
    echo -e "${CYAN}PKI Certificate Generator v2.1.0 (Multi-Client)${NC}"
    echo ""
    echo "Użycie: $0 [KOMENDA] [OPCJE]"
    echo ""
    echo "Komendy:"
    echo "  (brak)              Pełna generacja (CA + server + domyślni klienci)"
    echo "  ca                  Tylko Root CA + Intermediate CA"
    echo "  server              Tylko certyfikat serwera"
    echo "  client [--cn NAME]  Dodaj nowego klienta"
    echo "  clients             Wygeneruj domyślnych klientów"
    echo "  keystores           Wygeneruj Java Keystores"
    echo "  k8s                 Wygeneruj manifesty Kubernetes"
    echo "  verify              Zweryfikuj certyfikaty"
    echo "  list                Lista wszystkich klientów"
    echo "  help                Ta pomoc"
    echo ""
    echo "Zmienne środowiskowe:"
    echo "  CLIENT_CN              CN dla nowego klienta (alternatywa dla --cn)"
    echo "  DEFAULT_CLIENTS        Lista domyślnych klientów (rozdzielona przecinkami)"
    echo "  SERVER_SANS            Subject Alternative Names dla serwera"
    echo "  ADD_SERVER_SANS        Dodatkowe SANs (dołączane do SERVER_SANS)"
    echo "  FORCE_REGENERATE_CA    Wymuś regenerację CA (true/false)"
    echo "  FORCE_REGENERATE_CERTS Wymuś regenerację certyfikatów (true/false)"
    echo ""
    echo "Przykłady:"
    echo "  $0                                       # Pełna generacja"
    echo "  $0 ca                                    # Tylko CA"
    echo "  $0 client --cn service-a@example.com    # Dodaj klienta"
    echo "  $0 client --cn service-b                # Dodaj kolejnego klienta"
    echo "  CLIENT_CN=admin $0 client               # Dodaj klienta (env)"
    echo "  DEFAULT_CLIENTS='svc-a,svc-b,admin' $0  # Wielu klientów na raz"
    echo ""
    echo "Przykłady SANs:"
    echo "  # Zastąp domyślne SANs"
    echo "  SERVER_SANS='DNS:myserver.local,DNS:api.myserver.local,IP:192.168.1.100' $0 server"
    echo ""
    echo "  # Dodaj do domyślnych SANs"
    echo "  ADD_SERVER_SANS='DNS:vm1.local,DNS:lab3.local,IP:192.168.122.100' $0 server"
    echo ""
    echo "  # Kubernetes + custom domains"
    echo "  SERVER_SANS='DNS:localhost,DNS:nginx.default.svc.cluster.local,DNS:myapp.local,IP:127.0.0.1,IP:10.0.0.50' $0 server"
}

#===============================================================================
# GŁÓWNA FUNKCJA
#===============================================================================
main() {
    local command="${1:-all}"
    shift || true
    
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          PKI Certificate Generator v2.1 (Multi-Client)            ║"
    echo "║        Java 25 | Spring 7 | Quarkus | Micronaut | K8s             ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_docker
    
    case "$command" in
        all)
            init_directory_structure
            create_openssl_config
            generate_root_ca
            generate_intermediate_ca
            generate_server_cert
            generate_all_clients
            generate_java_keystores
            generate_kubernetes_manifests
            verify_certificates
            print_summary
            ;;
        ca)
            init_directory_structure
            create_openssl_config
            generate_root_ca
            generate_intermediate_ca
            ;;
        server)
            init_directory_structure
            create_openssl_config
            generate_server_cert
            generate_java_keystores
            generate_kubernetes_manifests
            ;;
        client)
            # Parsowanie argumentów
            local client_cn="${CLIENT_CN:-}"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --cn)
                        client_cn="$2"
                        shift 2
                        ;;
                    *)
                        client_cn="$1"
                        shift
                        ;;
                esac
            done
            
            if [[ -z "$client_cn" ]]; then
                log_error "Brak CN klienta. Użyj: $0 client --cn <nazwa>"
                exit 1
            fi
            
            init_directory_structure
            create_openssl_config
            generate_client_cert "$client_cn" "true"
            generate_java_keystores
            generate_kubernetes_manifests
            ;;
        clients)
            init_directory_structure
            create_openssl_config
            generate_all_clients
            generate_java_keystores
            generate_kubernetes_manifests
            ;;
        keystores)
            generate_java_keystores
            ;;
        k8s)
            generate_kubernetes_manifests
            ;;
        verify)
            verify_certificates
            ;;
        list)
            list_clients
            ;;
        help|--help|-h)
            print_usage
            exit 0
            ;;
        *)
            log_error "Nieznana komenda: $command"
            print_usage
            exit 1
            ;;
    esac
    
    echo -e "\n${GREEN}✓ Operacja zakończona pomyślnie!${NC}\n"
}

# Uruchomienie
main "$@"
