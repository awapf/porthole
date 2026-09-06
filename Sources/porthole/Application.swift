import AppKit

/// NSApplication subclass that rescues key-up events.
///
/// AppKit does not deliver `keyUp:` to the first responder while the Command
/// key is held — the event is consumed by menu-equivalent handling. For a
/// remote desktop that is fatal: the remote sees the key press, never sees the
/// release, and its own auto-repeat runs forever. Pressing Cmd-C once produced
/// an unbroken stream of 'c'.
///
/// Intercepting here rather than in the view means normal press-and-hold
/// repeat still works, instead of having to fake a release on press.
final class PortholeApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyUp,
           event.modifierFlags.contains(.command),
           let responder = keyWindow?.firstResponder as? VNCView {
            responder.keyUp(with: event)
            return
        }
        super.sendEvent(event)
    }
}
