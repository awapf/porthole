# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`porthole` is a native macOS VNC client for **wayvnc + sway**, reached over SSH or
directly. It is a single Swift package with no third-party dependencies — only
`zlib` and Apple frameworks. The RFB client, the Tight/ZRLE decoders and the Metal
renderer are all first-party code in this repo.

README.md is thorough and user-facing: flags, config file, keys, security model,
interoperability notes and known gaps. Read it before changing behaviour rather
than re-deriving it here.

## Commands

```bash
make build          # swift build (debug)
make release        # swift build -c release
make test           # swift run porthole-selftest — 55 checks, ~1s
make install        # release + install to ~/.local/bin + codesign
make demo           # local RFB server on :5999, exercised without a VM
make clean          # swift package clean && rm -rf .build
```

Release flow (see Makefile for details):

```bash
make tag VERSION=x.y.z      # bump Version.swift, commit, tag, push
make formula VERSION=x.y.z  # fetch the tarball, rewrite url + sha256
```

### Running a subset of tests

The suite has **no name filter**. `Sources/porthole-selftest/main.swift` runs its
inline checks and then calls `runKeyboardTests`, `runDecoderTests`,
`runSessionTests`, `runRenderTests` unconditionally. To narrow, comment out the
group calls at the bottom of `main.swift`. The whole suite is about a second, so
this is rarely worth it — prefer running all of it.

### Exercising the client without a VM

```bash
make demo                                  # terminal 1
porthole --direct 127.0.0.1:5999 --window  # terminal 2
```

Headless diagnostics that need neither a window nor Metal:

```bash
porthole <dest> --dump-frame /tmp/f.png -v  # decode, write PNG, report coverage, exit
porthole <dest> --test-input                # send input from a headless client, exit
```

## Testing conventions

The suite is a plain **executable target**, not an XCTest/swift-testing target,
because Command Line Tools ships neither usably — the constraint is deliberate so
the suite runs on any machine that can build the client. `Harness` in
`Sources/porthole-selftest/Harness.swift` is the whole framework: `h.test`,
`h.expect`, `h.expectEqual`.

Two seams make otherwise-untestable things testable, and new tests should use them
rather than mocking:

- `LoopbackServer` is a **real RFB server on a real TCP socket** that shares no
  code with the client, so the two must agree on the wire format rather than on a
  shared helper. Do not refactor toward shared encoding helpers.
- `RenderChecks` renders **offscreen with Metal and reads pixels back**, so
  orientation, alpha and letterboxing are checked without a display.

## Architecture

Three targets, layered so the protocol is usable headless:

- **`PortholeCore`** — no AppKit. Transport, RFB protocol, decoders, framebuffer,
  Metal renderer, SSH, remote launch, keysym mapping, config.
- **`porthole`** — the AppKit shell: `AppDelegate` orchestrates, `VNCView` renders
  and forwards input, `KeyboardGrab` runs the event tap.
- **`porthole-selftest`** — the suite plus the loopback and demo servers.

### Bringing a session up

`AppDelegate.establish()` runs off the main queue: `SSHSession` opens **one
multiplexed master connection** (ControlMaster) that probing, launching and
tunnelling all ride, so connecting costs a single handshake. `RemoteDesktop`
probes the far end, starts headless sway and/or wayvnc if needed or reuses a
running one, and sets sway's `output scale`. Then a local port forward, a
`Socket`, and an `RFBClient`.

### Threading contract

`RFBClient.start()` spawns a **`Thread` running a blocking read loop**. Every
`RFBClientDelegate` callback is hopped to the main queue by the client's own
`dispatch` helper before it fires, because delegates touch AppKit. Keep that
invariant: emit delegate calls through `dispatch`, never directly from the read
loop.

The blocking, exact-length reads in `BufferedReader` are what keep the protocol
parser linear and free of continuation plumbing. `ByteSource`/`ByteSink` are the
abstraction the tests substitute at.

### Rendering

Dirty rectangles upload straight into one BGRA Metal texture that a fullscreen
triangle samples — remote pixels are never repacked between the socket and the
screen. `VNCView` coalesces rects and presents on a `CADisplayLink`.

## Invariants that are easy to break

These each cost real debugging time and have regression tests. Changing the code
they guard without reading the tests will reintroduce them.

- **AppKit withholds `keyUp:` while Command is held.** `PortholeApplication`
  (an `NSApplication` subclass) intercepts `sendEvent` to route those releases to
  `VNCView`. Without it the remote never sees the release and its auto-repeat
  floods the screen — pressing ⌘C produced an unbroken stream of `c`.
  `KeyboardTracker` holds the press bookkeeping, deliberately outside the view so
  it is directly testable, and releases by **physical key code**, not keysym.
- **An incremental update request while continuous updates are enabled wedges
  neatvnc/wayvnc permanently** — silently, since video keeps flowing while input
  dies. Continuous updates are off by default and the client must never be able
  to produce the combination.
- **`ExtendedDesktopSize` status 4 is an acceptance** (`REQUEST_FORWARDED`), not a
  refusal, and the rectangle still carries the *old* dimensions.
- **Tight's four zlib streams must keep their history across messages and stay
  independent of each other.** Breaking this shows up as corruption several
  frames in, not immediately.
- **The keyboard grab must be impossible to get stuck in.** The ⌃⌥⌘G release
  chord is checked before anything is forwarded and never swallowed; focus loss
  releases; events only get consumed while grabbed *and* frontmost; a tap macOS
  disabled for slowness is detected and re-armed.
- **The version is a checked-in constant** in `Sources/PortholeCore/Version.swift`,
  not derived from git, because Homebrew builds from a tarball with no git
  metadata. It and the tag must agree — use `make tag`.
- **The codesign identifier `ch.awapf.porthole` must stay stable** across
  `make install` and the Homebrew formula, or macOS drops the Accessibility grant
  that the keyboard grab needs.
- **Once the framebuffer is live, progress messages must not repaint the status
  overlay** (`AppDelegate.isLive`) — it is opaque and would hide the session.

## Gotchas

- The `.build` module cache bakes in absolute paths. If the repo directory is
  moved or renamed, builds fail with *"missing required module 'SwiftShims'"* —
  `rm -rf .build` fixes it.
- Command-line flags override the config file: `Options.parse` tracks which flags
  were given explicitly and applies `defaults` then the named host entry only for
  the ones that were not.
- `swiftLanguageMode(.v5)` is set on every target. Swift 6 strict concurrency is
  not in force; do not assume it.
