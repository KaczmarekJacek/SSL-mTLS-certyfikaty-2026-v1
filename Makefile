#===============================================================================
# PKI Certificate Generator - Makefile (Multi-Client)
# 
# Cele:
#   make ca           - tylko Root + Intermediate CA (jednorazowo)
#   make server       - tylko certyfikat serwera
#   make client       - dodaj nowego klienta (CLIENT_CN=nazwa)
#   make clients      - domyślni klienci
#   make certs        - server + domyślni klienci
#   make all          - pełna regeneracja
#
# Wersja: 2.1.0
# Kompatybilność: Java 25, Spring 7, Quarkus 3+, Micronaut 4+, Kubernetes
#===============================================================================

.PHONY: all ca server client clients certs keystores k8s clean clean-certs \
        clean-clients verify shell help list show-server show-client \
        check-expiry test-mtls info force-all force-certs force-server

#-------------------------------------------------------------------------------
# Konfiguracja
#-------------------------------------------------------------------------------
DOCKER_IMAGE   ?= alpine/openssl
EXPORT_DIR     ?= ./certs
SCRIPTS_DIR    := ./scripts

# Domyślni klienci (rozdzieleni przecinkami)
DEFAULT_CLIENTS ?= default-client

# Nowy klient (dla make client)
CLIENT_CN      ?=

# Subject Alternative Names dla serwera
# Format: "DNS:nazwa1,DNS:nazwa2,IP:1.2.3.4"
SERVER_SANS    ?=
ADD_SERVER_SANS ?=

# Ścieżki do certyfikatów
ROOT_CA_CRT      := $(EXPORT_DIR)/root-ca/certs/rootCA.crt
INTERMEDIATE_CRT := $(EXPORT_DIR)/intermediate-ca/certs/intermediateCA.crt
SERVER_CRT       := $(EXPORT_DIR)/server/server.crt
SERVER_KEYSTORE  := $(EXPORT_DIR)/java-keystores/server-keystore.p12
K8S_SECRETS      := $(EXPORT_DIR)/kubernetes/tls-secrets.yaml

