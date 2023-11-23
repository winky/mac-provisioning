# PROVISIONPATH is a variable that stores the absolute path of the directory containing the Makefile.
PROVISIONPATH := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))

# This Makefile sets the default goal to 'help'.
.DEFAULT_GOAL := help

all: ## All command run

init: ## Initialize Provisioning
	@bash $(PROVISIONPATH)/scripts/init.sh

deploy: ## Run ansible-playbook
	@cd $(PROVISIONPATH)/ansible && ansible-playbook site.yml --ask-vault-pass

help: ## Display available targets and their descriptions
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
