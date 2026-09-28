.PHONY: help doctor apply apply-infra apply-connectors up down destroy seed load smoke verify-clean clean format validate lint test render-diagram

help:
	@echo "Available targets:"
	@echo "  make doctor          - Pre-flight checks (credentials, tools, quotas, estimated cost)"
	@echo "  make up              - Full deployment (apply-infra + seed + apply-connectors)"
	@echo "  make apply-infra     - Deploy infrastructure only (enable_connectors=false)"
	@echo "  make seed            - Create schema, publication, and control topic"
	@echo "  make apply-connectors - Enable and deploy connectors (enable_connectors=true)"
	@echo "  make down            - Destroy all infrastructure"
	@echo "  make apply           - Legacy: deploy infrastructure (use 'up' for staged flow)"
	@echo "  make destroy         - Legacy: destroy infrastructure (use 'down')"
	@echo "  make load            - Run load generator (inserts/updates/deletes)"
	@echo "  make smoke           - End-to-end smoke test"
	@echo "  make verify-clean    - Verify all billable resources are removed after destroy"
	@echo "  make format          - Format Terraform files"
	@echo "  make validate        - Validate Terraform configuration"
	@echo "  make lint            - Run linters (shellcheck, Python)"
	@echo "  make test            - Run Python unit tests"
	@echo "  make render-diagram  - Generate architecture diagram"

doctor:
	@./scripts/doctor.sh

# Staged deployment flow
apply-infra:
	@echo "=== Applying infrastructure (connectors disabled) ==="
	@cd terraform && terraform init
	@cd terraform && terraform apply -var='enable_connectors=false' $(if $(AUTO_APPROVE),-auto-approve,)

apply-connectors:
	@echo "=== Enabling connectors ==="
	@cd terraform && terraform apply -var='enable_connectors=true' $(if $(AUTO_APPROVE),-auto-approve,)

up:
	@echo "=== Full staged deployment ==="
	@$(MAKE) apply-infra AUTO_APPROVE=$(AUTO_APPROVE)
	@$(MAKE) seed
	@$(MAKE) apply-connectors AUTO_APPROVE=$(AUTO_APPROVE)
	@echo ""
	@echo "=== Deployment complete ==="
	@echo "Run 'make smoke' to test the pipeline"

down:
	@echo "=== Destroying infrastructure ==="
	@if [ "$(AUTO_APPROVE)" = "1" ]; then \
		cd terraform && terraform destroy -auto-approve; \
	else \
		cd terraform && terraform destroy; \
	fi

# Legacy targets (for backward compatibility)
apply:
	@echo "Warning: 'make apply' is deprecated. Use 'make up' for staged deployment."
	@cd terraform && terraform init
	@if [ "$(AUTO_APPROVE)" = "1" ]; then \
		cd terraform && terraform apply -auto-approve; \
	else \
		cd terraform && terraform apply; \
	fi

destroy:
	@echo "Warning: 'make destroy' is deprecated. Use 'make down'."
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
