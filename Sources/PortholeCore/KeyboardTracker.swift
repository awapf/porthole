import Foundation

/// One key transition to send to the server.
public struct KeyAction: Equatable {
    public let keysym: UInt32
    public let down: Bool
    public init(keysym: UInt32, down: Bool) {
        self.keysym = keysym
        self.down = down
    }
}

/// Tracks which keys the remote believes are held.
///
/// This exists as its own type because the failure it guards against is
/// invisible until it bites: macOS does not deliver `keyUp:` while Command is
/// held, so a chord like Cmd-C leaves the letter pressed forever and the
/// remote's auto-repeat floods the screen. Keeping the bookkeeping out of the
/// AppKit view makes it directly testable.
public struct KeyboardTracker {
    private var pressed: [UInt16: UInt32] = [:]

    public init() {}

    public var heldCount: Int { pressed.count }
    public func isHeld(_ keyCode: UInt16) -> Bool { pressed[keyCode] != nil }

    /// Presses a key. If that physical key is already believed to be held with
    /// a different keysym, its release is emitted first so nothing latches.
    public mutating func press(keyCode: UInt16, keysym: UInt32) -> [KeyAction] {
        var actions: [KeyAction] = []
        if let stale = pressed[keyCode], stale != keysym {
            actions.append(KeyAction(keysym: stale, down: false))
        }
        pressed[keyCode] = keysym
        actions.append(KeyAction(keysym: keysym, down: true))
        return actions
    }

    /// Releases by physical key, so releasing Shift before a letter cannot
    /// strand the letter under a different keysym.
    public mutating func release(keyCode: UInt16, fallbackKeysym: UInt32?) -> [KeyAction] {
        if let keysym = pressed.removeValue(forKey: keyCode) {
            return [KeyAction(keysym: keysym, down: false)]
        }
        guard let fallback = fallbackKeysym else { return [] }
        return [KeyAction(keysym: fallback, down: false)]
    }

    /// Releases every tracked key. Used when Command is released (macOS may
    /// have swallowed the real key-ups) and when the window loses focus.
    public mutating func releaseAll() -> [KeyAction] {
        let actions = pressed.values.map { KeyAction(keysym: $0, down: false) }
        pressed.removeAll()
        return actions
    }
}
