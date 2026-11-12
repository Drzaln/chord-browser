import ChordCore
import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Chromium's macOS encryption, as Chromium itself implements it.
///
/// The recipe, unchanged for a decade:
/// - passphrase: the UTF-8 text of the `<Browser> Safe Storage` Keychain item,
///   **used as written** (Chromium stores base64 of 16 random bytes, then feeds
///   that base64 text to PBKDF2 — decoding it first derives the wrong key),
/// - PBKDF2-HMAC-SHA1, salt `saltysalt`, 1003 iterations, 16 bytes out,
/// - AES-128-CBC, IV = sixteen spaces, PKCS#7 padding,
/// - blob = `v10` (or `v11`) followed by the ciphertext.
///
/// Newer Chromium can prefix the *plaintext* with a 32-byte SHA-256 of the
/// signon realm. That prefix is only stripped when it verifies against the row's
/// realm; an unverifiable prefix is reported, never guessed past. `v20`/`v21`
/// app-bound encryption and `v12` portal keys are refused by name.
///
/// This type owns the derived key and zeroes it on `invalidate()`/`deinit`.
/// That is best-effort in Swift — `String` and `Data` copies are not under our
/// control — but the import holds plaintext only for the write call.
public final class ChromiumPasswordDecryptor: ChromiumPasswordDecrypting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var key: [UInt8]
    private var invalidated = false

    public init(passphrase: String) throws {
        let validated = try ChromiumSafeStorageKey(passphrase: passphrase)
        key = Self.deriveKey(passphrase: Array(validated.passphrase.utf8))
    }

    deinit {
        wipe()
    }

    public func decrypt(_ ciphertext: Data, signonRealm: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { throw ChromiumPasswordDecryptionError.decryptionFailed }
        return try Self.decrypt(ciphertext, signonRealm: signonRealm, key: key)
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        wipe()
        invalidated = true
    }

    private func wipe() {
        _ = key.withUnsafeMutableBytes { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
        }
        key.removeAll(keepingCapacity: false)
    }

    // MARK: - The recipe

    static let salt = Array("saltysalt".utf8)
    static let iterations: UInt32 = 1003
    static let derivedKeyLength = 16

    /// PBKDF2-HMAC-SHA1 with Chromium's parameters. Internal so the tests can
    /// pin it against an independent vector rather than against this code's own
    /// encrypt helper.
    static func deriveKey(passphrase: [UInt8]) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: derivedKeyLength)
        guard !passphrase.isEmpty else { return derived }

        let status = passphrase.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passphrase.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    &derived,
                    derived.count
                )
            }
        }
        // Only returns non-success for parameters this code fixes. Returning a
        // zero key makes every decrypt fail cleanly rather than crashing.
        guard status == kCCSuccess else {
            return [UInt8](repeating: 0, count: derivedKeyLength)
        }
        return derived
    }

    private static func decrypt(
        _ ciphertext: Data, signonRealm: String, key: [UInt8]
    ) throws -> String {
        guard ciphertext.count >= 3 else {
            throw ChromiumPasswordDecryptionError.malformedCiphertext
        }
        let markerBytes = [UInt8](ciphertext.prefix(3))
        let marker = String(bytes: markerBytes, encoding: .ascii)

        switch marker {
        case "v10", "v11":
            break  // Chromium's AES-CBC format; v11 uses the same cipher here.
        case "v12":
            throw ChromiumPasswordDecryptionError.unsupportedVersion("v12")
        case "v20", "v21":
            throw ChromiumPasswordDecryptionError.unsupportedVersion(
                marker ?? "app-bound encryption"
            )
        default:
            if markerBytes[0] == UInt8(ascii: "v"),
                ChromiumSafeStorageKey.isASCIIDigit(markerBytes[1]),
                ChromiumSafeStorageKey.isASCIIDigit(markerBytes[2])
            {
                throw ChromiumPasswordDecryptionError.unsupportedVersion(
                    marker ?? "an unknown encryption version"
                )
            }
            throw ChromiumPasswordDecryptionError.unrecognisedCiphertext
        }

        let body = [UInt8](ciphertext.dropFirst(3))
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else {
            throw ChromiumPasswordDecryptionError.malformedCiphertext
        }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        defer {
            _ = output.withUnsafeMutableBytes { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            body,
            body.count,
            &output,
            output.count,
            &moved
        )
        guard status == kCCSuccess else {
            throw ChromiumPasswordDecryptionError.decryptionFailed
        }
        let plaintext = Data(output.prefix(moved))
        guard !plaintext.isEmpty else {
            throw ChromiumPasswordDecryptionError.invalidPlaintext
        }

        // Ordinary password: the decrypted bytes are the whole UTF-8 string.
        if let text = String(data: plaintext, encoding: .utf8), !text.isEmpty {
            return text
        }

        // Origin-bound plaintext: SHA-256(signon_realm) || password. Only strip
        // the prefix when it verifies; a 32-byte prefix that does not is either
        // a different site's blob or a failed decrypt.
        guard plaintext.count > 32 else {
            throw ChromiumPasswordDecryptionError.invalidPlaintext
        }
        let expected = Data(SHA256.hash(data: Data(signonRealm.utf8)))
        guard Data(plaintext.prefix(32)) == expected else {
            throw ChromiumPasswordDecryptionError.originBindingMismatch
        }
        guard let text = String(data: plaintext.dropFirst(32), encoding: .utf8),
            !text.isEmpty
        else {
            throw ChromiumPasswordDecryptionError.invalidPlaintext
        }
        return text
    }
}

