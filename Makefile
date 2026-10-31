# QuietDeck — `make install` é o único comando necessário no dia a dia.
APP_NAME := QuietDeck
DEST     := /Applications/$(APP_NAME).app
DEV_DD   := .build/xcode-debug
# `archlinux` só existe em amd64, e o sshd não roda emulado num Mac ARM (DECISIONS.md #8).
HARNESS_BASE := $(if $(filter arm64 aarch64,$(shell uname -m)),menci/archlinuxarm:base,archlinux:latest)

.DEFAULT_GOAL := help
.PHONY: help install dev test harness shelf-harness shelf-mount integration release

help: ## Lista os alvos
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

install: ## Compila em Release, assina ad-hoc, instala em /Applications e abre o app
	scripts/build-app.sh
	@pkill -x $(APP_NAME) 2>/dev/null; true
	rm -rf "$(DEST)"
	ditto dist/$(APP_NAME).app "$(DEST)"
	open "$(DEST)"

dev: ## Compila em Debug e roda o app no terminal (logs aqui; Ctrl-C para sair)
	@command -v xcodegen >/dev/null && scripts/generate-project.sh || true
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Debug \
	  -derivedDataPath $(DEV_DD) build -quiet
	$(DEV_DD)/Build/Products/Debug/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)

test: ## Roda os testes unitários e os de replay (sem Docker)
	swift test

harness: ## Sobe o Deck simulado em 127.0.0.1:2222 (Docker)
	docker build --build-arg BASE=$(HARNESS_BASE) -t quietdeck-harness Harness
	-docker rm -f quietdeck-sim
	docker run -d --name quietdeck-sim -p 127.0.0.1:2222:22 -p 127.0.0.1:32000:32000 quietdeck-harness
	@for i in $$(seq 1 60); do docker exec quietdeck-sim pgrep -x sshd >/dev/null 2>&1 && exit 0; sleep 0.5; done; echo 'sshd não subiu' >&2; exit 1

shelf-harness: ## Sobe o servidor de acervo com SSH, SMB e o serviço da Estante (Docker)
	docker build --build-context service=Service/shelf -t quietdeck-shelf Harness/shelf
	-docker rm -f quietdeck-shelf
	-docker network create quietdeck-net
	-docker network connect quietdeck-net quietdeck-sim
	docker run -d --name quietdeck-shelf --network quietdeck-net -p 127.0.0.1:2223:22 -p 127.0.0.1:4445:445 -p 127.0.0.1:8766:8766 quietdeck-shelf

shelf-mount: ## Monta o compartilhamento SMB do servidor de acervo em /tmp/qd-smb
	mkdir -p /tmp/qd-smb
	-umount /tmp/qd-smb 2>/dev/null
	@for i in $$(seq 1 20); do mount_smbfs '//acervo:acervo-password@127.0.0.1:4445/acervo' /tmp/qd-smb && exit 0; sleep 0.5; done; exit 1

integration: harness shelf-harness shelf-mount ## Roda os testes de integração contra o Deck simulado
	QUIETDECK_TEST_SMB=/tmp/qd-smb QUIETDECK_TEST_HOST=127.0.0.1 QUIETDECK_TEST_PORT=2222 QUIETDECK_TEST_PASSWORD=deck-password \
	  QUIETDECK_TEST_CONTAINER=quietdeck-sim QUIETDECK_TEST_SHELF=1 swift test --filter Integration --no-parallel

release: ## Build Release universal e .dmg ad-hoc em dist/
	scripts/release.sh
