BIN     := bin/gsa
PKG     := ./cmd/gsa
GOFILES := $(shell find cmd internal -name '*.go' 2>/dev/null)

.PHONY: all build fmt vet test clean check

all: build

## Build the gsa terminal app. Run this on the server after `git pull`.
build: $(BIN)

$(BIN): $(GOFILES) go.mod go.sum
	@mkdir -p bin
	CGO_ENABLED=0 go build -trimpath -o $(BIN) $(PKG)
	@echo "built $(BIN)"

fmt:
	gofmt -w cmd internal

vet:
	go vet ./...

test:
	go test ./...

## Everything CI-ish we can run locally, including the existing bash checks.
check: vet test
	@test -z "$$(gofmt -l cmd internal)" || { echo "gofmt needed:"; gofmt -l cmd internal; exit 1; }
	bash -n scripts/core/server-manager.sh
	find games/ -name '*.json' -exec jq empty {} \;

clean:
	rm -rf bin