/// A Safe Storage passphrase after shape validation.
///
/// Chromium's own format is base64 text encoding 16 random bytes, but the only
/// thing that matters cryptographically is the text, so any non-empty string is
/// accepted. A value that looks like a *wrapped* key instead is refused: trying
/// possible unwrappings until one decrypts is a guess, and this feature does not
/// guess with key material.
public struct ChromiumSafeStorageKey: Sendable, Equatable {
    public let passphrase: String

    public init(passphrase: String) throws {
        guard !passphrase.isEmpty else { throw ChromiumSafeStorageKeyError.emptyKey }
        try Self.rejectWrappedKey(passphrase)
        self.passphrase = passphrase
    }

    static func rejectWrappedKey(_ text: String) throws {
        // The expected Chromium form: base64 of exactly 16 random bytes. Accept
        // it before looking for markers, so a legitimate key that happens to
        // begin with those letters is not misread.
        if let decoded = Data(base64Encoded: text), decoded.count == 16 { return }

        let raw = Array(text.utf8)
        if startsWithVersionMarker(raw) {
            throw ChromiumSafeStorageKeyError.wrappedKeyUnsupported
        }
        if let decoded = Data(base64Encoded: text),
            startsWithVersionMarker([UInt8](decoded))
        {
            throw ChromiumSafeStorageKeyError.wrappedKeyUnsupported
        }
    }

    static func startsWithVersionMarker(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3
            && bytes[0] == UInt8(ascii: "v")
            && isASCIIDigit(bytes[1])
            && isASCIIDigit(bytes[2])
    }

    static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}

/// Reads a browser's Safe Storage passphrase from the macOS Keychain.
///
/// This is the one deliberate Keychain read outside Chord's own vault. The item
/// belongs to another app, so macOS may show an access prompt; refusing it means
/// no key and therefore no import. Matching both service and account is what
/// keeps a look-alike item from being accepted.
public struct ChromiumSafeStorageKeychain: ChromiumPasswordKeyProviding {
    public init() {}

    public func makeDecryptor(
        for browser: ChromiumBrowser
    ) throws -> any ChromiumPasswordDecrypting {
        let data = try keyData(
            service: browser.keychainService, account: browser.keychainAccount
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChromiumSafeStorageKeyError.notText
        }
        return try ChromiumPasswordDecryptor(passphrase: text)
    }

    /// The raw Keychain payload. Public so a test can round-trip a throwaway
    /// item without reading a real browser's key.
    public func keyData(service: String, account: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            // Browser Safe Storage items live in the file-based login keychain,
            // not the data-protection keychain.
            kSecUseDataProtectionKeychain: false,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw ChromiumSafeStorageKeyError.itemNotFound
        }
        guard status == errSecSuccess else {
            throw ChromiumSafeStorageKeyError.keychain(status: status)
        }
        guard let data = result as? Data, !data.isEmpty else {
            throw ChromiumSafeStorageKeyError.emptyKey
        }
        return data
    }
}
