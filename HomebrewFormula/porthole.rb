class Porthole < Formula
  desc "Native macOS VNC client for wayvnc/sway over SSH or a direct VNC port"
  homepage "https://github.com/awapf/porthole"
  url "https://github.com/awapf/porthole/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "b4953a8bf80a2dbe5374137ea2a9eaad42cb338a82a53b388f96d434ffbc1944"
  license "MIT"
  version "0.1.1"

  # Metal and CADisplayLink APIs used here need Sonoma or later.
  depends_on macos: :sonoma
  # Deliberately no `depends_on xcode`: that requires a full Xcode install,
  # whereas this builds fine with the Swift toolchain in Command Line Tools.

  def install
    # --disable-sandbox: SwiftPM writes its build tree, which Homebrew's
    # sandbox otherwise blocks.
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/porthole"
    bin.install ".build/release/porthole-selftest"

    # A stable signing identifier gives macOS something consistent to attach
    # the Accessibility grant to, so the keyboard grab survives upgrades.
    system "codesign", "--force", "--sign", "-",
           "--identifier", "ch.awapf.porthole", bin/"porthole"
  end

  def caveats
    <<~EOS
      porthole needs `wayvnc` on the machine you connect to, and `sway` if you
      want it to start a desktop that is not already running:

        apt install wayvnc sway     # Debian/Ubuntu
        pacman -S wayvnc sway       # Arch

      The keyboard grab (⌘Tab, ⌘Space and friends going to the remote) needs
      Accessibility permission. macOS asks the first time it engages; grant it
      and relaunch. Use --no-grab to switch the feature off.
    EOS
  end

  test do
    assert_match "porthole #{version}", shell_output("#{bin}/porthole --version")
    assert_match "USAGE", shell_output("#{bin}/porthole --help")
    # The protocol suite is self-contained, so it doubles as an install check.
    assert_match "passed", shell_output("#{bin}/porthole-selftest")
  end
end
