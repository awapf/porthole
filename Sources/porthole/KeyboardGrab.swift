import AppKit
import ApplicationServices

/// Captures the keys macOS would otherwise keep for itself.
///
/// Without this, Command-Tab, Command-Space, Command-Q and the rest are
/// consumed by macOS before the app ever sees them, so the remote desktop can
/// never feel like a real machine. A session-level `CGEventTap` sees them
/// first, and returning nil from the callback swallows them.
///
/// Two safety properties matter more than the feature itself:
///
/// - The release chord is checked before anything is forwarded, and is never
///   swallowed, so there is always a way out.
/// - The tap only consumes while grabbed *and* this app is frontmost. macOS
///   disables a tap that blocks for too long; that is detected and re-armed,
///   because a dead tap would otherwise silently eat the keyboard.
final class KeyboardGrab {
    /// Called with each captured event; returns true if it was consumed.
    var onEvent: ((NSEvent) -> Bool)?
    /// Checked before forwarding. Returning true releases the grab.
    var isReleaseChord: ((NSEvent) -> Bool)?
    var onStateChange: ((Bool) -> Void)?
    var logger: ((String) -> Void)?

    private(set) var isGrabbed = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether macOS has granted Accessibility rights, optionally prompting.
    static func hasPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func grab() -> Bool {
        guard !isGrabbed else { return true }
        guard Self.hasPermission(prompt: true) else {
            logger?("keyboard grab needs Accessibility permission")
            return false
        }
        guard installTap() else { return false }
        isGrabbed = true
        onStateChange?(true)
        logger?("keyboard grabbed")
        return true
    }

    func release() {
        guard isGrabbed else { return }
        isGrabbed = false
        removeTap()
        onStateChange?(false)
        logger?("keyboard released")
    }

    func toggle() -> Bool {
        if isGrabbed { release(); return false }
        return grab()
    }

    // MARK: - Tap plumbing

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let grab = Unmanaged<KeyboardGrab>.fromOpaque(refcon).takeUnretainedValue()
                return grab.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: context) else {
            logger?("could not create the event tap")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long to respond. Re-arm rather
        // than leaving a grab that silently stops working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            logger?("event tap was disabled by the system; re-enabled")
            return nil
        }
        guard isGrabbed, NSApp.isActive, let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        // Always checked first, and never swallowed on the way out.
        if isReleaseChord?(nsEvent) == true {
            release()
            return nil
        }
        return onEvent?(nsEvent) == true ? nil : Unmanaged.passUnretained(event)
    }

    deinit { removeTap() }
}
