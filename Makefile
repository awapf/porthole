PREFIX    ?= $(HOME)/.local
BIN       := $(PREFIX)/bin
BUNDLE_ID := ch.awapf.porthole

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
	@# A stable signing identifier gives macOS something consistent to attach
	@# the Accessibility grant to, so the keyboard grab survives reinstalls.
	@codesign --force --sign - --identifier $(BUNDLE_ID) $(BIN)/porthole
	@echo "installed to $(BIN)/porthole (signed as $(BUNDLE_ID))"
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
