PREFIX    ?= $(HOME)/.local
BIN       := $(PREFIX)/bin
BUNDLE_ID := ch.awapf.porthole

.PHONY: all build release test install uninstall demo clean version tag

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

version:
	@grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' Sources/PortholeCore/Version.swift | tr -d '"'

# make tag VERSION=0.2.0 — updates the checked-in version, commits, tags and
# pushes. The constant and the tag must agree: Homebrew builds from a release
# tarball, which carries no git metadata to derive a version from.
tag:
	@test -n "$(VERSION)" || { echo "usage: make tag VERSION=x.y.z"; exit 1; }
	@echo "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "VERSION must be x.y.z"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "working tree is dirty"; exit 1; }
	sed -i '' 's/public static let version = "[^"]*"/public static let version = "$(VERSION)"/' Sources/PortholeCore/Version.swift
	swift build -c release
	./.build/release/porthole --version
	git add Sources/PortholeCore/Version.swift
	git commit -m "Release v$(VERSION)"
	git tag -a "v$(VERSION)" -m "porthole v$(VERSION)"
	git push origin main
	git push origin "v$(VERSION)"
	@echo
	@echo "tagged v$(VERSION). Now refresh the formula:"
	@echo "  make formula VERSION=$(VERSION)"

# Rewrites HomebrewFormula/porthole.rb for a tag that is already pushed.
formula:
	@test -n "$(VERSION)" || { echo "usage: make formula VERSION=x.y.z"; exit 1; }
	@url="https://github.com/awapf/porthole/archive/refs/tags/v$(VERSION).tar.gz"; \
	echo "fetching $$url"; \
	sha=$$(curl -fsSL "$$url" | shasum -a 256 | cut -d" " -f1); \
	test -n "$$sha" || { echo "could not fetch the tarball — is the tag pushed?"; exit 1; }; \
	sed -i '' -e "s|/v[0-9]*\.[0-9]*\.[0-9]*\.tar\.gz|/v$(VERSION).tar.gz|" \
	          -e "s|sha256 \"[0-9a-f]*\"|sha256 \"$$sha\"|" \
	          -e "s|version \"[0-9]*\.[0-9]*\.[0-9]*\"|version \"$(VERSION)\"|" \
	          HomebrewFormula/porthole.rb; \
	echo "sha256 $$sha"
	@grep -E "url|sha256|version " HomebrewFormula/porthole.rb
