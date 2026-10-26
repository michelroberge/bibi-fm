import Foundation

public enum Plist {
    /// Reads a property list (XML or binary) as a dictionary, or nil if unreadable.
    public static func read(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
