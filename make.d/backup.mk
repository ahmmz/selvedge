#########################################################
## 
## Backup and Restore Commands 
##
#########################################################

BACKUP_DIR ?= $(CURRENT_DIR)/backup
TIMESTAMP := $(shell date +'%Y-%m-%d-%H%M%S')
BACKUP_FILE := $(BACKUP_DIR)/$(PROJECT_LOCASED)-backup-$(TIMESTAMP).tar.gz

.PHONY: backup
backup: ## Create a compressed backup of environment, configuration, and data
	@mkdir -p $(BACKUP_DIR)
	@echo "$(GREEN)==>$(RESET) Creating full backup: $(YELLOW)$(notdir $(BACKUP_FILE))$(RESET) ..."
	@tar -C $(CURRENT_DIR) \
		--exclude='.git' \
		--exclude='*.sock' \
		--exclude='data/log/*' \
		--exclude='*.pyc' \
		-czf $(BACKUP_FILE) \
		.env \
		etc \
		data \
		$(if $(wildcard $(CURRENT_DIR)/docker-compose.override.yml),docker-compose.override.yml) 2>/dev/null || true
	@echo "$(GREEN)==>$(RESET) Backup created successfully at: $(GREEN)$(BACKUP_FILE)$(RESET)"

.PHONY: restore
restore: ## Restore the latest configuration and data backup
	@LATEST=$$(ls -t $(BACKUP_DIR)/$(PROJECT_LOCASED)-backup-*.tar.gz 2>/dev/null | head -n 1); \
	if [ -z "$$LATEST" ] || [ ! -f "$$LATEST" ]; then \
		echo "$(RED)==>$(RESET) No backup files found in $(BACKUP_DIR)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)==>$(RESET) Restoring from latest backup: $(YELLOW)$$(basename $$LATEST)$(RESET) ..."; \
	tar -xvpzf "$$LATEST" -C $(CURRENT_DIR); \
	echo "$(GREEN)==>$(RESET) Restore completed successfully."

.PHONY: list-backups
list-backups: ## List all available backups
	@echo "$(GREEN)==>$(RESET) Available backups in $(YELLOW)$(BACKUP_DIR)$(RESET):"
	@if [ -d "$(BACKUP_DIR)" ] && [ "$$(ls -A $(BACKUP_DIR)/*.tar.gz 2>/dev/null)" ]; then \
		ls -lh $(BACKUP_DIR)/*.tar.gz | awk '{print "  - " $$9 " (" $$5 ", " $$6 " " $$7 " " $$8 ")";}'; \
	else \
		echo "  No backups found."; \
	fi
