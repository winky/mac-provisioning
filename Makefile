PROVISIONPATH	:= $(realpath $(dir $(lastword $(MAKEFILE_LIST))))

init: ## Initialize Provisioning
	@bash $(PROVISIONPATH)/scripts/init.sh

deploy: ## run ansible-playbook
	@ansible-playbook ansible/site.yml -i ansible/inventories/macOS/local.yml --ask-vault-pass
