# Stop the stack before backup or restore. Archives contain secrets.
BACKUP_DIR ?= $(CURRENT_DIR)/backup
# Leave empty to back up to a timestamped default name, or restore the newest completed archive.
BACKUP_FILE ?=
BACKUP_COMMAND = python3 "$(CURRENT_DIR)/scripts/backup.py" --root "$(CURRENT_DIR)" --directory "$(BACKUP_DIR)" --project "$(PROJECT_LOCASED)"

.PHONY: backup restore list-backups
backup: ## Back up local config and all data to BACKUP_FILE, or a timestamped default (stop the stack first)
	@$(BACKUP_COMMAND) backup $(if $(BACKUP_FILE),--file "$(BACKUP_FILE)")

restore: ## Restore BACKUP_FILE, or the newest backup if unset (stop the stack first)
	@$(BACKUP_COMMAND) restore $(if $(BACKUP_FILE),--file "$(BACKUP_FILE)")

list-backups: ## List completed backups, newest first
	@$(BACKUP_COMMAND) list
