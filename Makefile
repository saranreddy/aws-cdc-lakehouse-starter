.PHONY: help doctor apply destroy seed load smoke verify-clean clean format validate lint test render-diagram

help:
	@echo "Available targets:"
	@echo "  make doctor        - Pre-flight checks (credentials, tools, quotas, estimated cost)"
	@echo "  make apply         - Deploy infrastructure (use AUTO_APPROVE=1 for non-interactive)"
	@echo "  make destroy       - Destroy infrastructure (use AUTO_APPROVE=1 for non-interactive)"
	@echo "  make seed          - Create schema and insert seed data"
	@echo "  make load          - Run load generator (inserts/updates/deletes)"
	@echo "  make smoke         - End-to-end smoke test"
	@echo "  make verify-clean  - Verify all billable resources are removed after destroy"
	@echo "  make format        - Format Terraform files"
	@echo "  make validate      - Validate Terraform configuration"
	@echo "  make lint          - Run linters (shellcheck, Python)"
	@echo "  make test          - Run Python unit tests"
	@echo "  make render-diagram - Generate architecture diagram"

doctor:
	@./scripts/doctor.sh

apply:
	@cd terraform && terraform init
	@if [ "$(AUTO_APPROVE)" = "1" ]; then \
		cd terraform && terraform apply -auto-approve; \
	else \
		cd terraform && terraform apply; \
	fi

destroy:
	@if [ "$(AUTO_APPROVE)" = "1" ]; then \
		cd terraform && terraform destroy -auto-approve; \
	else \
		cd terraform && terraform destroy; \
	fi

seed:
	@./scripts/seed.sh

load:
	@python3 scripts/load_generator.py

smoke:
	@./scripts/smoke.sh

verify-clean:
	@./scripts/verify-clean.sh

format:
	@cd terraform && terraform fmt -recursive

validate:
	@cd terraform && terraform init -backend=false && terraform validate

lint:
	@echo "Running shellcheck..."
	@shellcheck scripts/*.sh || true
	@echo "Running Python linters..."
	@python3 -m pylint scripts/*.py || true

test:
	@echo "Running Python unit tests..."
	@python3 -m pytest tests/ -v

render-diagram:
	@python3 docs/architecture.py

clean:
	@rm -rf terraform/.terraform terraform/.terraform.lock.hcl terraform/terraform.tfstate*
