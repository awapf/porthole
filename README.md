# porthole

A native macOS VNC client built for **wayvnc + sway** on a Proxmox VM, reachable
over **SSH** or **NetBird**.

You type one destination. It opens an SSH connection, starts the remote desktop
if it isn't running, forwards the port, and drops you into a full-screen native
window already resized to your Mac's display.

```
porthole aw@10.10.0.5
```

There is no viewer app to install, no bundled Java, and no X11. The RFB client,
the Tight/ZRLE decoders and the Metal renderer are all in this binary.

---

## Why not TightVNC

TightVNC's *server* has been Windows-only for years. On Linux the lineage lives
on as **TigerVNC** (`Xvnc`) and, for Wayland, **wayvnc** — which is what sway
needs. What actually matters from TightVNC is the **Tight encoding**, and
wayvnc speaks it. `porthole` implements Tight (fill, JPEG, and the basic
copy/palette/gradient filters), ZRLE/TRLE, Raw and CopyRect, so it also works
against TigerVNC and x11vnc unchanged.

## What it does

| | |
|---|---|
| **One destination** | `porthole aw@vm` — SSH, remote launch, tunnel, window. |
| **Starts the server** | Detects a running Wayland session; starts headless sway if there isn't one; starts wayvnc; reuses one that is already serving. |
| **Matches your display** | Sends `SetDesktopSize` with your Mac's real backing resolution and sets sway's `output scale`, so the remote is pixel-sharp rather than upscaled. |
| **Native rendering** | Dirty rectangles upload straight into one BGRA Metal texture. Remote pixels are never repacked between the socket and the screen. |
| **Instant full screen** | A borderless window over the display, not a macOS Space — no transition animation on entry or exit. |
| **Real keyboard** | Command maps to **Super** by default, so sway's `$mod` bindings sit under your thumb. Modifiers are released on focus loss so nothing latches. |
| **Keyboard grab** | Click into the window and ⌘Tab, ⌘Space and ⌘Q go to the remote instead of macOS. ^⌥⌘G hands the keyboard back, and losing focus releases it automatically. |
| **Clipboard both ways** | Full UTF-8 via the extended clipboard — accents, dashes, CJK and emoji all survive. Falls back to Latin-1 only if the server has no extension. |
| **Auto-reconnect** | A dropped link retries with backoff, restarting the remote server if it died. Survives laptop sleep. |
| **Live resize** | Resizing the window reshapes the remote desktop to match, debounced. |
| **Remote cursor** | Drawn locally from the `Cursor` pseudo-encoding, so the pointer has no round-trip lag. |

## Install

Requires macOS 14+ and the Swift toolchain that ships with Command Line Tools
(`xcode-select --install`). Full Xcode is **not** needed.

```bash
git clone <this repo> porthole && cd porthole
make install          # builds release, installs to ~/.local/bin
```

Or by hand:

```bash
swift build -c release
cp .build/release/porthole /usr/local/bin/
```

## Remote setup

On the VM you need `wayvnc`, and `sway` if you want porthole to bring up a
desktop that isn't already running.

```bash
# Debian/Ubuntu
sudo apt install wayvnc sway
# Arch
sudo pacman -S wayvnc sway
```

Nothing else. porthole starts them over SSH, binding wayvnc to `127.0.0.1` so it
is reachable only through the tunnel.

For a persistent desktop that survives disconnects, run sway yourself (a
systemd user unit is ideal) and porthole will attach to it instead of starting
its own.

## Usage

```bash
porthole aw@10.10.0.5              # SSH: start the desktop, tunnel, full screen
porthole aw@10.10.0.5 --window     # windowed
porthole vm                        # a host saved in the config file

porthole --direct 100.64.0.5:5900  # straight to a listening server, no SSH
porthole aw@100.64.0.5 --direct-vnc  # SSH starts it; pixels go direct
```

### Resolution

