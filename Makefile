# Makefile — Nextcloud SaaS Manager
# Alvos de teste via Bats

.PHONY: test test-unit test-integration test-e2e deps shellcheck

BATS      ?= bats
BATS_OPTS ?= --tap

# Instala bats-support e bats-assert em tests/lib/
deps:
	bash tests/install-deps.sh

test-unit:
	$(BATS) $(BATS_OPTS) --recursive tests/unit

test-integration:
	$(BATS) $(BATS_OPTS) --recursive tests/integration

test-e2e:
	$(BATS) $(BATS_OPTS) --recursive tests/e2e

# Roda sanity + unit + integration
test: deps
	$(BATS) $(BATS_OPTS) tests/sanity.bats
	@if [ -n "$$(find tests/unit -name '*.bats' 2>/dev/null)" ]; then \
	  $(BATS) $(BATS_OPTS) --recursive tests/unit; \
	fi
	@if [ -n "$$(find tests/integration -name '*.bats' 2>/dev/null)" ]; then \
	  $(BATS) $(BATS_OPTS) --recursive tests/integration; \
	fi

shellcheck:
	shellcheck --severity=warning --shell=bash --external-sources \
	  scripts/manage.sh \
	  scripts/deploy-server.sh \
	  $$(find scripts/lib -name '*.sh' 2>/dev/null) || true
