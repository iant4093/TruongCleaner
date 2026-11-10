import CryptoKit
import Foundation
import os

/// The public keys an update's `SHA256SUMS.sig` must verify against.
///
/// The release owner signs `SHA256SUMS` on their own Mac with an Ed25519 key that never leaves it.
/// The app embeds only the public half, so whoever can upload release assets still cannot ship
/// an update the app will install. An empty key list trusts nothing: every update is refused.
public struct UpdateTrust: Sendable {
    /// Longest `SHA256SUMS.sig` may be. A real one is 89 bytes.
    public static let maxSignatureFileBytes = 1024

    /// Raw 32-byte Ed25519 public keys, standard base64, that the app trusts.
    ///
    /// The public half of the release owner's signing key (`scripts/release-key.swift generate`).
    /// If this list were empty, every update would be refused (fail closed). Adding a second key
    /// before retiring the first allows key rotation.
    public static let productionPublicKeys: [String] = [
        // Ian's release key, created 2026-11-10 with `swift scripts/release-key.swift generate`.
        "pXOVZv2innD/hYJWcZzApiY/QbiqiHYfsRI5f4JGf5k=",
    ]

    /// The trust the shipping app uses, built from ``productionPublicKeys``.
    public static let production = UpdateTrust(base64Keys: productionPublicKeys)

    private static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "updates")

    private let keys: [Curve25519.Signing.PublicKey]

    /// Trusts exactly these keys. Tests pass keys they generated.
    public init(publicKeys: [Curve25519.Signing.PublicKey]) {
        keys = publicKeys
    }

    /// Trusts the keys given as base64 of the raw 32 bytes. An entry that is not valid is logged and
    /// ignored; it is never trusted.
    public init(base64Keys: [String]) {
        var parsed: [Curve25519.Signing.PublicKey] = []
        for (index, text) in base64Keys.enumerated() {
            if let data = Data(base64Encoded: text), data.count == 32,
               let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) {
                parsed.append(key)
            } else {
                Self.log.error("Ignoring an invalid update public key at position \(index, privacy: .public)")
            }
        }
        keys = parsed
    }

    /// Whether `signatureFile` is a well-formed `SHA256SUMS.sig` for exactly `message` under a
    /// trusted key.
    ///
    /// The file holds one line, the standard base64 of the 64-byte signature, with an optional
    /// trailing newline. Anything else (empty, wrong length, bad base64, extra lines, over 1 KB)
    /// is not valid. With no trusted keys the answer is always `false`.
    public func isValid(signatureFile: Data, for message: Data) -> Bool {
        guard let signature = Self.parse(signatureFile) else { return false }
        return keys.contains { $0.isValidSignature(signature, for: message) }
    }

    /// The 64 signature bytes, or `nil` when the file is not in the documented format.
    static func parse(_ file: Data) -> Data? {
        guard !file.isEmpty, file.count <= maxSignatureFileBytes,
              var text = String(data: file, encoding: .utf8)
        else { return nil }
        if text.hasSuffix("\n") { text.removeLast() }
        // The only newline allowed is the one removed above; everything else is a second line.
        guard !text.isEmpty, !text.contains(where: \.isNewline),
              let bytes = Data(base64Encoded: text), bytes.count == 64,
              bytes.base64EncodedString() == text
        else { return nil }
        return bytes
    }
}
