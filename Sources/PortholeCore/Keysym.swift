import Foundation

/// X11 keysym values. wayvnc feeds these through `xkbcommon` to synthesise
/// Wayland key events, so getting them right is what makes the remote keyboard
/// behave like a local one.
public enum Keysym {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let ret: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let insert: UInt32 = 0xFF63
    public static let keypadEnter: UInt32 = 0xFF8D
    public static let f1: UInt32 = 0xFFBE
    public static let shiftL: UInt32 = 0xFFE1
    public static let shiftR: UInt32 = 0xFFE2
    public static let controlL: UInt32 = 0xFFE3
    public static let controlR: UInt32 = 0xFFE4
    public static let capsLock: UInt32 = 0xFFE5
    public static let altL: UInt32 = 0xFFE9
    public static let altR: UInt32 = 0xFFEA
    public static let superL: UInt32 = 0xFFEB
    public static let superR: UInt32 = 0xFFEC
    public static let delete: UInt32 = 0xFFFF

    /// A Unicode scalar as a keysym: Latin-1 maps directly, everything else
    /// uses the 0x01000000 plane.
    public static func fromUnicode(_ scalar: UnicodeScalar) -> UInt32 {
        let value = scalar.value
        if value >= 0x20 && value <= 0xFF { return value }
        return 0x0100_0000 + value
    }
}

/// Which X11 modifier the Mac's Command key should become.
///
/// `super` is the default because a sway user's window-manager bindings all
/// hang off `$mod`, which is Mod4/Super by convention. Linux copy/paste is
/// Ctrl-based either way, so mapping Command to Control would strand the WM.
public enum CommandKeyMapping: String, CaseIterable {
    case superKey = "super"
    case control = "ctrl"
    case alt = "alt"

    public var leftKeysym: UInt32 {
        switch self {
        case .superKey: return Keysym.superL
        case .control: return Keysym.controlL
        case .alt: return Keysym.altL
        }
    }

    public var rightKeysym: UInt32 {
        switch self {
        case .superKey: return Keysym.superR
        case .control: return Keysym.controlR
        case .alt: return Keysym.altR
        }
    }
}

/// Maps macOS virtual key codes for keys that produce no useful character.
public enum MacKeyCode {
    public static func specialKeysym(for keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 0x24: return Keysym.ret
        case 0x4C: return Keysym.keypadEnter
        case 0x30: return Keysym.tab
        case 0x33: return Keysym.backspace
        case 0x35: return Keysym.escape
        case 0x72: return Keysym.insert          // Help doubles as Insert
        case 0x73: return Keysym.home
        case 0x74: return Keysym.pageUp
        case 0x75: return Keysym.delete          // forward delete
        case 0x77: return Keysym.end
        case 0x79: return Keysym.pageDown
        case 0x7B: return Keysym.left
        case 0x7C: return Keysym.right
        case 0x7D: return Keysym.down
        case 0x7E: return Keysym.up
        // Function keys, in the order macOS assigns their scan codes.
        case 0x7A: return Keysym.f1
        case 0x78: return Keysym.f1 + 1
        case 0x63: return Keysym.f1 + 2
        case 0x76: return Keysym.f1 + 3
        case 0x60: return Keysym.f1 + 4
        case 0x61: return Keysym.f1 + 5
        case 0x62: return Keysym.f1 + 6
        case 0x64: return Keysym.f1 + 7
        case 0x65: return Keysym.f1 + 8
        case 0x6D: return Keysym.f1 + 9
        case 0x67: return Keysym.f1 + 10
        case 0x6F: return Keysym.f1 + 11
        case 0x69: return Keysym.f1 + 12
        case 0x6B: return Keysym.f1 + 13
        case 0x71: return Keysym.f1 + 14
        case 0x6A: return Keysym.f1 + 15
        case 0x40: return Keysym.f1 + 16
        default: return nil
        }
    }

    /// Modifier keys, distinguished left from right.
    public static func modifierKeysym(for keyCode: UInt16, commandMapping: CommandKeyMapping) -> UInt32? {
        switch keyCode {
        case 0x38: return Keysym.shiftL
        case 0x3C: return Keysym.shiftR
        case 0x3B: return Keysym.controlL
        case 0x3E: return Keysym.controlR
        case 0x3A: return Keysym.altL
        case 0x3D: return Keysym.altR
        case 0x37: return commandMapping.leftKeysym
        case 0x36: return commandMapping.rightKeysym
        case 0x39: return Keysym.capsLock
        default: return nil
        }
    }
}

/// RFB pointer button bits.
public struct PointerButtons: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = PointerButtons(rawValue: 1 << 0)
    public static let middle = PointerButtons(rawValue: 1 << 1)
    public static let right = PointerButtons(rawValue: 1 << 2)
    public static let scrollUp = PointerButtons(rawValue: 1 << 3)
    public static let scrollDown = PointerButtons(rawValue: 1 << 4)
    public static let scrollLeft = PointerButtons(rawValue: 1 << 5)
    public static let scrollRight = PointerButtons(rawValue: 1 << 6)
}
