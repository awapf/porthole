import Foundation
import PortholeCore

/// The stuck-key failures are all bookkeeping errors, and each one showed up
/// in practice as a screen full of repeated characters.
func runKeyboardTests(_ h: Harness) {
    print("keyboard")

    h.test("a press and release is one down and one up") {
        var keyboard = KeyboardTracker()
        try h.expectEqual(keyboard.press(keyCode: 8, keysym: 0x63),
                          [KeyAction(keysym: 0x63, down: true)])
        try h.expectEqual(keyboard.release(keyCode: 8, fallbackKeysym: 0x63),
                          [KeyAction(keysym: 0x63, down: false)])
        try h.expectEqual(keyboard.heldCount, 0)
    }

    h.test("releasing Command releases everything still held") {
        // The Cmd-C case: macOS swallows the key-up for 'c', so without this
        // the remote keeps repeating the letter forever.
        var keyboard = KeyboardTracker()
        _ = keyboard.press(keyCode: 8, keysym: 0x63)
        try h.expect(keyboard.isHeld(8), "'c' should be held")
        let released = keyboard.releaseAll()
        try h.expectEqual(released, [KeyAction(keysym: 0x63, down: false)])
        try h.expectEqual(keyboard.heldCount, 0, "nothing may remain held")
    }

    h.test("pressing a key twice without a release does not latch it") {
        // The Cmd-1 case: a second press with no intervening up made sway
        // ignore it, so the workspace switch silently did nothing.
        var keyboard = KeyboardTracker()
        _ = keyboard.press(keyCode: 18, keysym: 0x31)
        let again = keyboard.press(keyCode: 18, keysym: 0x21)
        try h.expectEqual(again, [KeyAction(keysym: 0x31, down: false),
                                  KeyAction(keysym: 0x21, down: true)],
                          "the stale keysym must be released first")
    }

    h.test("release is keyed on the physical key, not the current keysym") {
        // Shift released before the letter: the up must carry the keysym that
        // went down, or the remote strands the shifted one.
        var keyboard = KeyboardTracker()
        _ = keyboard.press(keyCode: 1, keysym: 0x53)          // 'S' with shift
        let up = keyboard.release(keyCode: 1, fallbackKeysym: 0x73)   // now 's'
        try h.expectEqual(up, [KeyAction(keysym: 0x53, down: false)],
                          "must release 'S', the keysym actually pressed")
    }

    h.test("an unknown release falls back rather than being dropped") {
        var keyboard = KeyboardTracker()
        try h.expectEqual(keyboard.release(keyCode: 99, fallbackKeysym: 0x61),
                          [KeyAction(keysym: 0x61, down: false)])
        try h.expectEqual(keyboard.release(keyCode: 99, fallbackKeysym: nil), [])
    }

    h.test("releaseAll covers every held key") {
        var keyboard = KeyboardTracker()
        for (code, sym) in [(UInt16(1), UInt32(0x61)), (2, 0x62), (3, 0x63)] {
            _ = keyboard.press(keyCode: code, keysym: sym)
        }
        let released = keyboard.releaseAll()
        try h.expectEqual(released.count, 3)
        try h.expect(released.allSatisfy { !$0.down }, "all must be releases")
        try h.expectEqual(Set(released.map(\.keysym)), Set([0x61, 0x62, 0x63]))
    }
}
