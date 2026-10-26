import BibiCore
import Foundation

public enum Docker {
    public struct Image: Sendable {
        public var id: String
        public var repository: String
        public var tag: String
        public var bytes: Int
        public var created: String
        public var name: String { repository == "<none>" ? id : "\(repository):\(tag)" }
        public var dangling: Bool { repository == "<none>" }
    }

    public struct Volume: Sendable {
        public var name: String
        public var bytes: Int
        public var links: Int
    }

    public struct Usage: Sendable {
        public var images: [Image] = []
        public var usedImages: Set<String> = []  // repo:tag or id prefixes referenced by any container
        public var danglingVolumes: [Volume] = []
        public var buildCacheBytes = 0
        public var sources: [String] = []
    }

    /// "1.21GB", "512MB", "12.3kB", "0B" (docker uses decimal units) -> bytes.
    public static func bytes(_ s: String) -> Int {
        guard let m = Re.first("^([0-9.]+)\\s*([kKMGT]?B)", s.trimmingCharacters(in: .whitespaces)), let n = Double(m[1]) else { return 0 }
        let mult: [String: Double] = ["B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
        return Int(n * (mult[m[2]] ?? 1))
    }

    static func jsonLines(_ text: String) -> [JSONValue] {
        text.split(separator: "\n").compactMap { try? JSON.decode(JSONValue.self, from: String($0)) }
    }

    public static func parseImages(_ text: String) -> [Image] {
        jsonLines(text).map {
            Image(id: $0["ID"]?.string ?? "", repository: $0["Repository"]?.string ?? "<none>", tag: $0["Tag"]?.string ?? "<none>",
                  bytes: bytes($0["Size"]?.string ?? "0B"), created: $0["CreatedSince"]?.string ?? "")
        }
    }

    public static func parseContainers(_ text: String) -> Set<String> {
        Set(jsonLines(text).compactMap { $0["Image"]?.string })
    }

    public static func parseDF(_ text: String) -> (volumes: [Volume], buildCache: Int) {
        guard let v = jsonLines(text).first else { return ([], 0) }
        let volumes = (v["Volumes"]?.array ?? []).map {
            Volume(name: $0["Name"]?.string ?? "", bytes: bytes($0["Size"]?.string ?? "0B"), links: Int($0["Links"]?.string ?? "") ?? $0["Links"]?.int ?? 0)
        }
        let cache = (v["BuildCache"]?.array ?? []).filter { $0["InUse"]?.bool != true && $0["InUse"]?.string != "true" }
            .map { bytes($0["Size"]?.string ?? "0B") }.reduce(0, +)
        return (volumes, cache)
    }

    public static func isUsed(_ image: Image, by used: Set<String>) -> Bool {
        used.contains(image.name) || used.contains(image.repository) && image.tag == "latest"
            || used.contains { !image.id.isEmpty && ($0.hasPrefix(image.id) || image.id.hasPrefix($0)) }
    }

    public static func collect() async -> Usage? {
        guard Tools.available("docker") else { return nil }
        async let images = Command.run(["docker", "images", "--format", "{{json .}}"], timeout: 60)
        async let containers = Command.run(["docker", "ps", "-a", "--format", "{{json .}}"], timeout: 60)
        async let df = Command.run(["docker", "system", "df", "-v", "--format", "{{json .}}"], timeout: 120)
        let i = await images, c = await containers, d = await df
        var u = Usage()
        u.images = parseImages(i.stdout)
        u.usedImages = parseContainers(c.stdout)
        let parsed = parseDF(d.stdout)
        u.danglingVolumes = parsed.volumes.filter { $0.links == 0 }
        u.buildCacheBytes = parsed.buildCache
        u.sources = [i.source, c.source, d.source]
        return u
    }
}

/// `docker rmi` for an image no container uses.
public struct DockerImageRemove: ActionSpec {
    public let id = "docker_image_rm"
    public let summary = "Remove a Docker image that no container uses"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let image = try require(p, "image")
        guard Re.test("^(sha256:)?[0-9a-f]{12,64}$", image) else { throw ActionError("not an image id: \(image)") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["docker rmi \(p["image"]!)   (cannot be undone; docker pull or a rebuild gets it back)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let image = p["image"]!
        let users = await Command.run(["docker", "ps", "-a", "-q", "--filter", "ancestor=\(image)"], timeout: 30)
        guard users.ok, users.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionError("a container still uses image \(image)")
        }
        try await Command.run(["docker", "rmi", image], timeout: 300).check()
        return Outcome("removed image \(image)")
    }
}

/// `docker volume rm` for a volume no container references. Volumes can hold real data, so this is never rated very safe.
public struct DockerVolumeRemove: ActionSpec {
    public let id = "docker_volume_rm"
    public let summary = "Remove a Docker volume no container uses (its data is lost)"

    public func validate(_ p: Params, _ env: ActionEnv) throws {
        let name = try require(p, "volume")
        guard Re.test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$", name) else { throw ActionError("not a volume name: \(name)") }
    }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["docker volume rm \(p["volume"]!)   (deletes the data in it; cannot be undone)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let name = p["volume"]!
        let dangling = await Command.run(["docker", "volume", "ls", "-q", "--filter", "dangling=true"], timeout: 30)
        guard dangling.lines.contains(name) else { throw ActionError("volume \(name) is in use or gone") }
        try await Command.run(["docker", "volume", "rm", name], timeout: 120).check()
        return Outcome("removed volume \(name)")
    }
}

public struct DockerBuilderPrune: ActionSpec {
    public let id = "docker_builder_prune"
    public let summary = "Remove Docker's unused build cache"
    public func validate(_ p: Params, _ env: ActionEnv) throws {
        guard Tools.available("docker") else { throw ActionError("docker is not running") }
    }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["docker builder prune -f   (builds get slower until the cache refills)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let out = try await Command.run(["docker", "builder", "prune", "-f"], timeout: 600).check()
        return Outcome(out.lines.last ?? "pruned the build cache")
    }
}
