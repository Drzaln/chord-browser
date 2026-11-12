import ChordCore
import CommonCrypto
import Foundation
import Security
import Testing

@testable import ChordSecrets

/// The Chromium recipe, pinned against values produced outside this codebase.
///
/// The fixtures below were encrypted with `openssl enc -aes-128-cbc` using a key
/// derived by Python's `hashlib.pbkdf2_hmac(..., "sha1", ..., 1003, 16)`. That
/// way a change to Chord's own PBKDF2/AES code cannot cancel itself out in a
/// round-trip test and look correct.
@Suite("Chromium password decryptor")
struct ChromiumPasswordDecryptorTests {
    private let passphrase = "test-passphrase-899.15"
    private let realm = "https://example.com/"

    private func makeDecryptor(_ passphrase: String? = nil) throws
        -> ChromiumPasswordDecryptor
    {
        try ChromiumPasswordDecryptor(passphrase: passphrase ?? self.passphrase)
    }

    @Test("PBKDF2 matches an independently computed vector")
    func pbkdf2Vector() {
        let key = ChromiumPasswordDecryptor.deriveKey(
            passphrase: Array(passphrase.utf8)
        )
        #expect(hex(key) == "309384b356a4be195ab1039da642891b")
    }

    @Test("A v10 fixture decrypts to the exact password")
    func v10Fixture() throws {
        let blob = try #require(
            Data(base64Encoded: "djEwuyr8A3ckfAXWPmIsC5KOoA2/q4ShP4HUhZ4pLrcWkus=")
        )
        #expect(
            try makeDecryptor().decrypt(blob, signonRealm: realm)
                == "correct horse battery staple"
        )
    }

    @Test("Unicode survives the round trip")
    func unicodeFixture() throws {
        let blob = try #require(
            Data(base64Encoded: "djEwBQTL12c7jVmZpXip09GbM+L7S7cjvckYJhgtbK3u55Q=")
        )
        #expect(
            try makeDecryptor().decrypt(blob, signonRealm: realm)
                == "hunter2 ✓ unicode"
        )
    }

    @Test("v11 uses the same recipe")
    func v11Fixture() throws {
        let v10 = try #require(
            Data(base64Encoded: "djEwuyr8A3ckfAXWPmIsC5KOoA2/q4ShP4HUhZ4pLrcWkus=")
        )
        let v11 = Data("v11".utf8) + v10.dropFirst(3)
        #expect(
            try makeDecryptor().decrypt(v11, signonRealm: realm)
                == "correct horse battery staple"
        )
    }

    @Test("A wrong key fails rather than inventing a password")
    func wrongKey() throws {
        let blob = try #require(
            Data(base64Encoded: "djEwbLwBJT8fvsOGa4NVfmicEqMXWfs/gz9PutYkyNV0vk8=")
        )
        #expect(throws: ChromiumPasswordDecryptionError.self) {
            _ = try makeDecryptor().decrypt(blob, signonRealm: realm)
        }
    }

    @Test("Malformed ciphertext is a typed failure, not a crash")
    func malformed() throws {
        let decryptor = try makeDecryptor()
        #expect(throws: ChromiumPasswordDecryptionError.malformedCiphertext) {
            _ = try decryptor.decrypt(Data("v10abc".utf8), signonRealm: realm)
        }
        #expect(throws: ChromiumPasswordDecryptionError.malformedCiphertext) {
            _ = try decryptor.decrypt(Data("v10".utf8), signonRealm: realm)
        }
    }

    @Test("App-bound and unknown wrappers are named, never guessed at")
    func unsupportedVersions() throws {
        let decryptor = try makeDecryptor()
        #expect(throws: ChromiumPasswordDecryptionError.unsupportedVersion("v20")) {
            _ = try decryptor.decrypt(
                Data("v20".utf8) + Data(repeating: 1, count: 16), signonRealm: realm
            )
        }
        #expect(throws: ChromiumPasswordDecryptionError.unrecognisedCiphertext) {
            _ = try decryptor.decrypt(
                Data("nope".utf8) + Data(repeating: 1, count: 16), signonRealm: realm
            )
        }
    }

    @Test("Origin-bound plaintext is stripped only when the realm matches")
    func originBinding() throws {
        let bound = try #require(
            Data(base64Encoded: "djEwZZzYRlmSqmkf4BXAR9nicMcFVG5lZPPFqp7sPnoDK6jkewRbnsphX4VoR0zLLNVi")
        )
        let decryptor = try makeDecryptor()
        #expect(
            try decryptor.decrypt(bound, signonRealm: "https://example.com/")
                == "bound-secret"
        )
        #expect(throws: ChromiumPasswordDecryptionError.originBindingMismatch) {
            _ = try decryptor.decrypt(bound, signonRealm: "https://evil.example/")
        }
    }

    @Test("invalidate drops the key, so a late decrypt cannot run")
    func invalidate() throws {
        let decryptor = try makeDecryptor()
        let blob = try #require(
            Data(base64Encoded: "djEwuyr8A3ckfAXWPmIsC5KOoA2/q4ShP4HUhZ4pLrcWkus=")
        )
        decryptor.invalidate()
        #expect(throws: ChromiumPasswordDecryptionError.decryptionFailed) {
            _ = try decryptor.decrypt(blob, signonRealm: realm)
        }
    }

    @Test("A failure carries no secret material")
    func redaction() throws {
        let blob = try #require(
            Data(base64Encoded: "djEwbLwBJT8fvsOGa4NVfmicEqMXWfs/gz9PutYkyNV0vk8=")
        )
        do {
            _ = try makeDecryptor().decrypt(blob, signonRealm: realm)
            Issue.record("the wrong-key fixture decrypted")
        } catch let error as ChromiumPasswordDecryptionError {
            let rendered = "\(error) \(error.explanation) \(String(describing: error))"
            #expect(!rendered.contains("correct horse battery staple"))
            #expect(!rendered.contains(passphrase))
            #expect(!rendered.contains(blob.base64EncodedString()))
        }
    }

    @Test("A wrapped key is refused; a normal base64 key is accepted")
    func keyShape() throws {
        #expect(throws: ChromiumSafeStorageKeyError.wrappedKeyUnsupported) {
            _ = try ChromiumSafeStorageKey(passphrase: "v20AAAA")
        }
        let wrapped = Data("v20".utf8) + Data(repeating: 7, count: 24)
        #expect(throws: ChromiumSafeStorageKeyError.wrappedKeyUnsupported) {
            _ = try ChromiumSafeStorageKey(passphrase: wrapped.base64EncodedString())
        }
        // Chromium's real shape: base64 of 16 random bytes.
        let normal = Data((0..<16).map { UInt8($0) }).base64EncodedString()
        #expect(try ChromiumSafeStorageKey(passphrase: normal).passphrase == normal)
        #expect(throws: ChromiumSafeStorageKeyError.emptyKey) {
            _ = try ChromiumSafeStorageKey(passphrase: "")
        }
    }

    @Test("The Keychain surface reads the item it is pointed at")
    func keychainRead() throws {
        let service = "com.rizal.chord.tests.safe-storage.\(UUID().uuidString)"
        let account = "ChordTest"
        let expected = passphrase
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(expected.utf8),
            kSecUseDataProtectionKeychain: false,
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        #expect(added == errSecSuccess)
        defer {
            SecItemDelete(
                [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: account,
                    kSecUseDataProtectionKeychain: false,
                ] as CFDictionary
            )
        }

        let data = try ChromiumSafeStorageKeychain().keyData(
            service: service, account: account
        )
        #expect(String(data: data, encoding: .utf8) == expected)

        // The same item drives a decryptor end to end.
        let browser = ChromiumBrowser(
            id: "test", displayName: "Test", keychainService: service,
            keychainAccount: account, dataPath: ["Test"]
        )
        let decryptor = try ChromiumSafeStorageKeychain().makeDecryptor(for: browser)
        let blob = try #require(
            Data(base64Encoded: "djEwuyr8A3ckfAXWPmIsC5KOoA2/q4ShP4HUhZ4pLrcWkus=")
        )
        #expect(
            try decryptor.decrypt(blob, signonRealm: realm)
                == "correct horse battery staple"
        )
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
