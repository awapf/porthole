import Foundation
import PortholeCore

// `--serve [port]` runs a local RFB server instead of the test suite, so the
// window, input and resize paths can be checked without a VM.
let arguments = Array(CommandLine.arguments.dropFirst())
if let index = arguments.firstIndex(of: "--serve") {
    let port = index + 1 < arguments.count ? UInt16(arguments[index + 1]) ?? 5999 : 5999
    runDemoServer(port: port)
}

let h = Harness()

// MARK: - Authentication

print("auth")

h.test("DES matches the FIPS-46 known answer") {
    let key: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
    let plain: [UInt8] = [0x4E, 0x6F, 0x77, 0x20, 0x69, 0x73, 0x20, 0x74]
    let expected: [UInt8] = [0x3F, 0xA4, 0x0E, 0x8A, 0x98, 0x4D, 0x48, 0x15]
    try h.expectEqual(VNCAuth.desEncryptBlock(key: key, block: plain) ?? [], expected)
}

h.test("VNC challenge response is two independent DES blocks") {
    let challenge = [UInt8](repeating: 0, count: 16)
    let response = try VNCAuth.response(challenge: challenge, password: "sesame")
    try h.expectEqual(response.count, 16)
    try h.expect(Array(response[0..<8]) == Array(response[8..<16]),
                 "identical halves must encrypt identically")
    try h.expect(response != challenge, "response must not be the challenge")
}

h.test("password key is bit-reversed per byte") {
    // 'a' is 0x61 = 0110_0001; reversed is 1000_0110 = 0x86. If the mangling
    // were skipped these two would collide with a plain-ASCII key.
    let a = try VNCAuth.response(challenge: [UInt8](repeating: 1, count: 16), password: "a")
    let reversed = VNCAuth.desEncryptBlock(key: [0x86, 0, 0, 0, 0, 0, 0, 0],
                                           block: [UInt8](repeating: 1, count: 8))
    try h.expectEqual(Array(a[0..<8]), reversed ?? [])
}

// MARK: - Pixel handling

print("pixels")

h.test("negotiated format is BGRA and compact-pixel eligible") {
    let format = PixelFormat.bgra
    try h.expectEqual(format.bytes.count, 16)
    try h.expect(format.usesCompactPixel, "32bpp with 255 maxes must use 3-byte pixels")
    try h.expectEqual(packBGRA(r: 0x11, g: 0x22, b: 0x33), 0xFF11_2233)
}

h.test("compact and wide pixel decoding agree") {
    var bytes: [UInt8] = [0x11, 0x22, 0x33]
    let compact = bytes.withUnsafeBufferPointer { decodePixel($0.baseAddress!, 3, .bgra) }
    try h.expectEqual(compact, rgb(0x11, 0x22, 0x33))
    // 0x00112233 stored little-endian is 33 22 11 00.
    bytes = [0x33, 0x22, 0x11, 0x00]
    let wide = bytes.withUnsafeBufferPointer { decodePixel($0.baseAddress!, 4, .bgra) }
    try h.expectEqual(wide, rgb(0x11, 0x22, 0x33))
}

// MARK: - Framebuffer

print("framebuffer")

h.test("CopyRect survives overlapping source and destination") {
    let fb = Framebuffer(width: 4, height: 2)
    for x in 0..<4 { fb.row(0)[x] = UInt32(x + 1) }
    fb.copy(from: RFBRect(x: 0, y: 0, width: 3, height: 1), toX: 1, toY: 0)
    try h.expectEqual([fb.row(0)[1], fb.row(0)[2], fb.row(0)[3]], [1, 2, 3])
}

h.test("resize keeps the overlapping region") {
    let fb = Framebuffer(width: 4, height: 4)
    fb.row(1)[2] = 0xDEAD_BEEF
    fb.resize(width: 8, height: 8)
    try h.expectEqual(fb.width, 8)
    try h.expectEqual(fb.row(1)[2], 0xDEAD_BEEF)
}

h.test("fill clips to the framebuffer bounds") {
    let fb = Framebuffer(width: 4, height: 4)
    fb.fill(RFBRect(x: 2, y: 2, width: 100, height: 100), with: 0x1234)
    try h.expectEqual(fb.row(3)[3], 0x1234)
    try h.expect(fb.row(0)[0] != 0x1234, "outside the rect must be untouched")
}

// MARK: - zlib streaming

print("zlib")

h.test("inflate history survives across messages") {
    let original = [UInt8]("the quick brown fox jumps over the lazy dog".utf8)
    let compressed = Deflater().compress(original)
    let split = compressed.count / 2
    let inflater = Inflater()
    let first = try inflater.inflateAll(Array(compressed[0..<split]), hint: original.count)
    let second = try inflater.inflateAll(Array(compressed[split...]), hint: original.count)
    try h.expectEqual(first + second, original)
}

h.test("reset lets a fresh stream decode correctly") {
    let payload = [UInt8](repeating: UInt8(ascii: "a"), count: 40)
    let inflater = Inflater()
    try h.expectEqual(try inflater.inflateAll(Deflater().compress(payload), hint: 64), payload)
    inflater.reset()
    try h.expectEqual(try inflater.inflateAll(Deflater().compress(payload), hint: 64), payload)
}

runDecoderTests(h)
runSessionTests(h)
runRenderTests(h)

let status = h.summarise()
exit(status)