The default, `--res auto`, asks the compositor for your Mac's full **backing**
resolution and sets sway's output scale to match — a 1:1 pixel map with no
resampling anywhere. On a 15" MacBook Air that is 3420×2224 at scale 2.

```bash
porthole vm --res auto        # backing pixels + scale 2 (default, sharpest)
porthole vm --res 1x          # logical points, a quarter of the pixels
porthole vm --res 2560x1440   # explicit
porthole vm --res keep        # leave the remote alone
porthole vm --scale 0         # do not touch sway's output scale
```

`--res auto` is the sharp option but the expensive one: it is four times the
pixels of `--res 1x`. sway is cheap to render and wayvnc only sends damage, so
an idle desktop costs almost nothing either way — but on a constrained link, or
a VM without much CPU, `--res 1x` is the one that feels better.

### When a session looks wrong

`--dump-frame` connects, decodes, writes the framebuffer to a PNG and exits
without opening a window. It reports how much of the buffer is non-black and how
many distinct colours it holds, which separates "the server sent nothing" from
"we failed to draw it":

```bash
porthole office-aw-6 --dump-frame /tmp/remote.png -v
# framebuffer 3420x2224 — 99.99% non-black, 63104 distinct colours, 5 frames
```

### Tuning a slow link

```bash
porthole vm --no-reconnect    # exit on a dropped link instead of retrying
porthole vm --no-live-resize  # keep the remote size fixed while resizing
porthole vm --quality 5       # more JPEG compression (0-9, default 8)
porthole vm --compress 9      # more zlib effort, less bandwidth
porthole vm --lossless        # no JPEG at all; crisp text, more bytes
porthole vm -v                # log bytes/s and ms/frame every 2 seconds
```

Press **⌃⌥⌘I** in-session for the same numbers as an overlay.

### Keys

Command becomes **Super**, so `$mod+Return`, `$mod+1` and the rest work as they
do on the VM. Change it with `--cmd-key ctrl` or `--cmd-key alt`.

Because Command is forwarded, the client's own controls sit on a chord sway
will not claim:

| | |
|---|---|
| **⌃⌥⌘F** | toggle full screen |
| **⌃⌥⌘I** | stats overlay |
| **⌃⌥⌘R** | re-send the resolution request |
| **⌃⌥⌘G** | release the keyboard grab |
| **⌃⌥⌘Q** | disconnect |

### Saved hosts

```bash
porthole --init-config       # writes ~/.config/porthole/config.json
```

```json
{
  "hosts": {
    "vm": {
      "destination": "aw@10.10.0.5",
      "resolution": "auto",
      "swayScale": 2,
      "commandKey": "super"
    }
  }
}
```

Then `porthole vm`. Command-line flags override the file.

## Keyboard grab

Clicking into the session captures the keyboard, so the chords macOS normally
keeps for itself — ⌘Tab, ⌘Space, ⌘Q — reach sway instead. The blue badge at the
top of the window shows when it is active, along with the way out.

It needs Accessibility permission, which macOS asks for the first time the grab
engages. Grant it, then relaunch: macOS only re-reads the decision at launch.
`make install` signs the binary with a stable identifier so the grant survives
reinstalls. `--no-grab` switches the feature off entirely.

The grab is built to be impossible to get stuck in:

- **⌃⌥⌘G** is checked before anything is forwarded and is never swallowed.
- Losing focus by any means — another window, Mission Control, anything —
  releases it.
- Events only get consumed while grabbed *and* porthole is frontmost;
  otherwise they pass through untouched.
- macOS disables an event tap that responds too slowly. That is detected and
  the tap re-armed, so a grab cannot silently keep eating the keyboard.

## Security

**The RFB session itself is not encrypted.** porthole relies on the transport
underneath it, and defaults to the arrangement that makes that safe:

- **Default (SSH).** wayvnc is bound to `127.0.0.1` on the VM and reached
  through an SSH port forward. Nothing touches the network in the clear, and
  authentication is your existing SSH key.
