// © 2026 High Gain Design. All rights reserved.
import Foundation
import CryptoKit

public enum SharedLibraryIdentityError: Error, Equatable, Sendable {
    case invalidRelativePath
    case invalidSourceFingerprint
}

/// IDs are scoped by library binding, not by a Mac's absolute storage path.
public enum SharedLibraryIdentity {
    public static func legacy(relativePath: String) throws -> UUID {
        let path = try normalized(relativePath)
        return identifier("DockTape.legacy.v1\0" + path)
    }

    /// The caller must have verified this source MD5 against an actual transfer.
    /// Syntax checks cannot establish provenance of a checksum returned by USB.
    public static func deviceImport(filename: String, sourceMD5: String) throws -> UUID {
        let path = try normalized(filename)
        guard !path.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
        let fingerprint = sourceMD5.lowercased()
        guard fingerprint.utf8.count == 32,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              fingerprint.contains(where: { $0 != "0" }) else {
            throw SharedLibraryIdentityError.invalidSourceFingerprint
        }
        return identifier("DockTape.device-import.v1\0" + path + "\0" + fingerprint)
    }

    public static func normalized(_ relativePath: String) throws -> String {
        let path = relativePath.precomposedStringWithCanonicalMapping
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            throw SharedLibraryIdentityError.invalidRelativePath
        }
        return path
    }

    private static func identifier(_ input: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        // RFC 9562 version8 identifies this application-defined hash scheme.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
