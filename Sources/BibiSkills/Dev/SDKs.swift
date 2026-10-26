import BibiCore
import Foundation

/// An installed runtime version managed by a version manager (or a standalone JDK / system image).
public struct SDKInstall: Sendable {
    public var manager: String  // pyenv, nvm, rbenv, asdf, mise, sdkman, uv, fnm, jdk, android
    public var tool: String  // python, node, ruby, java, go...
    public var version: String
    public var path: String
    public var removable: Bool  // false for admin-owned locations (review only)
}

public enum SDKs {
    static let toolNames = PinScanner.asdfNames

    /// Every installed version bibi knows how to find.
    public static func find(home: String = Paths.home) -> [SDKInstall] {
        var out: [SDKInstall] = []
        func versions(_ dir: String, _ manager: String, _ tool: String) {
            for p in Paths.children(dir) where Paths.isDirectory(p) && !Paths.isSymlink(p) {
                let name = Paths.name(p)
                guard name.first?.isNumber == true || name.hasPrefix("v") && name.dropFirst().first?.isNumber == true else { continue }
                out.append(SDKInstall(manager: manager, tool: tool, version: name.hasPrefix("v") ? String(name.dropFirst()) : name,
                                      path: p, removable: true))
            }
        }
        versions(home + "/.pyenv/versions", "pyenv", "python")
        versions(home + "/.nvm/versions/node", "nvm", "node")
        versions(home + "/.rbenv/versions", "rbenv", "ruby")
        versions(home + "/.local/share/fnm/node-versions", "fnm", "node")
        versions(home + "/Library/Application Support/fnm/node-versions", "fnm", "node")
        for (root, manager) in [(home + "/.asdf/installs", "asdf"), (home + "/.local/share/mise/installs", "mise"),
                                (home + "/.sdkman/candidates", "sdkman")] {
            for toolDir in Paths.children(root) where Paths.isDirectory(toolDir) {
                versions(toolDir, manager, toolNames[Paths.name(toolDir)] ?? Paths.name(toolDir))
            }
        }
        // uv-managed Pythons: cpython-3.12.4-macos-aarch64-none
        for p in Paths.children(home + "/.local/share/uv/python") {
            if let m = Re.first("^cpython-([0-9.]+)", Paths.name(p)) {
                out.append(SDKInstall(manager: "uv", tool: "python", version: m[1], path: p, removable: true))
            }
        }
        for p in Paths.children("/Library/Java/JavaVirtualMachines") where Paths.ext(p) == "jdk" {
            let v = Re.first("([0-9]+(\\.[0-9.]+)?)", Paths.name(p))?[1] ?? Paths.name(p)
            out.append(SDKInstall(manager: "jdk", tool: "java", version: v, path: p, removable: false))
        }
        for api in Paths.children(home + "/Library/Android/sdk/system-images") {
            for tag in Paths.children(api) {
                for abi in Paths.children(tag) where Paths.isDirectory(abi) {
                    out.append(SDKInstall(manager: "android", tool: "android-image",
                                          version: "\(Paths.name(api))/\(Paths.name(tag))/\(Paths.name(abi))", path: abi, removable: true))
                }
            }
        }
        return out
    }

    /// Installs no project pins and that aren't a global default. Never the only version a manager has.
    public static func unused(_ installs: [SDKInstall], pins: Pins) -> [SDKInstall] {
        let groups = Dictionary(grouping: installs) { "\($0.manager)/\($0.tool)" }
        return installs.filter { i in
            guard i.tool != "android-image" else { return true }
            // System JDKs: only the non-default ones (java_home's default is added as a pin).
            return (i.manager == "jdk" || groups["\(i.manager)/\(i.tool)"]!.count > 1) && !pins.pins(i.tool, i.version)
        }
    }
}
