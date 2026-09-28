# PROVISIONPATH is a variable that stores the absolute path of the directory containing the Makefile.
PROVISIONPATH := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
ANSIBLEPATH := $(PROVISIONPATH)/ansible

# The profile (laptop | mac-mini) is resolved by scripts/host-profile.sh from the
# hardware, so no argument is needed on either machine. Exported rather than passed
# through, so that both `HOST_PROFILE=mac-mini make deploy` and
# `make deploy HOST_PROFILE=mac-mini` reach the script.
export HOST_PROFILE

# ansible-lint runs in its own Homebrew virtualenv with no collections in it, while
# the ansible formula keeps its bundled collections inside its own virtualenv rather
# than the shared ~/.ansible/collections path. Point ansible-lint at that location,
# via brew --prefix so that a stale keg is never picked up.
ANSIBLE_PREFIX := $(shell brew --prefix ansible 2>/dev/null)
BUNDLED_COLLECTIONS := $(firstword $(wildcard $(ANSIBLE_PREFIX)/libexec/lib/python*/site-packages))

.DEFAULT_GOAL := help
.PHONY: all init deploy check lint help

all: init deploy ## Run init and deploy

init: ## Install Xcode CLT, Homebrew and Brewfile packages
	@bash $(PROVISIONPATH)/scripts/init.sh

deploy: ## Run ansible-playbook
	@profile="$$($(PROVISIONPATH)/scripts/host-profile.sh)" \
	  && cd $(ANSIBLEPATH) && ansible-playbook site.yml -e host_profile="$$profile"

check: ## Dry-run ansible-playbook (no changes are made)
	@profile="$$($(PROVISIONPATH)/scripts/host-profile.sh)" \
	  && cd $(ANSIBLEPATH) && ansible-playbook site.yml --check --diff -e host_profile="$$profile"

lint: ## Run ansible-lint
	@cd $(ANSIBLEPATH) && ANSIBLE_COLLECTIONS_PATH="$(BUNDLED_COLLECTIONS)" ansible-lint --offline -c .ansible-lint site.yml

help: ## Display available targets and their descriptions
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
