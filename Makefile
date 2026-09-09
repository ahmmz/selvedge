SHELL := bash
.DEFAULT_GOAL := help

export PROJECT := "Selvedge"
export PROJECT_LOCASED := $(strip $(subst -,_,$(shell echo $(PROJECT) | tr A-Z a-z)))
export CURRENT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
export ETC_DIR := $(CURRENT_DIR)/etc

ifneq (,$(wildcard $(CURRENT_DIR)/.env))
	include $(CURRENT_DIR)/.env
endif

RED=`tput -Txterm setaf 1`
GREEN=`tput -Txterm setaf 2`
RESET=`tput -Txterm sgr0`
YELLOW=`tput -Txterm setaf 3`
LIME=`tput -Txterm setaf 190`
BLUE=`tput -Txterm setaf 4`

export DOCKER := docker
export DOCKER_COMPOSE := docker compose
export DOCKER_COMPOSE

# check what editor is available
ifdef VSCODE_GIT_ASKPASS_NODE
	EDITOR := code
else
	EDITOR := vi
endif
export EDITOR

export ARGX_LOCASED := $(strip $(word 2,$(MAKECMDGOALS)))
export ENABLED_ADDONS_FILES := $(wildcard $(ETC_DIR)/compose/services-enabled/*.yml)
export ENABLED_ADDONS_FLAGS := $(foreach file, $(ENABLED_ADDONS_FILES), -f $(file))
export OVERRIDE_FILES := $(wildcard $(CURRENT_DIR)/docker-compose.override.yml) $(wildcard $(ETC_DIR)/compose/overrides-enabled/*.yml)
export OVERRIDE_FLAGS := $(foreach file, $(OVERRIDE_FILES), -f $(file))

BUILDABLE := $(shell grep -lE '^[[:space:]]+build:' $(CURRENT_DIR)/docker-compose.yml $(ENABLED_ADDONS_FILES) $(OVERRIDE_FILES) 2>/dev/null)

# use the rest as arguments as empty targets aka: MAGIC
EMPTY_TARGETS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
$(eval $(EMPTY_TARGETS):;@:)

export COMPOSE_FLAGS := --project-directory $(CURRENT_DIR) -f docker-compose.yml $(ENABLED_ADDONS_FLAGS) $(OVERRIDE_FLAGS)

#########################################################
##
## basic commands
##
#########################################################
help: ## Show this help text
	$(call help_function,$(CURRENT_DIR)/Makefile $(wildcard $(CURRENT_DIR)/make.d/*.mk))

.PHONY: check-docker check-runtime
check-docker:
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)==>$(RESET) 'docker' is required"; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo "$(RED)==>$(RESET) Docker Compose v2 is required"; exit 1; }

check-runtime: check-docker
	@command -v python3 >/dev/null 2>&1 || { echo "$(RED)==>$(RESET) 'python3' is required"; exit 1; }
	@command -v openssl >/dev/null 2>&1 || { echo "$(RED)==>$(RESET) 'openssl' is required"; exit 1; }

start: check-runtime bootstrap ## Start Selvedge Service
	@echo "$(GREEN)==>$(RESET) Starting $(GREEN)$(PROJECT)$(RESET) Stack ..."
	@$(DOCKER_COMPOSE) $(COMPOSE_FLAGS) up -d --build --remove-orphans

stop: check-docker bootstrap ## Stop Selvedge Service
	@echo "$(RED)==>$(RESET) Stopping $(GREEN)$(PROJECT)$(RESET) Stack ..."
	@$(DOCKER_COMPOSE) $(COMPOSE_FLAGS) down --remove-orphans

build: check-docker ## Build custom local container images
ifneq ($(BUILDABLE),)
	@echo "$(GREEN)==>$(RESET) Building custom images for $(GREEN)$(PROJECT)$(RESET) Stack ..."
	@$(DOCKER_COMPOSE) $(COMPOSE_FLAGS) build --pull
endif

pull: check-docker ## Pull remote images and rebuild local custom images
	@echo "$(GREEN)==>$(RESET) Pulling images for $(GREEN)$(PROJECT)$(RESET) Stack ..."
	@$(DOCKER_COMPOSE) $(COMPOSE_FLAGS) pull --ignore-buildable
	@$(MAKE) --no-print-directory build

up: start
down: stop
reset: restart
log: logs
restart: stop start ## Restart Selvedge Service
update: stop pull prune start ## Update and restart Selvedge

report: check-docker ## Show CrowdSec bouncer, alert, and decision metrics
	@docker ps --format '{{.Names}}' | grep -q '^crowdsec$$' || { \
		echo "$(YELLOW)==>$(RESET) CrowdSec is not running"; exit 0; }
	@echo "$(GREEN)==>$(RESET) Bouncer metrics (requests dropped at edge):"
	@docker exec crowdsec cscli metrics show bouncers 2>/dev/null || true
	@echo "$(GREEN)==>$(RESET) Alert metrics (detected threat reasons):"
	@docker exec crowdsec cscli metrics show alerts 2>/dev/null || true
	@echo "$(GREEN)==>$(RESET) Active decisions (local bans & community intelligence):"
	@docker exec crowdsec cscli decisions list 2>/dev/null || true

logs: check-docker ## Show Selvedge logs
	$(DOCKER_COMPOSE) $(COMPOSE_FLAGS) logs --tail 1000 -f

.PHONY: config validate config-show
config: validate ## Validate the merged Compose configuration without printing secrets

validate: check-docker ## Validate the merged Compose configuration without printing it
	@$(DOCKER_COMPOSE) $(COMPOSE_FLAGS) config --quiet

config-show: check-docker ## Show resolved Compose configuration (may contain secrets)
	@echo "$(YELLOW)==> WARNING: resolved configuration may contain secrets$(RESET)"
	@$(DOCKER_COMPOSE) $(COMPOSE_FLAGS) config

prune: check-docker
	@$(DOCKER) image prune -f

bootstrap:
	@$(CURRENT_DIR)/scripts/bootstrap.sh
	@python3 $(CURRENT_DIR)/scripts/certificates.py le gen
	@python3 $(CURRENT_DIR)/scripts/certificates.py mkcert gen

.PHONY: create-service create-addon
create-service: ## Create an add-on Compose file from the service template
	@if [ -z "$(ARGX_LOCASED)" ]; then \
		echo "$(RED)==>$(RESET) Usage: make create-service <name>"; \
		exit 1; \
	fi
	@if [[ ! "$(ARGX_LOCASED)" =~ ^[a-z0-9]+([_-][a-z0-9]+)*$$ ]]; then \
		echo "$(RED)==>$(RESET) Add-on names must be lowercase slugs (letters, numbers, '-' or '_')"; \
		exit 1; \
	fi
	@if ! command -v envsubst >/dev/null 2>&1; then \
		echo "$(RED)==>$(RESET) 'envsubst' is required to create an add-on"; \
		exit 1; \
	fi
	@if [ -e "$(ETC_DIR)/compose/services-available/$(ARGX_LOCASED).yml" ]; then \
		echo "$(RED)==>$(RESET) Add-on '$(ARGX_LOCASED)' already exists"; \
		exit 1; \
	fi
	@envsubst '$${ARGX_LOCASED}' \
		< $(ETC_DIR)/templates/service.template \
		> $(ETC_DIR)/compose/services-available/$(ARGX_LOCASED).yml
	@echo "$(GREEN)==>$(RESET) Created $(ETC_DIR)/compose/services-available/$(ARGX_LOCASED).yml"

create-addon: create-service ## Alias for create-service

edit-env: ## Edit the .env file using the editor specified in the EDITOR variable
	@cp -n ${CURRENT_DIR}/.env.example ${CURRENT_DIR}/.env
	@chmod 600 ${CURRENT_DIR}/.env
	@$(EDITOR) ${CURRENT_DIR}/.env

.PHONY: enable
enable: ## Enable a Traefik add-on, middleware, override, or dynamic config
	@if [ ! -f $(ETC_DIR)/compose/services-available/$(ARGX_LOCASED).yml ] && [ ! -f $(ETC_DIR)/traefik/available/$(ARGX_LOCASED).yml ] && [ ! -f $(ETC_DIR)/compose/overrides-available/$(ARGX_LOCASED).yml ]; then \
		echo "$(RED)==>$(RESET) No such Add-On / Override YAML file for '$(ARGX_LOCASED)'"; \
		exit 1; \
	fi
	@echo "$(GREEN)==>$(RESET) Enabling $(GREEN)$(ARGX_LOCASED)$(RESET) Add-On / Override ..."
	@if [ -f $(ETC_DIR)/compose/services-available/$(ARGX_LOCASED).yml ]; then \
		ln -sf $(ETC_DIR)/compose/services-available/$(ARGX_LOCASED).yml \
			$(ETC_DIR)/compose/services-enabled/$(ARGX_LOCASED).yml; \
	fi
	@if [ -f $(ETC_DIR)/traefik/available/$(ARGX_LOCASED).yml ]; then \
		cp -f $(ETC_DIR)/traefik/available/$(ARGX_LOCASED).yml \
			$(ETC_DIR)/traefik/enabled/$(ARGX_LOCASED).yml; \
	fi
	@if [ -f $(ETC_DIR)/compose/overrides-available/$(ARGX_LOCASED).yml ]; then \
		ln -sf $(ETC_DIR)/compose/overrides-available/$(ARGX_LOCASED).yml \
			$(ETC_DIR)/compose/overrides-enabled/$(ARGX_LOCASED).yml; \
	fi
	@bash $(CURRENT_DIR)/scripts/compose.sh sync enable $(ARGX_LOCASED)

.PHONY: disable
disable: ## Disable a Traefik add-on, middleware, override, or dynamic config
	@echo "$(GREEN)==>$(RESET) Disabling $(GREEN)$(ARGX_LOCASED)$(RESET) Add-On / Override ..."
	@rm -f $(ETC_DIR)/compose/services-enabled/$(ARGX_LOCASED).yml
	@rm -f $(ETC_DIR)/traefik/enabled/$(ARGX_LOCASED).yml
	@rm -f $(ETC_DIR)/compose/overrides-enabled/$(ARGX_LOCASED).yml
	@bash $(CURRENT_DIR)/scripts/compose.sh sync disable $(ARGX_LOCASED)

ALL_SVCS := $(basename $(notdir $(wildcard $(ETC_DIR)/compose/services-available/*.yml) $(wildcard $(ETC_DIR)/traefik/available/*.yml) $(wildcard $(ETC_DIR)/compose/overrides-available/*.yml)))
$(ALL_SVCS):

include $(CURRENT_DIR)/make.d/help.mk
include $(CURRENT_DIR)/make.d/backup.mk
include $(CURRENT_DIR)/make.d/mkcert.mk
include $(CURRENT_DIR)/make.d/systemd.mk
include $(CURRENT_DIR)/make.d/letsencrypt.mk

##############################################################
##
##############################################################
