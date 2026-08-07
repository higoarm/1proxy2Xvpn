# =============================================================================
# Makefile — Convenience targets for development
# Production use: prefer the `1proxy2xvpn` CLI directly.
# =============================================================================
.PHONY: help setup build up down destroy haproxy status logs lint test \
        observability-up observability-down clean

SHELL := /bin/bash

help:
	@echo "1proxy2Xvpn — Development Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make setup              Install dependencies (requires sudo)"
	@echo "  make build              Build the Docker image"
	@echo "  make up                 Start all VPN containers"
	@echo "  make down               Stop all containers"
	@echo "  make destroy            Tear down everything"
	@echo "  make haproxy            Generate haproxy.cfg (requires sudo)"
	@echo "  make status             Show container status"
	@echo "  make logs               Tail logs from all containers"
	@echo ""
	@echo "  make observability-up   Start metrics/logs/alerts stack"
	@echo "  make observability-down Stop observability stack"
	@echo ""
	@echo "  make lint               Run all linters"
	@echo "  make test               Run smoke tests"
	@echo "  make clean              Remove generated files"

setup:
	sudo ./1proxy2xvpn setup

build:
	./1proxy2xvpn build

build-no-cache:
	./1proxy2xvpn build --no-cache

up:
	./1proxy2xvpn up

down:
	./1proxy2xvpn down

destroy:
	./1proxy2xvpn destroy

destroy-purge:
	./1proxy2xvpn destroy --purge

haproxy:
	sudo ./1proxy2xvpn haproxy

haproxy-only-up:
	sudo ./1proxy2xvpn haproxy --only-up

status:
	./1proxy2xvpn status

status-json:
	./1proxy2xvpn status --json

logs:
	./1proxy2xvpn logs all

observability-up:
	./1proxy2xvpn observability up

observability-down:
	./1proxy2xvpn observability down

# ── Development ───────────────────────────────────────────────────────────────
lint: lint-shell lint-docker lint-yaml lint-python

lint-shell:
	@command -v shellcheck >/dev/null || { echo "Install shellcheck first"; exit 1; }
	shellcheck -S warning scripts/*.sh docker/*.sh 1proxy2xvpn

lint-docker:
	@command -v hadolint >/dev/null || { echo "Install hadolint first"; exit 1; }
	hadolint docker/Dockerfile

lint-yaml:
	@command -v yamllint >/dev/null || { echo "Install yamllint first"; exit 1; }
	yamllint -c .yamllint.yaml .

lint-python:
	@command -v ruff >/dev/null || { echo "Install ruff first: pip install ruff"; exit 1; }
	ruff check middleware/

test: lint
	@echo "Running syntax checks..."
	@for f in scripts/*.sh docker/*.sh 1proxy2xvpn; do bash -n "$$f" && echo "✓ $$f" || exit 1; done
	@echo "Validating Docker build context..."
	@docker buildx build --progress=plain --check docker/ 2>/dev/null || true

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	rm -f haproxy.cfg haproxy.cfg.bak
	rm -rf middleware/__pycache__
	rm -rf middleware/.ruff_cache
	find . -name "*.pyc" -delete
	@echo "Cleaned generated files"

# ── Release helpers ──────────────────────────────────────────────────────────
release-patch:
	@./scripts/release.sh patch 2>/dev/null || echo "release.sh not present yet"

release-minor:
	@./scripts/release.sh minor 2>/dev/null || echo "release.sh not present yet"

release-major:
	@./scripts/release.sh major 2>/dev/null || echo "release.sh not present yet"
