import CryptoKit
import Foundation

enum ProLicenseValidator {
    static func normalize(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    static func isValid(_ key: String) -> Bool {
        let normalized = normalize(key)
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0] == "WWB",
              parts[1] == "PRO",
              parts[2].count == 4,
              parts[3].count == 4,
              parts[4].count == 4,
              parts.dropFirst(2).allSatisfy(isAlphaNumeric) else {
            return false
        }
        return parts[4] == checksum(for: parts.prefix(4).joined(separator: "-"))
    }

    private static func checksum(for payload: String) -> String {
        let digest = SHA256.hash(data: Data("\(payload)-3XHAUST".utf8))
        return digest.prefix(2).map { String(format: "%02X", $0) }.joined()
    }

    private static func isAlphaNumeric(_ part: Substring) -> Bool {
        part.allSatisfy { character in
            character.isASCII && (character.isNumber || character.isLetter)
        }
    }
}
