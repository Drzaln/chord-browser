import BrowserCrypto
import CryptoKit
import Foundation
import Security
import Testing

/// Extension-bundle signature verification (dte). Fixtures are built from a
/// real RSA key pair: a valid CRX2/CRX3 is actually signed, and the tampered
/// variants mutate the signed bytes. This is the only place the crypto is
/// exercised end-to-end — the installer trusts these verdicts.
@Suite("Extension signature verification")
struct ExtensionSignatureVerifierTests {

    /// A stand-in ZIP body — same convention as `ExtensionArchiveTests`: only
    /// the local-file-header magic has to be real for the verifier.
    private static let zip = Data([0x50, 0x4B, 0x03, 0x04] + Array(0..<64))

    private struct KeyFixture {
        let publicSPKI: Data
        let privateKey: SecKey
    }

    // MARK: - Unsigned / unparseable

    @Test("A plain ZIP is unsigned")
    func xpiIsUnsigned() {
        #expect(ExtensionSignatureVerifier.verify(Self.zip) == .unsigned)
    }

    @Test("Arbitrary non-CRX bytes carry no signature")
    func nonCRXBytesAreUnsigned() {
        #expect(ExtensionSignatureVerifier.verify(Data([0x00, 0x01, 0x02, 0x03, 0x04])) == .unsigned)
    }

    @Test("A CRX whose header is truncated is unsupported")
    func truncatedCRXIsUnsupported() {
        // `Cr24` magic but no version/header bytes to read.
        #expect(ExtensionSignatureVerifier.verify(Data("Cr24".utf8)) == .unsupported)
        // A CRX3 claiming an enormous header it does not carry.
        var truncated = Data("Cr24".utf8)
        truncated += le32(3)
        truncated += le32(9999)
        truncated += Data([0x00, 0x01])
        #expect(ExtensionSignatureVerifier.verify(truncated) == .unsupported)
    }

    // MARK: - CRX2

    @Test("A valid CRX2 verifies; a pinned key upgrades it to trusted")
    func validCRX2Verifies() async throws {
        let key = try makeKey()
        let crx = try makeCRX2(zip: Self.zip, key: key)
        #expect(ExtensionSignatureVerifier.verify(crx) == .verified)
        #expect(ExtensionSignatureVerifier.verify(crx, pinnedKeys: [key.publicSPKI]) == .trusted)
    }

    @Test("A tampered CRX2 ZIP body is detected")
    func tamperedCRX2Detected() async throws {
        let key = try makeKey()
        var crx = try makeCRX2(zip: Self.zip, key: key)
        crx[crx.count - 1] ^= 0xFF  // flip one byte inside the ZIP body
        #expect(ExtensionSignatureVerifier.verify(crx) == .tampered)
    }

    @Test("A CRX2 whose embedded key does not match the signer is detected")
    func keySwapCRX2Detected() async throws {
        let signer = try makeKey()
        let headerKey = try makeKey()  // a *different* key sits in the header
        let sig = try sign(Self.zip, key: signer.privateKey)
        var crx = Data("Cr24".utf8)
        crx += le32(2)
        crx += le32(UInt32(headerKey.publicSPKI.count))
        crx += le32(UInt32(sig.count))
        crx += headerKey.publicSPKI
        crx += sig
        crx += Self.zip
        #expect(ExtensionSignatureVerifier.verify(crx) == .tampered)
    }

    // MARK: - CRX3

    @Test("A valid CRX3 verifies; a pinned key upgrades it to trusted")
    func validCRX3Verifies() async throws {
        let key = try makeKey()
        let crx = try makeCRX3(zip: Self.zip, key: key)
        #expect(ExtensionSignatureVerifier.verify(crx) == .verified)
        #expect(ExtensionSignatureVerifier.verify(crx, pinnedKeys: [key.publicSPKI]) == .trusted)
    }

    @Test("A tampered CRX3 ZIP body is detected via its archive hash")
    func tamperedCRX3ZipDetected() async throws {
        let key = try makeKey()
        var crx = try makeCRX3(zip: Self.zip, key: key)
        crx[crx.count - 1] ^= 0xFF
        #expect(ExtensionSignatureVerifier.verify(crx) == .tampered)
    }

