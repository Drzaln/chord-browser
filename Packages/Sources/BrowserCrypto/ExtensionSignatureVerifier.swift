import BrowserCore
import CryptoKit
import Foundation
import Security

/// Verifies the bundle identity of a `.crx`/`.xpi` at install time.
///
/// `WKWebExtension` loads whatever bundle it is handed and performs no signing
/// checks of its own, so the browser must. This is the module that owns that
/// check — the only Security/CryptoKit importer besides BrowserSecrets, keeping
/// the one-OS-framework-per-target rule intact (ADR 011).
///
/// What "verified" means here, honestly:
/// - **`.trusted`** — the bundle's signature validates against the public key it
///   embeds AND that key is one the app pins as a known signer.
/// - **`.verified`** — the signature validates against the embedded key, but the
///   key is not pinned. This proves the bundle is internally consistent (not
///   tampered since signing) and attributes it to whoever holds the matching
///   private key — it does not vouch for that signer.
/// - **`.tampered`** — a signature or archive hash is present but does not
///   validate. Trust nothing.
/// - **`.unsigned`** — a plain ZIP (`.xpi`/`.zip`) with no signature header.
/// - **`.unsupported`** — the header could not be parsed far enough to check.
///
/// Both CRX formats are verified against the key they embed: CRX2's header
/// carries the RSA public key and a signature over the ZIP body; CRX3's header
/// is a protobuf whose RSA-SHA256 proof signs `signed_header_data`, which in
/// turn carries the SHA-256 of the ZIP. The pinned-key set is empty today (no
/// extension store exists yet); the plumbing is here so a store key slots in
/// without re-designing the check.
public enum ExtensionSignatureVerifier {

    public static func verify(
        _ data: Data, pinnedKeys: [Data] = []
    ) -> ExtensionSignatureStatus {
        // A ZIP alone (.xpi/.zip) carries no signature header at all.
        guard data.starts(with: crxMagic) else { return .unsigned }
        guard let version = readUInt32(data, at: 4) else { return .unsupported }
        switch version {
        case 2: return verifyCRX2(data, pinnedKeys: pinnedKeys)
        case 3: return verifyCRX3(data, pinnedKeys: pinnedKeys)
        default: return .unsupported
        }
    }

    // MARK: - CRX2

    /// Layout: `Cr24` | version:u32 | pubKeyLen:u32 | sigLen:u32 | publicKey |
    /// signature | ZIP. The RSA signature (PKCS#1 v1.5, SHA-256, with SHA-1 as
    /// the pre-Chrome-33 fallback) covers the ZIP body.
    private static func verifyCRX2(_ data: Data, pinnedKeys: [Data]) -> ExtensionSignatureStatus {
        guard let pubKeyLen = readUInt32(data, at: 8),
            let sigLen = readUInt32(data, at: 12)
        else { return .unsupported }

        let pubKeyStart = 16
        let sigStart = pubKeyStart + Int(pubKeyLen)
        let zipStart = sigStart + Int(sigLen)
        guard zipStart <= data.count, data[zipStart...].starts(with: zipMagic) else {
            return .unsupported
        }

        let publicKey = Data(data[pubKeyStart..<sigStart])
        let signature = Data(data[sigStart..<zipStart])
        let zip = Data(data[zipStart...])
        guard let key = secKey(from: publicKey) else { return .unsupported }

        if verifyRSA(key, data: zip, signature: signature, algorithm: .rsaSignatureMessagePKCS1v15SHA256)
            || verifyRSA(key, data: zip, signature: signature, algorithm: .rsaSignatureMessagePKCS1v15SHA1)
        {
            return pinnedKeys.contains(publicKey) ? .trusted : .verified
        }
        return .tampered
    }

    // MARK: - CRX3

    /// Layout: `Cr24` | version:u32 | headerSize:u32 | header(protobuf) | ZIP.
    /// The header is a `CrxFileHeader` protobuf: repeated `sha256_with_rsa`
    /// proofs (field 2), and `signed_header_data` (field 10000), itself a
    /// `SignedData` protobuf whose `sha256_with_rsa` (field 2) is the SHA-256 of
    /// the ZIP. The proof's signature covers the serialized `signed_header_data`.
    private static func verifyCRX3(_ data: Data, pinnedKeys: [Data]) -> ExtensionSignatureStatus {
        guard let headerSize = readUInt32(data, at: 8) else { return .unsupported }
        let headerStart = 12
        let zipStart = headerStart + Int(headerSize)
        guard zipStart <= data.count, data[zipStart...].starts(with: zipMagic) else {
            return .unsupported
        }

        let headerBytes = Data(data[headerStart..<zipStart])
        let zip = Data(data[zipStart...])
        guard let header = CrxFileHeader.parse(headerBytes),
            let signedHeaderBytes = header.signedHeaderData,
            let signed = SignedData.parse(signedHeaderBytes)
        else { return .unsupported }

        // 1) The archive hash inside SignedData must match the ZIP we received.
        guard let declaredHash = signed.sha256WithRSA, !declaredHash.isEmpty else {
            return .unsupported
        }
        guard Data(SHA256.hash(data: zip)) == declaredHash else { return .tampered }

        // 2) An RSA-SHA256 proof must validate over the signed header bytes.
        var pinnedMatch: Data?
        var anyVerified = false
        for proof in header.sha256RSAProofs {
            guard let key = secKey(from: proof.publicKey) else { continue }
            if verifyRSA(
                key, data: signedHeaderBytes, signature: proof.signature,
                algorithm: .rsaSignatureMessagePKCS1v15SHA256
            ) {
                anyVerified = true
                if pinnedKeys.contains(proof.publicKey) { pinnedMatch = proof.publicKey }
                break
            }
        }
        guard anyVerified else {
            // ECDSA-only headers we cannot check are "could not check", not
            // "tampered"; an RSA proof that failed to validate is tampering.
            return header.sha256RSAProofs.isEmpty ? .unsupported : .tampered
        }
        return pinnedMatch != nil ? .trusted : .verified
    }

