// Release signing key for in-app updates. Dev tool: run by hand on the release owner's Mac, never by CI
// and never from the app.
//
//   swift scripts/release-key.swift generate      make the Ed25519 key, keep it in the login Keychain
//   swift scripts/release-key.swift public        print the public key (base64)
//   swift scripts/release-key.swift sign <file>   write <file>.sig, a detached signature over the
//                                                 exact bytes of <file>, then verify it
//
// The private key lives only in the login Keychain (generic password, service
// com.iant4093.TruongCleaner.update-signing, account ed25519). It is never printed or written to a
// file. This script does not call /usr/bin/security, because that would put the secret in argv.
//
// The .sig file is one line: standard base64 of the 64 signature bytes, then a newline. The app
// (CleanerActions/Update/UpdateTrust.swift) accepts exactly that format.

import CryptoKit
import Foundation
import Security

let keychainService = "com.iant4093.TruongCleaner.update-signing"
let keychainAccount = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("release-key: \(message)\n".utf8))
    exit(1)
}

func say(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

func describe(_ status: OSStatus) -> String {
    let text = SecCopyErrorMessageString(status, nil) as String?
    return "\(text ?? "unknown error") (\(status))"
}

/// Attributes that identify the one Keychain item. No data and no access group: the login Keychain.
func identity() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
    ]
}

/// True when the item exists. Does not read the secret, so macOS shows no prompt.
func keyExists() -> Bool {
    var query = identity()
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    switch status {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: fail("could not look in the Keychain: \(describe(status))")
    }
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    var query = identity()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        fail("there is no signing key yet. Run: swift scripts/release-key.swift generate")
    }
    guard status == errSecSuccess else { fail("could not read the key from the Keychain: \(describe(status))") }
    guard let data = result as? Data, data.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    else { fail("the Keychain item is not a 32-byte Ed25519 key. Nothing was changed.") }
    return key
}

func generate() {
    if keyExists() {
        fail("a signing key already exists in the login Keychain. Not replacing it. Use 'public' to see its public key.")
    }
    let key = Curve25519.Signing.PrivateKey()
    var attributes = identity()
    attributes[kSecValueData as String] = key.rawRepresentation
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    attributes[kSecAttrLabel as String] = "TruongCleaner update signing key"
    var status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecParam {
        // Some macOS versions reject the accessibility attribute for the file-based login Keychain.
        // Items there never leave this Mac, so storing without it keeps the same promise.
        attributes[kSecAttrAccessible as String] = nil
        status = SecItemAdd(attributes as CFDictionary, nil)
    }
    guard status == errSecSuccess else { fail("could not store the key in the Keychain: \(describe(status))") }
    say("Created the update signing key in your login Keychain.")
    say("Public key (base64): \(key.publicKey.rawRepresentation.base64EncodedString())")
    say("Send this public key to the orchestrator. Never share the private key; it is not shown anywhere.")
}

func printPublic() {
    say(loadKey().publicKey.rawRepresentation.base64EncodedString())
}

/// Parses a .sig file the way the app does: one base64 line of 64 bytes, optional final newline.
func signatureBytes(fromFile data: Data) -> Data? {
    guard var text = String(data: data, encoding: .utf8) else { return nil }
    if text.hasSuffix("\n") { text.removeLast() }
    guard !text.isEmpty, !text.contains(where: \.isNewline),
          let bytes = Data(base64Encoded: text), bytes.count == 64, bytes.base64EncodedString() == text
    else { return nil }
    return bytes
}

func sign(path: String) {
    let fileURL = URL(fileURLWithPath: path)
    guard let message = try? Data(contentsOf: fileURL) else { fail("cannot read \(path)") }
    let key = loadKey()
    guard let signature = try? key.signature(for: message) else { fail("signing failed") }
    let output = URL(fileURLWithPath: path + ".sig")
    do {
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: output, options: .atomic)
    } catch {
        fail("cannot write \(output.path): \(error.localizedDescription)")
    }
    // Read both files again from disk and check, so a bad write or a wrong file never goes out.
    guard let written = try? Data(contentsOf: output), let parsed = signatureBytes(fromFile: written),
          let again = try? Data(contentsOf: fileURL), again == message,
          key.publicKey.isValidSignature(parsed, for: again)
    else { fail("the signature written to \(output.path) does not verify. Do not upload it.") }
    say("Signed \(path) (\(message.count) bytes). Wrote \(output.path) and verified it.")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("generate", 1): generate()
case ("public", 1): printPublic()
case ("sign", 2): sign(path: arguments[1])
default:
    FileHandle.standardError.write(
        Data("usage: swift scripts/release-key.swift generate | public | sign <file>\n".utf8))
    exit(2)
}
