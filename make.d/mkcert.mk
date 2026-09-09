#########################################################
##
## mkcert commands (Internal, Staging & Private Apps)
##
#########################################################

export TRUST_STORES="system"
export CAROOT := $(ETC_DIR)/mkcert/rootCA
export MKCERT_PATH := $(ETC_DIR)/mkcert

.PHONY: cert-add cert
cert-add: cert ## Create or update internal, staging, or private certificates. Ex: make cert-add app.internal

cert:
	@DOMAINS="$(filter-out cert cert-add, $(MAKECMDGOALS))"; \
	if [ -z "$$DOMAINS" ]; then \
		echo "Please provide at least one domain name, e.g. make cert app.internal"; \
		exit 1; \
	fi; \
	python3 $(CURRENT_DIR)/scripts/certificates.py mkcert add $$DOMAINS

.PHONY: cert-remove
cert-remove: ## Remove internal, staging, or private certificates. Ex: make cert-remove app.internal
	@DOMAINS="$(filter-out $@, $(MAKECMDGOALS))"; \
	if [ -z "$$DOMAINS" ]; then \
		echo "Please provide at least one domain name, e.g. make cert-remove app.internal"; \
		exit 1; \
	fi; \
	python3 $(CURRENT_DIR)/scripts/certificates.py mkcert remove $$DOMAINS

.PHONY: cert-list
cert-list: ## List all active internal, staging, or private certificates
	@python3 $(CURRENT_DIR)/scripts/certificates.py mkcert list

.PHONY: cert-gen
cert-gen: ## Regenerate Dynamic file provider configuration for internal & staging certificates
	@python3 $(CURRENT_DIR)/scripts/certificates.py mkcert gen

%:
	@true

.PHONY: cert-info
cert-info: ## Print mkcert certificate details
	@openssl x509 -noout -text -in $(MKCERT_PATH)/$(ARGX_LOCASED) -certopt \
	"no_issuer, no_pubkey, no_sigdump, no_aux"

##############################################################
##
##############################################################
