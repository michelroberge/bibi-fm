import Foundation
import Security

/// Code-signature facts about a program, from the Security framework (no codesign subprocess).
public struct CodeSignature: Sendable, Codable {
    public var signed: Bool
    public var valid: Bool
    public var apple: Bool  // signed by Apple (platform or App Store)
    public var adhoc: Bool
    public var teamID: String?
    public var identifier: String?

    public var summary: String {
        if !signed { return "unsigned" }
        if !valid { return "signature invalid" }
        if apple { return "signed by Apple" }
        if adhoc { return "ad-hoc signed (no developer identity)" }
        return "signed by team \(teamID ?? "?")" + (identifier.map { " (\($0))" } ?? "")
    }
}

public enum CodeSign {
    private static let cache = Mutex<[String: CodeSignature]>([:])

    /// For an executable inside an app bundle, the bundle is checked (that's what macOS checks too).
    public static func check(_ path: String) -> CodeSignature {
        var target = path
        if let r = path.range(of: ".app/Contents/MacOS/") { target = String(path[..<r.lowerBound]) + ".app" }
        if let hit = cache.withLock({ $0[target] }) { return hit }
        let sig = compute(target)
        cache.withLock { $0[target] = sig }
        return sig
    }

    static func compute(_ path: String) -> CodeSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return CodeSignature(signed: false, valid: false, apple: false, adhoc: false)
        }
        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = (infoRef as? [String: Any]) ?? [:]
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let signed = info[kSecCodeInfoIdentifier as String] != nil
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil) == errSecSuccess
        var req: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &req)
        let apple = req.map { SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), $0) == errSecSuccess } ?? false
        return CodeSignature(signed: signed, valid: valid, apple: apple,
                             adhoc: flags & 0x2 != 0,  // kSecCodeSignatureAdhoc
                             teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                             identifier: info[kSecCodeInfoIdentifier as String] as? String)
    }

    /// Path of a running process's executable.
    public static func executable(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }
}
