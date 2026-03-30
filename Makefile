MODULE_DIR   := modules/postgres
INTG_DIR     := tests/postgres/integration
INTG_IMAGE   := pg-integration-test:latest
UNIT_FILTER  ?=

.PHONY: help unit preflight integration test \
        build-image tf-init tf-init-preflight \
        clean clean-intg

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

help:
	@echo "Usage: make <target> [UNIT_FILTER=file.tftest.hcl]"
	@echo ""
	@echo "Test layers:"
	@echo "  unit         terraform test — formula unit tests (no infrastructure)"
	@echo "  preflight    bats — preflight.sh against a Docker PostgreSQL container"
	@echo "  integration  Terratest Go — full apply against a Docker SSH target"
	@echo "  test         all three layers in sequence"
	@echo ""
	@echo "Setup:"
	@echo "  build-image      build the Docker image for integration tests"
	@echo "  tf-init          terraform init in modules/postgres"
	@echo "  tf-init-preflight  terraform init in the preflight render fixture"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean        remove .terraform caches and Terraform state from test fixtures"
	@echo "  clean-intg   remove only the integration Docker container and temp state files"

# ---------------------------------------------------------------------------
# Layer 1 — terraform test (unit)
# ---------------------------------------------------------------------------

tf-init:
	terraform -chdir=$(MODULE_DIR) init -reconfigure

unit: tf-init
ifdef UNIT_FILTER
	terraform -chdir=$(MODULE_DIR) test -test-directory=tests/unit -filter=$(UNIT_FILTER)
else
	terraform -chdir=$(MODULE_DIR) test -test-directory=tests/unit
endif

# ---------------------------------------------------------------------------
# Layer 2 — bats (preflight)
# ---------------------------------------------------------------------------

tf-init-preflight:
	terraform -chdir=$(MODULE_DIR)/tests/preflight init -reconfigure

preflight: tf-init-preflight
	bats $(MODULE_DIR)/tests/preflight/preflight.bats

# ---------------------------------------------------------------------------
# Layer 3 — Terratest (integration)
# ---------------------------------------------------------------------------

build-image:
	docker build -t $(INTG_IMAGE) $(INTG_DIR)

integration: build-image
	cd $(INTG_DIR) && go test -v -timeout 20m -run TestPostgresModule

# ---------------------------------------------------------------------------
# Run all layers
# ---------------------------------------------------------------------------

test: unit preflight integration

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean:
	rm -rf $(MODULE_DIR)/.terraform $(MODULE_DIR)/.terraform.lock.hcl
	rm -rf $(MODULE_DIR)/tests/preflight/.terraform \
	       $(MODULE_DIR)/tests/preflight/.terraform.lock.hcl \
	       $(MODULE_DIR)/tests/preflight/terraform.tfstate \
	       $(MODULE_DIR)/tests/preflight/terraform.tfstate.backup
	rm -rf $(INTG_DIR)/fixtures/.terraform \
	       $(INTG_DIR)/fixtures/.terraform.lock.hcl

clean-intg:
	docker rm -f pg_integration_test 2>/dev/null || true
	rm -f /tmp/tf-pg-integration-*.tfstate
