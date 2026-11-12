MOON ?= moon
TURSODB_VERSION ?= 0.8.2
TURSODB_CACHE ?= $(CURDIR)/.cache/tursodb/$(TURSODB_VERSION)
ifeq ($(OS),Windows_NT)
TURSODB_EXE := tursodb.exe
GIT_EXE := $(strip $(shell where git 2>NUL))
GIT_BASH ?= $(subst \,/,$(patsubst %\cmd\git.exe,%,$(GIT_EXE)))/bin/bash.exe
RUN_SHELL := "$(GIT_BASH)" -c
else
TURSODB_EXE := tursodb
RUN_SHELL := sh -c
endif
TURSODB ?= $(TURSODB_CACHE)/$(TURSODB_EXE)
SYNC_DB ?= .cache/turso-sync-server.db
SYNC_ADDR ?= 127.0.0.1:8080
NATIVE_SERVER ?= $(CURDIR)/_build/native/debug/build/cmd/native-server/native-server$(if $(filter Windows_NT,$(OS)),.exe,)

.PHONY: check test download-cli native-server native-server-run test-server server server-wrapper fmt

check:
	$(RUN_SHELL) '$(MOON) check --target native --deny-warn'

test:
	$(RUN_SHELL) '$(MOON) test --target native --deny-warn'

download-cli:
	$(RUN_SHELL) 'bash scripts/fetch-tursodb-cli.sh'

native-server:
	$(RUN_SHELL) '$(MOON) build cmd/native-server --target native'

native-server-run: native-server
	$(RUN_SHELL) 'mkdir -p "$(dir $(SYNC_DB))" && "$(NATIVE_SERVER)" "$(SYNC_DB)" "$(SYNC_ADDR)"'

test-server: download-cli native-server
	$(RUN_SHELL) 'TURSODB="$(TURSODB)" MTURSO_NATIVE_SERVER="$(NATIVE_SERVER)" $(MOON) test --target native --deny-warn server'

server: download-cli
	$(RUN_SHELL) 'mkdir -p "$(dir $(SYNC_DB))" && "$(TURSODB)" "$(SYNC_DB)" --sync-server "$(SYNC_ADDR)"'

server-wrapper: download-cli
	$(RUN_SHELL) 'mkdir -p "$(dir $(SYNC_DB))" && TURSODB="$(TURSODB)" $(MOON) run cmd/server --target native -- "$(SYNC_DB)" "$(SYNC_ADDR)"'

fmt:
	$(RUN_SHELL) '$(MOON) fmt --warn'
