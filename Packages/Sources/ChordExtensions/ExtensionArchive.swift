import Foundation

/// The archive formats we accept for an extension bundle.
///
/// Both end up as a ZIP that `WKWebExtension` reads directly (its
/// `resourceBaseURL` initializer accepts "a ZIP archive containing a
/// `manifest.json` file", verified in the SDK header). So the only real work is
/// recovering the ZIP: `.xpi` already *is* one, and `.crx` is a ZIP behind a
/// signed header this strips off. No ZIP extraction of our own — see the note
/// in `ExtensionInstaller` and ADR 011.
public enum ExtensionArchiveFormat: Sendable, Equatable {
    /// Chrome's format: a `Cr24` header (CRX2 or CRX3) in front of a ZIP.
    case crx
    /// A plain ZIP — a Firefox `.xpi`, or a bare `.zip`.
    case zip
}

public enum ExtensionArchiveError: Error, Equatable, CustomStringConvertible {
    case unrecognizedFormat
    case truncatedCRXHeader
    case unsupportedCRXVersion(UInt32)
    /// The bytes at the computed ZIP offset are not a ZIP local-file header.
    case crxPayloadNotZIP

    public var description: String {
        switch self {
        case .unrecognizedFormat:
            "not a recognised extension archive (expected a CRX or a ZIP)"
        case .truncatedCRXHeader:
            "CRX header is truncated"
        case .unsupportedCRXVersion(let v):
            "unsupported CRX version \(v) (only 2 and 3 are known)"
        case .crxPayloadNotZIP:
            "CRX header stripped but the payload is not a ZIP"
        }
    }
}

/// Format detection and CRX-header stripping. Pure byte work — no file system,
/// no WebKit — so every branch is testable from a byte buffer.
public enum ExtensionArchive {
    private static let crxMagic: [UInt8] = Array("Cr24".utf8)  // 43 72 32 34
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]  // "PK\x03\x04"

    public static func detectFormat(_ data: Data) -> ExtensionArchiveFormat? {
        if data.starts(with: crxMagic) { return .crx }
        if data.starts(with: zipMagic) { return .zip }
        return nil
    }

    /// Returns the ZIP payload of an extension archive.
    ///
    /// For a `.xpi`/`.zip` this is the input unchanged. For a `.crx` it is the
    /// ZIP after the `Cr24` header (CRX3's protobuf header, or CRX2's public
    /// key + signature). All CRX header fields are little-endian uint32s.
    public static func zipPayload(from data: Data) throws -> Data {
        switch detectFormat(data) {
        case .zip:
            return data
        case .crx:
            return try stripCRXHeader(data)
        case nil:
            throw ExtensionArchiveError.unrecognizedFormat
        }
    }

    private static func stripCRXHeader(_ data: Data) throws -> Data {
        // Layout after the 4-byte "Cr24" magic:
        //   version: uint32
        //   CRX3 (version 3): headerSize: uint32, then headerSize bytes, then ZIP
        //   CRX2 (version 2): pubKeyLen: uint32, sigLen: uint32,
        //                     then pubKeyLen + sigLen bytes, then ZIP
        let version = try readUInt32(data, at: 4)
        let zipOffset: Int
        switch version {
        case 3:
            let headerSize = try readUInt32(data, at: 8)
            zipOffset = 12 + Int(headerSize)
        case 2:
            let pubKeyLen = try readUInt32(data, at: 8)
            let sigLen = try readUInt32(data, at: 12)
            zipOffset = 16 + Int(pubKeyLen) + Int(sigLen)
        default:
            throw ExtensionArchiveError.unsupportedCRXVersion(version)
        }

        guard zipOffset <= data.count else { throw ExtensionArchiveError.truncatedCRXHeader }
        let payload = data.subdata(in: zipOffset..<data.count)
        guard payload.starts(with: zipMagic) else {
            throw ExtensionArchiveError.crxPayloadNotZIP
        }
        return payload
    }

    /// Reads a little-endian uint32 at `offset`, or throws if the buffer is too
    /// short. `data` may be a slice, so index off `startIndex`.
    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        let start = data.startIndex + offset
        guard start + 4 <= data.endIndex else { throw ExtensionArchiveError.truncatedCRXHeader }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[start + i]) << (8 * i)
        }
        return value
    }
}
