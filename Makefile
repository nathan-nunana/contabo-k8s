VAULT := $(if $(wildcard .vault-pass),--vault-password-file .vault-pass,--ask-vault-pass)

.PHONY: deps bootstrap deploy check verify lint

deps:
	ansible-galaxy collection install -r requirements.yml

# First run only: connects as root, creates the admin user, disables root login.
bootstrap:
	ansible-playbook site.yml --tags hardening -e ansible_user=root $(VAULT)

deploy:
	ansible-playbook site.yml $(VAULT)

check:
	ansible-playbook site.yml --check --diff $(VAULT)

verify:
	ansible-playbook verify.yml $(VAULT)

lint:
	yamllint .
	ansible-lint