    // MARK: - Crypto plumbing

    private static func secKey(from spki: Data) -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(spki as CFData, attributes as CFDictionary, nil)
    }

    private static func verifyRSA(
        _ key: SecKey, data: Data, signature: Data, algorithm: SecKeyAlgorithm
    ) -> Bool {
        guard SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            key, algorithm, data as CFData, signature as CFData, &error
        )
    }

    // MARK: - Byte helpers

    private static let crxMagic: [UInt8] = Array("Cr24".utf8)
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[start + i]) << (8 * i)
        }
        return value
    }
}

// MARK: - Minimal protobuf parsing

/// A bounds-checked reader for the subset of the protobuf wire format CRX3 uses:
/// varints, 64/32-bit fields, and length-delimited bytes. Groups are rejected.
private struct ProtoReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    /// Reads the next field, or `nil` at end of input or on malformed bytes.
    mutating func next() -> ProtoField? {
        guard offset < data.count, let tag = readVarint() else { return nil }
        let number = Int(tag >> 3)
        let wire = Int(tag & 7)
        switch wire {
        case 0:
            guard let value = readVarint() else { return nil }
            return ProtoField(number: number, data: Data(), value: value)
        case 1:
            guard offset + 8 <= data.count else { return nil }
            let payload = data.subdata(in: offset..<(offset + 8))
            offset += 8
            return ProtoField(number: number, data: payload, value: 0)
        case 2:
            guard let length = readVarint(),
                length <= UInt64(data.count - offset)
            else { return nil }
            let start = offset
            offset += Int(length)
            return ProtoField(
                number: number, data: data.subdata(in: start..<offset), value: 0
            )
        case 5:
            guard offset + 4 <= data.count else { return nil }
            let payload = data.subdata(in: offset..<(offset + 4))
            offset += 4
            return ProtoField(number: number, data: payload, value: 0)
        default:
            return nil  // groups and unknown wire types
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard offset < data.count else { return nil }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

private struct ProtoField {
    let number: Int
    let data: Data
    let value: UInt64
}

/// `CrxFileHeader` — the relevant subset: repeated `sha256_with_rsa` proofs
/// (field 2, each an `AsymmetricKeyProof`) and `signed_header_data` (field
/// 10000). ECDSA/SHA-512 proofs are ignored; we only ever act on RSA-SHA256.
private struct CrxFileHeader {
    var sha256RSAProofs: [CRX3Proof] = []
    var signedHeaderData: Data?

    static func parse(_ bytes: Data) -> CrxFileHeader? {
        var reader = ProtoReader(bytes)
        var result = CrxFileHeader()
        while let field = reader.next() {
            switch field.number {
            case 2:
                guard field.data.count > 0, let proof = CRX3Proof.parse(field.data) else {
                    return nil
                }
                result.sha256RSAProofs.append(proof)
            case 10000:
                result.signedHeaderData = field.data
            default:
                continue
            }
        }
        return result
    }
}

/// `AsymmetricKeyProof` — `public_key` (field 1), `signature` (field 2).
private struct CRX3Proof {
    let publicKey: Data
    let signature: Data

    static func parse(_ bytes: Data) -> CRX3Proof? {
        var reader = ProtoReader(bytes)
        var publicKey: Data?
        var signature: Data?
        while let field = reader.next() {
            switch field.number {
            case 1: publicKey = field.data
            case 2: signature = field.data
            default: continue
            }
        }
        guard let publicKey, let signature else { return nil }
        return CRX3Proof(publicKey: publicKey, signature: signature)
    }
}

/// `SignedData` — the payload of `signed_header_data`. `sha256_with_rsa`
/// (field 2) is the SHA-256 digest of the ZIP archive.
private struct SignedData {
    var sha256WithRSA: Data?

    static func parse(_ bytes: Data) -> SignedData? {
        var reader = ProtoReader(bytes)
        var result = SignedData()
        while let field = reader.next() {
            if field.number == 2 { result.sha256WithRSA = field.data }
        }
        return result
    }
}
