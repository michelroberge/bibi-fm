import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256(file path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension Hashing {
    /// First 12 hex characters of the SHA-256 of a string: stable ids for facts and intents.
    public static func short(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
