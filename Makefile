PROVISIONPATH	:= $(realpath $(dir $(lastword $(MAKEFILE_LIST))))

init: ## Initialize Provisioning
	@bash $(PROVISIONPATH)/etc/init/init.sh
