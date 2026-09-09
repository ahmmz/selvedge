#########################################################
##
## letsencrypt commands
##
#########################################################

.PHONY: le-list
le-list: ## List all configured Let's Encrypt domains
	@python3 $(CURRENT_DIR)/scripts/certificates.py le list

.PHONY: le-add
le-add: ## Add domain(s) to Let's Encrypt. Ex: make le-add example.com
	@DOMAINS="$(filter-out $@, $(MAKECMDGOALS))"; \
	if [ -z "$$DOMAINS" ]; then \
		echo "Please provide at least one domain name, e.g. make le-add example.com"; \
		exit 1; \
	fi; \
	python3 $(CURRENT_DIR)/scripts/certificates.py le add $$DOMAINS

.PHONY: le-remove
le-remove: ## Remove domain(s) from Let's Encrypt. Ex: make le-remove example.com
	@DOMAINS="$(filter-out $@, $(MAKECMDGOALS))"; \
	if [ -z "$$DOMAINS" ]; then \
		echo "Please provide at least one domain name, e.g. make le-remove example.com"; \
		exit 1; \
	fi; \
	python3 $(CURRENT_DIR)/scripts/certificates.py le remove $$DOMAINS

.PHONY: le-gen
le-gen: ## Regenerate Let's Encrypt Traefik configuration from .env
	@python3 $(CURRENT_DIR)/scripts/certificates.py le gen