- **`--direct-vnc` / `--direct` on NetBird.** WireGuard already provides modern
  authenticated encryption and NetBird restricts who can reach the peer. This
  skips a hop of latency. Only use it on the mesh. `--direct-vnc` binds wayvnc
  to the exact address you connected to, not `0.0.0.0`, so the VM's other
  interfaces are not served.
- **`--direct` on an untrusted network.** Don't. Use the SSH default.

`--password` uses classic VNC DES auth, which is weak on its own — it exists for
servers that demand it, not as a substitute for the tunnel.

wayvnc also supports **RSA-AES** (types 5/129), which would encrypt RFB itself
and remove the reliance on the transport. It is not implemented here yet: it
needs AES-EAX, which CryptoKit does not expose, so it wants a hand-written
CMAC/CTR layer. `RFBClient.authenticate()` is where it would slot in.

## Testing

```bash
swift run porthole-selftest
```

38 checks with no external dependencies, covering:

- DES against the FIPS-46 known-answer vector, and the bit-reversed VNC key
  mangling.
- Every Tight path — fill, JPEG, and basic compression with the copy, palette
  and gradient filters — round-tripped against synthetic server output.
- That the four Tight zlib streams keep their history across messages and stay
  independent of each other. This is the bug class that only shows up as
  corruption several frames in.
- Every ZRLE tile encoding, plus multi-tile raster order.
- A **full session over a real TCP socket** against a loopback RFB server:
  handshake, auth, framing, the `SetDesktopSize` round trip, input, clipboard,
  and the continuous-updates fallback.
- **Offscreen Metal renders** read back pixel by pixel, checking orientation,
  forced-opaque alpha, letterboxing, and that dirty rects upload only what they
  claim.

There is also a demo server, so the window and input can be exercised with no VM:

```bash
porthole-selftest --serve 5999
porthole --direct 127.0.0.1:5999 --window
```

The suite is a plain executable rather than a test target because Command Line
Tools ships neither a usable XCTest nor a complete swift-testing.

## Layout

```
Sources/PortholeCore/         no AppKit — usable headless
  Socket.swift               ByteSource/ByteSink, buffered exact-length reads
  RFBClient.swift            handshake, message loop, pseudo-encodings
  TightDecoder.swift         fill / JPEG / copy / palette / gradient
  ZRLEDecoder.swift          ZRLE and TRLE tiles
  Framebuffer.swift          BGRA pixels, overlap-safe CopyRect
  FramebufferRenderer.swift  Metal upload + draw, renderable offscreen
  SSHSession.swift           one multiplexed connection for everything
  RemoteDesktop.swift        probe, start sway/wayvnc, set output scale
  Keysym.swift               macOS key codes to X11 keysyms
Sources/porthole/             AppKit shell
Sources/porthole-selftest/    suite + loopback and demo servers
```

## Known gaps

- **RSA-AES auth** is not implemented (see Security above).
- **Keyboard scancodes** (QEMU extended key events) are not sent; keysyms are
  used instead, which can mis-map on non-US layouts.
- **Audio and file transfer** are out of scope: RFB has no channel for either.
  Use PipeWire and `sshfs`/`scp` over the same SSH connection.
- **open-h264** (encoding 50) is not implemented. wayvnc only offers it with
  VAAPI on the server, which a Proxmox VM without GPU passthrough will not have.
- **Multi-monitor** is single-screen only; `SetDesktopSize` sends one screen.
- **⌘Tab and ⌘Space** are intercepted by macOS before the app sees them.
  Capturing them needs a `CGEventTap` and an Accessibility permission prompt.
- **Audio** is out of scope; use PipeWire over the SSH connection if you need it.

## License

MIT — see [LICENSE](LICENSE).

All code here is first-party, and the only libraries linked are `zlib` and
Apple's own frameworks. [neatvnc](https://github.com/any1/neatvnc) and
[wayvnc](https://github.com/any1/wayvnc) (both ISC) were read to understand
the wire protocol and its quirks, but no code was taken from them.
