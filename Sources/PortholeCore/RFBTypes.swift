import Foundation

public struct RFBRect: Equatable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

public enum Encoding: Int32 {
    case raw = 0
    case copyRect = 1
    case rre = 2
    case hextile = 5
    case tight = 7
    case trle = 15
    case zrle = 16
    case openH264 = 50

    case pseudoCursor = -239
    case pseudoDesktopSize = -223
    case pseudoQemuExtendedKey = -258
    case pseudoQemuLedState = -261
    case pseudoDesktopName = -307
    case pseudoExtendedDesktopSize = -308
    case pseudoFence = -312
    case pseudoContinuousUpdates = -313
    case pseudoExtendedMouseButtons = -316
    case pseudoLastRect = -224
    case pseudoCompressLevel0 = -256
    case pseudoQualityLevel0 = -32
    case pseudoVMwareLedState = 0x574d5668
}

public enum SecurityType: UInt8 {
    case invalid = 0
    case none = 1
    case vncAuth = 2
    case rsaAes = 5
    case tight = 16
    case veNCrypt = 19
    case appleDH = 30
    case rsaAes256 = 129

    public var label: String {
        switch self {
        case .invalid: return "invalid"
        case .none: return "none"
        case .vncAuth: return "vnc-auth (DES)"
        case .rsaAes: return "rsa-aes128"
        case .tight: return "tight"
        case .veNCrypt: return "vencrypt"
        case .appleDH: return "apple-dh"
        case .rsaAes256: return "rsa-aes256"
        }
    }
}

/// RFB PIXEL_FORMAT. We always negotiate 32bpp little-endian true colour so the
/// framebuffer is already BGRA in memory and uploads to Metal with no repack.
public struct PixelFormat: Equatable {
    public var bitsPerPixel: UInt8 = 32
    public var depth: UInt8 = 24
    public var bigEndian: Bool = false
    public var trueColour: Bool = true
    public var redMax: UInt16 = 255
    public var greenMax: UInt16 = 255
    public var blueMax: UInt16 = 255
    public var redShift: UInt8 = 16
    public var greenShift: UInt8 = 8
    public var blueShift: UInt8 = 0

    public init() {}

    /// 0x00RRGGBB stored little-endian == B,G,R,A byte order == MTLPixelFormat.bgra8Unorm.
    public static let bgra = PixelFormat()

    public init(reader: BufferedReader) throws {
        bitsPerPixel = try reader.readU8()
        depth = try reader.readU8()
        bigEndian = try reader.readU8() != 0
        trueColour = try reader.readU8() != 0
        redMax = try reader.readU16()
        greenMax = try reader.readU16()
        blueMax = try reader.readU16()
        redShift = try reader.readU8()
        greenShift = try reader.readU8()
        blueShift = try reader.readU8()
        try reader.skip(3)
    }

    public var bytes: [UInt8] {
        var out: [UInt8] = [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColour ? 1 : 0]
        out += [UInt8(redMax >> 8), UInt8(redMax & 0xff)]
        out += [UInt8(greenMax >> 8), UInt8(greenMax & 0xff)]
        out += [UInt8(blueMax >> 8), UInt8(blueMax & 0xff)]
        out += [redShift, greenShift, blueShift, 0, 0, 0]
        return out
    }

    /// True when Tight/ZRLE may drop the unused byte and ship 3-byte pixels.
    public var usesCompactPixel: Bool {
        bitsPerPixel == 32 && depth <= 24 && redMax == 255 && greenMax == 255 && blueMax == 255
    }

    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }
}

/// Little-endian BGRA word from 8-bit R/G/B components.
@inline(__always)
public func packBGRA(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
    UInt32(b) | UInt32(g) << 8 | UInt32(r) << 16 | 0xFF00_0000
}

public enum ClientMessage: UInt8 {
    case setPixelFormat = 0
    case setEncodings = 2
    case framebufferUpdateRequest = 3
    case keyEvent = 4
    case pointerEvent = 5
    case clientCutText = 6
    case enableContinuousUpdates = 150
    case clientFence = 248
    case setDesktopSize = 251
}

public enum ServerMessage: UInt8 {
    case framebufferUpdate = 0
    case setColourMapEntries = 1
    case bell = 2
    case serverCutText = 3
    case endOfContinuousUpdates = 150
    case serverFence = 248
}

/// Little helper for building big-endian wire messages.
public struct MessageBuilder {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public init(_ type: ClientMessage) { bytes = [type.rawValue] }
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func pad(_ n: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    public mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xff)) }
    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8((v >> 24) & 0xff)); bytes.append(UInt8((v >> 16) & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff)); bytes.append(UInt8(v & 0xff))
    }
    public mutating func s32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func raw(_ v: [UInt8]) { bytes.append(contentsOf: v) }
}