    @Test("A tampered CRX3 signed header is detected via its signature")
    func tamperedCRX3HeaderDetected() async throws {
        let key = try makeKey()
        let signedHeaderData = protoBytes(2, Data(SHA256.hash(data: Self.zip)))
        // The stored signed_header_data gains a field AFTER it was signed; the
        // ZIP hash still matches, so only the header signature can catch it.
        let tampered = signedHeaderData + protoBytes(1, Data([0x01, 0x02, 0x03]))
        let proof = protoBytes(1, key.publicSPKI)
            + protoBytes(2, try sign(signedHeaderData, key: key.privateKey))
        let header = protoBytes(2, proof) + protoBytes(10000, tampered)
        var crx = Data("Cr24".utf8)
        crx += le32(3)
        crx += le32(UInt32(header.count))
        crx += header
        crx += Self.zip
        #expect(ExtensionSignatureVerifier.verify(crx) == .tampered)
    }

    // MARK: - Signer attribution

    @Test("A valid signer outside the pinned set is verified, not trusted")
    func unknownSignerIsVerifiedNotTrusted() async throws {
        let signer = try makeKey()
        let other = try makeKey()
        let crx = try makeCRX2(zip: Self.zip, key: signer)
        #expect(ExtensionSignatureVerifier.verify(crx, pinnedKeys: [other.publicSPKI]) == .verified)
    }

    // MARK: - Fixtures

    private func makeKey() throws -> KeyFixture {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let pub = SecKeyCopyPublicKey(priv) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // External representation of an RSA *public* key is PKCS#1; wrap it in
        // SubjectPublicKeyInfo, the format CRX headers actually carry.
        let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil)! as Data
        let algorithmID = Data([
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ])
        let spki = derSequence(derSequence(algorithmID) + derBitString(pkcs1))
        return KeyFixture(publicSPKI: spki, privateKey: priv)
    }

    private func sign(
        _ data: Data, key: SecKey, algorithm: SecKeyAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
    ) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, data as CFData, &error)
            as Data?
        else {
            throw error!.takeRetainedValue() as Error
        }
        return signature
    }

    /// CRX2: `Cr24` | version:u32 | pubKeyLen:u32 | sigLen:u32 | pubkey | sig | ZIP.
    private func makeCRX2(zip: Data, key: KeyFixture) throws -> Data {
        let signature = try sign(zip, key: key.privateKey)
        var data = Data("Cr24".utf8)
        data += le32(2)
        data += le32(UInt32(key.publicSPKI.count))
        data += le32(UInt32(signature.count))
        data += key.publicSPKI
        data += signature
        data += zip
        return data
    }

    /// CRX3: `Cr24` | version:u32 | headerSize:u32 | protobuf header | ZIP.
    /// The header carries one sha256_with_rsa proof signing `signed_header_data`,
    /// which holds the SHA-256 of the ZIP.
    private func makeCRX3(zip: Data, key: KeyFixture) throws -> Data {
        let signedHeaderData = protoBytes(2, Data(SHA256.hash(data: zip)))
        let proof = protoBytes(1, key.publicSPKI)
            + protoBytes(2, try sign(signedHeaderData, key: key.privateKey))
        let header = protoBytes(2, proof) + protoBytes(10000, signedHeaderData)
        var data = Data("Cr24".utf8)
        data += le32(3)
        data += le32(UInt32(header.count))
        data += header
        data += zip
        return data
    }

    // MARK: - DER / protobuf encoding

    private func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    private func protoBytes(_ field: Int, _ payload: Data) -> Data {
        var out = Data()
        out += protoVarint(UInt64(field << 3 | 2))  // wire type 2, length-delimited
        out += protoVarint(UInt64(payload.count))
        out += payload
        return out
    }

    private func protoVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while true {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            if v == 0 {
                out.append(byte)
                break
            }
            out.append(byte | 0x80)
        }
        return out
    }

    private func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var value = n
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)]) + Data(bytes)
    }

    private func derSequence(_ payload: Data) -> Data {
        Data([0x30]) + derLength(payload.count) + payload
    }

    private func derBitString(_ payload: Data) -> Data {
        Data([0x03]) + derLength(payload.count + 1) + Data([0x00]) + payload
    }
}
