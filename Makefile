PREFIX ?= $(HOME)/.local
BIN    := $(PREFIX)/bin

.PHONY: all build release test install uninstall demo clean

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift run porthole-selftest

install: release
	@mkdir -p $(BIN)
	install -m 755 .build/release/porthole $(BIN)/porthole
	install -m 755 .build/release/porthole-selftest $(BIN)/porthole-selftest
	@echo "installed to $(BIN)/porthole"
	@case ":$$PATH:" in *":$(BIN):"*) ;; \
	  *) echo "note: $(BIN) is not on your PATH";; esac

uninstall:
	rm -f $(BIN)/porthole $(BIN)/porthole-selftest

# Local RFB server for exercising the client without a VM.
demo: release
	.build/release/porthole-selftest --serve 5999

clean:
	swift package clean
	rm -rf .build
