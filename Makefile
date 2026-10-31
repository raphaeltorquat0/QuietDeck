# QuietDeck — `make install` é o único comando necessário no dia a dia.
APP_NAME := QuietDeck
DEST     := /Applications/$(APP_NAME).app
DEV_DD   := .build/xcode-debug
# `archlinux` só existe em amd64, e o sshd não roda emulado num Mac ARM (DECISIONS.md #8).
HARNESS_BASE := $(if $(filter arm64 aarch64,$(shell uname -m)),menci/archlinuxarm:base,archlinux:latest)

.DEFAULT_GOAL := help
.PHONY: help install dev test harness integration release

help: ## Lista os alvos
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

install: ## Compila em Release, assina ad-hoc, instala em /Applications e abre o app
	scripts/build-app.sh
	@pkill -x $(APP_NAME) 2>/dev/null; true
	rm -rf "$(DEST)"
	ditto dist/$(APP_NAME).app "$(DEST)"
	open "$(DEST)"

dev: ## Compila em Debug e roda o app no terminal (logs aqui; Ctrl-C para sair)
	@command -v xcodegen >/dev/null && xcodegen generate --quiet || true
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Debug \
	  -derivedDataPath $(DEV_DD) build -quiet
	$(DEV_DD)/Build/Products/Debug/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)

test: ## Roda os testes unitários e os de replay (sem Docker)
	swift test

harness: ## Sobe o Deck simulado em 127.0.0.1:2222 (Docker)
	docker build --build-arg BASE=$(HARNESS_BASE) -t quietdeck-harness Harness
	-docker rm -f quietdeck-sim
	docker run -d --name quietdeck-sim -p 127.0.0.1:2222:22 quietdeck-harness
	@for i in $$(seq 1 60); do docker exec quietdeck-sim pgrep -x sshd >/dev/null 2>&1 && exit 0; sleep 0.5; done; echo 'sshd não subiu' >&2; exit 1

integration: harness ## Roda os testes de integração contra o Deck simulado
	QUIETDECK_TEST_HOST=127.0.0.1 QUIETDECK_TEST_PORT=2222 QUIETDECK_TEST_PASSWORD=deck-password \
	  QUIETDECK_TEST_CONTAINER=quietdeck-sim swift test --filter Integration --no-parallel

release: ## Build Release universal e .dmg ad-hoc em dist/
	scripts/release.sh
