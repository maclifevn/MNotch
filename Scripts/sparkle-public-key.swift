#!/usr/bin/swift
import CryptoKit
import Foundation

// Read an optional signing file without sending secret material through argv,
// stdout, errors or Keychain. Production normally uses generate_keys -p instead.
do {
    guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 4097) ?? Data()
    guard data.count <= 4096, let text = String(data: data, encoding: .utf8),
          let secret = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw CocoaError(.fileReadCorruptFile) }
    let publicKey: Data
    if secret.count == 32 {
        publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
    } else if secret.count == 96 {
        publicKey = secret.suffix(32) // Sparkle's legacy expanded-key format.
    } else { throw CocoaError(.fileReadCorruptFile) }
    print(publicKey.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("Invalid Sparkle signing key file.\n".utf8))
    exit(1)
}
