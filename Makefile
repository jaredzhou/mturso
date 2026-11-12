MOON ?= moon
TURSODB_VERSION ?= 0.8.2
TURSODB_CACHE ?= $(CURDIR)/.cache/tursodb/$(TURSODB_VERSION)
ifeq ($(OS),Windows_NT)
TURSODB_EXE := tursodb.exe
else
TURSODB_EXE := tursodb
endif
TURSODB ?= $(TURSODB_CACHE)/$(TURSODB_EXE)
SYNC_DB ?= .cache/turso-sync-server.db
SYNC_ADDR ?= 127.0.0.1:8080

.PHONY: check test download-cli test-server server server-wrapper fmt

check:
	$(MOON) check --target native --deny-warn

test:
	$(MOON) test --target native --deny-warn

download-cli:
	bash scripts/fetch-tursodb-cli.sh

test-server: download-cli
	TURSODB="$(TURSODB)" $(MOON) test --target native --deny-warn cmd/server/lib

server: download-cli
	mkdir -p "$(dir $(SYNC_DB))"
	"$(TURSODB)" "$(SYNC_DB)" --sync-server "$(SYNC_ADDR)"

server-wrapper: download-cli
	mkdir -p "$(dir $(SYNC_DB))"
	TURSODB="$(TURSODB)" $(MOON) run cmd/server --target native -- "$(SYNC_DB)" "$(SYNC_ADDR)"

fmt:
	$(MOON) fmt --warn