# Kolory
CYAN   := \033[0;36m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m

#-------------------------------------------------------------------------------
# Główne cele
#-------------------------------------------------------------------------------

## all: Pełna regeneracja (CA → Server → Clients → Keystores → K8s)
all:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@DEFAULT_CLIENTS="$(DEFAULT_CLIENTS)" \
		SERVER_SANS="$(SERVER_SANS)" \
		ADD_SERVER_SANS="$(ADD_SERVER_SANS)" \
		$(SCRIPTS_DIR)/generate-certificates.sh all

## ca: Generuj tylko Root CA + Intermediate CA (idempotentne)
ca:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@$(SCRIPTS_DIR)/generate-certificates.sh ca
	@echo -e "$(GREEN)✓ Certyfikaty CA gotowe$(NC)"

## server: Generuj tylko certyfikat serwera
server:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@SERVER_SANS="$(SERVER_SANS)" \
		ADD_SERVER_SANS="$(ADD_SERVER_SANS)" \
		$(SCRIPTS_DIR)/generate-certificates.sh server
	@echo -e "$(GREEN)✓ Certyfikat serwera gotowy$(NC)"

## client: Dodaj nowego klienta (wymaga CLIENT_CN=nazwa)
client:
ifndef CLIENT_CN
	$(error CLIENT_CN nie jest ustawiony. Użyj: make client CLIENT_CN="nazwa-klienta")
endif
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@$(SCRIPTS_DIR)/generate-certificates.sh client --cn "$(CLIENT_CN)"
	@echo -e "$(GREEN)✓ Klient '$(CLIENT_CN)' dodany$(NC)"

## clients: Generuj domyślnych klientów (DEFAULT_CLIENTS)
clients:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@DEFAULT_CLIENTS="$(DEFAULT_CLIENTS)" $(SCRIPTS_DIR)/generate-certificates.sh clients
	@echo -e "$(GREEN)✓ Domyślni klienci wygenerowani$(NC)"

## certs: Generuj server + domyślni klienci (wymaga CA)
certs: server clients
	@echo -e "$(GREEN)✓ Wszystkie certyfikaty końcowe gotowe$(NC)"

## keystores: Generuj Java Keystores (PKCS12)
keystores:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@$(SCRIPTS_DIR)/generate-certificates.sh keystores
	@echo -e "$(GREEN)✓ Java Keystores gotowe$(NC)"

## k8s: Generuj manifesty Kubernetes
k8s:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@$(SCRIPTS_DIR)/generate-certificates.sh k8s
	@echo -e "$(GREEN)✓ Manifesty Kubernetes gotowe$(NC)"

#-------------------------------------------------------------------------------
# Wymuszone regeneracje
#-------------------------------------------------------------------------------

## force-all: Wymuś pełną regenerację (usuwa wszystko)
force-all: clean
	@echo -e "$(YELLOW)Wymuszam pełną regenerację...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@FORCE_REGENERATE_CA=true FORCE_REGENERATE_CERTS=true \
		DEFAULT_CLIENTS="$(DEFAULT_CLIENTS)" $(SCRIPTS_DIR)/generate-certificates.sh all

## force-certs: Wymuś regenerację certyfikatów (zachowuje CA)
force-certs: clean-server clean-clients
	@echo -e "$(YELLOW)Wymuszam regenerację certyfikatów...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@FORCE_REGENERATE_CERTS=true \
		DEFAULT_CLIENTS="$(DEFAULT_CLIENTS)" $(SCRIPTS_DIR)/generate-certificates.sh all

## force-server: Wymuś regenerację tylko serwera
force-server:
	@echo -e "$(YELLOW)Wymuszam regenerację certyfikatu serwera...$(NC)"
	@rm -rf $(EXPORT_DIR)/server
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@FORCE_REGENERATE_CERTS=true $(SCRIPTS_DIR)/generate-certificates.sh server

#-------------------------------------------------------------------------------
# Czyszczenie
#-------------------------------------------------------------------------------

## clean: Usuń wszystkie wygenerowane pliki
clean:
	@echo -e "$(RED)Usuwanie wszystkich certyfikatów...$(NC)"
	@rm -rf $(EXPORT_DIR)
	@echo -e "$(GREEN)✓ Katalog $(EXPORT_DIR) usunięty$(NC)"

## clean-certs: Usuń certyfikaty końcowe (zachowuje CA)
clean-certs: clean-server clean-clients
	@echo -e "$(GREEN)✓ Certyfikaty końcowe usunięte (CA zachowane)$(NC)"

## clean-server: Usuń tylko certyfikat serwera
clean-server:
	@echo -e "$(YELLOW)Usuwanie certyfikatu serwera...$(NC)"
	@rm -rf $(EXPORT_DIR)/server
	@rm -f $(EXPORT_DIR)/java-keystores/server-keystore.p12

## clean-clients: Usuń wszystkich klientów
clean-clients:
	@echo -e "$(YELLOW)Usuwanie certyfikatów klientów...$(NC)"
	@rm -rf $(EXPORT_DIR)/clients
	@rm -f $(EXPORT_DIR)/java-keystores/client-*.p12
	@rm -rf $(EXPORT_DIR)/kubernetes

## clean-client: Usuń konkretnego klienta (CLIENT_CN=nazwa)
clean-client:
ifndef CLIENT_CN
	$(error CLIENT_CN nie jest ustawiony. Użyj: make clean-client CLIENT_CN="nazwa")
endif
	@echo -e "$(YELLOW)Usuwanie klienta: $(CLIENT_CN)...$(NC)"
	@SAFE_NAME=$$(echo "$(CLIENT_CN)" | sed 's/[^a-zA-Z0-9._-]/_/g' | tr '[:upper:]' '[:lower:]'); \
	rm -rf $(EXPORT_DIR)/clients/$$SAFE_NAME; \
	rm -f $(EXPORT_DIR)/java-keystores/client-$$SAFE_NAME-keystore.p12
	@echo -e "$(GREEN)✓ Klient '$(CLIENT_CN)' usunięty$(NC)"

#-------------------------------------------------------------------------------
# Weryfikacja i diagnostyka
#-------------------------------------------------------------------------------

## verify: Zweryfikuj łańcuchy certyfikatów
verify:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@$(SCRIPTS_DIR)/generate-certificates.sh verify

## list: Lista wszystkich klientów
list:
	@chmod +x $(SCRIPTS_DIR)/generate-certificates.sh
	@$(SCRIPTS_DIR)/generate-certificates.sh list

## show-server: Pokaż szczegóły certyfikatu serwera
show-server:
	@echo -e "$(CYAN)=== Server Certificate ===$(NC)"
	@docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		x509 -noout -subject -issuer -dates -ext subjectAltName \
		-in /export/server/server.crt 2>/dev/null || echo "Certyfikat serwera nie istnieje"

## show-sans: Pokaż tylko Subject Alternative Names serwera
show-sans:
	@echo -e "$(CYAN)=== Server SANs ===$(NC)"
	@docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		x509 -noout -ext subjectAltName \
		-in /export/server/server.crt 2>/dev/null || echo "Certyfikat serwera nie istnieje"

## show-client: Pokaż szczegóły certyfikatu klienta (CLIENT_CN=nazwa)
show-client:
ifndef CLIENT_CN
	$(error CLIENT_CN nie jest ustawiony. Użyj: make show-client CLIENT_CN="nazwa")
endif
	@echo -e "$(CYAN)=== Client Certificate: $(CLIENT_CN) ===$(NC)"
	@SAFE_NAME=$$(echo "$(CLIENT_CN)" | sed 's/[^a-zA-Z0-9._-]/_/g' | tr '[:upper:]' '[:lower:]'); \
	docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		x509 -noout -subject -issuer -dates \
		-in /export/clients/$$SAFE_NAME/client.crt 2>/dev/null || \
		echo "Klient '$(CLIENT_CN)' nie istnieje"

## check-expiry: Sprawdź daty wygaśnięcia wszystkich certyfikatów
check-expiry:
	@echo -e "$(CYAN)=== Daty wygaśnięcia certyfikatów ===$(NC)"
	@echo -e "\n$(YELLOW)Root CA:$(NC)"
	@docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		x509 -noout -enddate -in /export/root-ca/certs/rootCA.crt 2>/dev/null || echo "  (brak)"
	@echo -e "\n$(YELLOW)Intermediate CA:$(NC)"
	@docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		x509 -noout -enddate -in /export/intermediate-ca/certs/intermediateCA.crt 2>/dev/null || echo "  (brak)"
	@echo -e "\n$(YELLOW)Server:$(NC)"
	@docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		x509 -noout -enddate -in /export/server/server.crt 2>/dev/null || echo "  (brak)"
	@echo -e "\n$(YELLOW)Clients:$(NC)"
	@for dir in $(EXPORT_DIR)/clients/*/; do \
		if [ -d "$$dir" ] && [ -f "$$dir/client.crt" ]; then \
			name=$$(basename "$$dir"); \
			cn=$$name; \
			if [ -f "$$dir/CN.txt" ]; then cn=$$(cat "$$dir/CN.txt"); fi; \
			expiry=$$(docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
				x509 -noout -enddate -in /export/clients/$$name/client.crt 2>/dev/null | cut -d= -f2); \
			echo "  $$cn: $$expiry"; \
		fi \
	done

## check-keystore: Sprawdź zawartość server-keystore.p12
check-keystore:
	@echo -e "$(CYAN)=== Server Keystore ===$(NC)"
	@docker run --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		pkcs12 -info -in /export/java-keystores/server-keystore.p12 \
		-passin pass:changeit -nokeys 2>/dev/null || echo "Keystore nie istnieje"

#-------------------------------------------------------------------------------
# Narzędzia
#-------------------------------------------------------------------------------

## shell: Uruchom interaktywną powłokę z OpenSSL
shell:
	@echo -e "$(CYAN)Uruchamiam interaktywną powłokę OpenSSL...$(NC)"
	@docker run -it --rm -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) sh

## test-mtls: Testuj połączenie mTLS (wymaga uruchomionego serwera)
test-mtls:
ifndef CLIENT_CN
	@echo -e "$(CYAN)=== Test mTLS z domyślnym klientem ===$(NC)"
	@FIRST_CLIENT=$$(ls -1 $(EXPORT_DIR)/clients/ 2>/dev/null | head -1); \
	if [ -n "$$FIRST_CLIENT" ]; then \
		docker run --rm --network=host -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
			s_client -connect localhost:8443 \
			-CAfile /export/intermediate-ca/certs/ca-chain.crt \
			-cert /export/clients/$$FIRST_CLIENT/client.crt \
			-key /export/clients/$$FIRST_CLIENT/client.key \
			-pass pass:client-secret \
			-brief 2>&1 | head -20; \
	else \
		echo "Brak klientów - najpierw wygeneruj certyfikaty"; \
	fi
else
	@echo -e "$(CYAN)=== Test mTLS z klientem: $(CLIENT_CN) ===$(NC)"
	@SAFE_NAME=$$(echo "$(CLIENT_CN)" | sed 's/[^a-zA-Z0-9._-]/_/g' | tr '[:upper:]' '[:lower:]'); \
	docker run --rm --network=host -v $(PWD)/$(EXPORT_DIR):/export $(DOCKER_IMAGE) \
		s_client -connect localhost:8443 \
		-CAfile /export/intermediate-ca/certs/ca-chain.crt \
		-cert /export/clients/$$SAFE_NAME/client.crt \
		-key /export/clients/$$SAFE_NAME/client.key \
		-pass pass:client-secret \
		-brief 2>&1 | head -20
endif

## info: Pokaż informacje o konfiguracji
info:
	@echo -e "$(CYAN)╔═══════════════════════════════════════════════════════════╗$(NC)"
	@echo -e "$(CYAN)║      PKI Certificate Generator - Konfiguracja             ║$(NC)"
	@echo -e "$(CYAN)╚═══════════════════════════════════════════════════════════╝$(NC)"
	@echo -e "\n$(YELLOW)Docker Image:$(NC)     $(DOCKER_IMAGE)"
	@echo -e "$(YELLOW)Export Dir:$(NC)       $(EXPORT_DIR)"
	@echo -e "$(YELLOW)Default Clients:$(NC)  $(DEFAULT_CLIENTS)"
	@echo -e "\n$(YELLOW)Wygenerowane certyfikaty:$(NC)"
	@echo -n "  CA:      "; [ -f "$(ROOT_CA_CRT)" ] && echo -e "$(GREEN)✓$(NC)" || echo -e "$(RED)✗$(NC)"
	@echo -n "  Server:  "; [ -f "$(SERVER_CRT)" ] && echo -e "$(GREEN)✓$(NC)" || echo -e "$(RED)✗$(NC)"
	@echo -n "  Clients: "; \
		count=$$(find $(EXPORT_DIR)/clients -name "client.crt" 2>/dev/null | wc -l); \
		if [ "$$count" -gt 0 ]; then echo -e "$(GREEN)$$count$(NC)"; else echo -e "$(RED)0$(NC)"; fi

#-------------------------------------------------------------------------------
# Pomoc
#-------------------------------------------------------------------------------

## help: Wyświetl tę pomoc
help:
	@echo -e "$(CYAN)╔═══════════════════════════════════════════════════════════════════╗$(NC)"
	@echo -e "$(CYAN)║          PKI Certificate Generator v2.1 (Multi-Client)            ║$(NC)"
	@echo -e "$(CYAN)║        Java 25 | Spring 7 | Quarkus | Micronaut | K8s             ║$(NC)"
	@echo -e "$(CYAN)╚═══════════════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@echo -e "$(YELLOW)GŁÓWNE CELE:$(NC)"
	@echo -e "  $(GREEN)make all$(NC)                       Pełna regeneracja"
	@echo -e "  $(GREEN)make ca$(NC)                        Tylko Root CA + Intermediate CA"
	@echo -e "  $(GREEN)make server$(NC)                    Tylko certyfikat serwera"
	@echo -e "  $(GREEN)make client CLIENT_CN=nazwa$(NC)    Dodaj nowego klienta"
	@echo -e "  $(GREEN)make clients$(NC)                   Domyślni klienci (DEFAULT_CLIENTS)"
	@echo -e "  $(GREEN)make certs$(NC)                     Server + domyślni klienci"
	@echo -e "  $(GREEN)make keystores$(NC)                 Generuj Java Keystores"
	@echo -e "  $(GREEN)make k8s$(NC)                       Generuj manifesty Kubernetes"
	@echo ""
	@echo -e "$(YELLOW)ZARZĄDZANIE KLIENTAMI:$(NC)"
	@echo -e "  $(GREEN)make client CLIENT_CN=svc-a$(NC)    Dodaj klienta 'svc-a'"
	@echo -e "  $(GREEN)make client CLIENT_CN=svc-b$(NC)    Dodaj klienta 'svc-b'"
	@echo -e "  $(GREEN)make list$(NC)                      Lista wszystkich klientów"
	@echo -e "  $(GREEN)make show-client CLIENT_CN=x$(NC)   Szczegóły klienta"
	@echo -e "  $(GREEN)make clean-client CLIENT_CN=x$(NC)  Usuń klienta"
	@echo ""
	@echo -e "$(YELLOW)WYMUSZANIE:$(NC)"
	@echo -e "  $(GREEN)make force-all$(NC)                 Wymuś pełną regenerację"
	@echo -e "  $(GREEN)make force-certs$(NC)               Wymuś regenerację certyfikatów"
	@echo -e "  $(GREEN)make force-server$(NC)              Wymuś regenerację serwera"
	@echo ""
	@echo -e "$(YELLOW)CZYSZCZENIE:$(NC)"
	@echo -e "  $(GREEN)make clean$(NC)                     Usuń wszystko"
	@echo -e "  $(GREEN)make clean-certs$(NC)               Usuń certyfikaty (zachowaj CA)"
	@echo -e "  $(GREEN)make clean-server$(NC)              Usuń tylko serwer"
	@echo -e "  $(GREEN)make clean-clients$(NC)             Usuń wszystkich klientów"
	@echo -e "  $(GREEN)make clean-client CLIENT_CN=x$(NC)  Usuń konkretnego klienta"
	@echo ""
	@echo -e "$(YELLOW)WERYFIKACJA:$(NC)"
	@echo -e "  $(GREEN)make verify$(NC)                    Zweryfikuj łańcuchy"
	@echo -e "  $(GREEN)make list$(NC)                      Lista klientów"
	@echo -e "  $(GREEN)make check-expiry$(NC)              Daty wygaśnięcia"
	@echo -e "  $(GREEN)make info$(NC)                      Status konfiguracji"
	@echo ""
	@echo -e "$(YELLOW)NARZĘDZIA:$(NC)"
	@echo -e "  $(GREEN)make shell$(NC)                     Interaktywna powłoka OpenSSL"
	@echo -e "  $(GREEN)make test-mtls$(NC)                 Test połączenia mTLS"
	@echo -e "  $(GREEN)make test-mtls CLIENT_CN=x$(NC)     Test mTLS z konkretnym klientem"
	@echo ""
	@echo -e "$(YELLOW)ZMIENNE:$(NC)"
	@echo -e "  DEFAULT_CLIENTS=\"svc-a,svc-b,admin\"  Lista domyślnych klientów"
	@echo -e "  CLIENT_CN=\"nazwa\"                   CN dla nowego klienta"
	@echo -e "  EXPORT_DIR=\"./certs\"                Katalog wyjściowy"
	@echo -e "  SERVER_SANS=\"DNS:x,IP:y\"            Subject Alternative Names"
	@echo -e "  ADD_SERVER_SANS=\"DNS:x,IP:y\"        Dodatkowe SANs (dołączane)"
	@echo ""
	@echo -e "$(YELLOW)PRZYKŁADY:$(NC)"
	@echo -e "  make ca                              # Wygeneruj CA (raz)"
	@echo -e "  make client CLIENT_CN=service-a     # Dodaj klienta"
	@echo -e "  make client CLIENT_CN=service-b     # Dodaj kolejnego"
	@echo -e "  make client CLIENT_CN=admin         # I jeszcze jednego"
	@echo -e "  make list                           # Pokaż wszystkich"
	@echo -e "  DEFAULT_CLIENTS=\"a,b,c\" make all    # Wielu klientów na raz"
	@echo ""
	@echo -e "$(YELLOW)PRZYKŁADY SANs:$(NC)"
	@echo -e "  # Zastąp domyślne SANs"
	@echo -e "  make server SERVER_SANS=\"DNS:myapp.local,IP:192.168.1.100\""
	@echo ""
	@echo -e "  # Dodaj do domyślnych SANs"
	@echo -e "  make server ADD_SERVER_SANS=\"DNS:vm1.local,DNS:lab3.local,IP:192.168.122.100\""
	@echo ""
	@echo -e "  # Kubernetes lab"
	@echo -e "  make server ADD_SERVER_SANS=\"DNS:nginx-lab3.lab-3.svc.cluster.local,DNS:nginx-lab3,IP:10.96.0.50\""

.DEFAULT_GOAL := help
