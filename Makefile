PREFIX ?= $(HOME)/.local
BIN    := $(PREFIX)/bin

.PHONY: all build release test install uninstall demo clean

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift run mytight-selftest

install: release
	@mkdir -p $(BIN)
	install -m 755 .build/release/mytight $(BIN)/mytight
	install -m 755 .build/release/mytight-selftest $(BIN)/mytight-selftest
	@echo "installed to $(BIN)/mytight"
	@case ":$$PATH:" in *":$(BIN):"*) ;; \
	  *) echo "note: $(BIN) is not on your PATH";; esac

uninstall:
	rm -f $(BIN)/mytight $(BIN)/mytight-selftest

# Local RFB server for exercising the client without a VM.
demo: release
	.build/release/mytight-selftest --serve 5999

clean:
	swift package clean
	rm -rf .build
