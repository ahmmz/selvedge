#########################################################
##
## systemd commands
##
#########################################################

check-sudo:
	@runner=`whoami` ; \
	if [ $$runner != "root" ]; then \
		echo "$(RED)==>$(RESET) Run 'make $(MAKECMDGOALS)' with superuser privileges."; \
		exit 1; \
	fi
systemd-install: check-sudo ## Install as a systemd service (Root required)
	@envsubst '$${CURRENT_DIR},$${DOCKER_COMPOSE}' \
		< $(ETC_DIR)/templates/systemd.service \
		> /etc/systemd/system/$(PROJECT_LOCASED).service
	@systemctl --quiet daemon-reload
	@systemctl --quiet enable $(PROJECT_LOCASED).service || true
systemd-uninstall: check-sudo ## Uninstall systemd service (Root required)
	@systemctl --quiet reset-failed $(PROJECT_LOCASED).service || true
	@systemctl --quiet disable $(PROJECT_LOCASED).service || true
	@systemctl --quiet daemon-reload
	@rm -f /etc/systemd/system/$(PROJECT_LOCASED).service

##############################################################
##
##############################################################
