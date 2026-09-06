import Foundation
import CommonCrypto

/// Classic VNC DES challenge-response (security type 2).
///
/// This authenticates the client to the server but does NOT encrypt the
/// session, and the 8-byte key limit makes it weak on its own. `mytight` only
/// ever uses it inside an SSH tunnel or a WireGuard/NetBird link, where the
/// transport already provides confidentiality.
public enum VNCAuth {
    /// VNC feeds the password to DES with the bit order of each byte reversed.
    private static func mangle(_ password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, byte) in Array(password.utf8).prefix(8).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                reversed |= 1 << (7 - bit)
            }
            key[i] = reversed
        }
        return key
    }

    /// Encrypts the 16-byte challenge as two independent DES-ECB blocks.
    public static func response(challenge: [UInt8], password: String) throws -> [UInt8] {
        guard challenge.count == 16 else {
            throw RFBError.handshake("expected 16-byte challenge, got \(challenge.count)")
        }
        let key = mangle(password)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            challenge.withUnsafeBytes { inPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, 8,
                            nil,
                            inPtr.baseAddress, 16,
                            outPtr.baseAddress, 16,
                            &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else {
            throw RFBError.authFailed("DES failed (status \(status))")
        }
        return out
    }

    /// Raw single-block DES-ECB, exposed so the test vector can verify the
    /// CommonCrypto path before we trust it on the wire.
    public static func desEncryptBlock(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        guard key.count == 8, block.count == 8 else { return nil }
        var out = [UInt8](repeating: 0, count: 8)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            block.withUnsafeBytes { i in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode), k.baseAddress, 8, nil,
                            i.baseAddress, 8, o.baseAddress, 8, &moved)
                }
            }
        }
        return status == kCCSuccess && moved == 8 ? out : nil
    }
}
