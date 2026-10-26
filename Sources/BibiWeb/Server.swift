import BibiCore
import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// The local web UI: static pages plus a JSON API over the same Harness the terminal uses.
/// Bound to 127.0.0.1 only; every API call needs the per-launch token, and requests whose Host or Origin
/// isn't this server are refused (DNS rebinding, cross-site requests).
public struct WebServer: Sendable {
    let harness: Harness
    let token: String

    public init(harness: Harness, token: String = WebServer.makeToken()) {
        self.harness = harness
        self.token = token
    }

    public static func makeToken() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static var staticRoot: String? {
        Bundle.module.resourceURL?.appendingPathComponent("Static").path
    }

    public func serve(port: Int, openBrowser: Bool, initialRun: [String]?) async throws {
        let manager = RunManager(harness: harness)
        let router = makeRouter(manager: manager)
        let token = token
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: nil),
            onServerRunning: { channel in
                guard let port = channel.localAddress?.port else { return }
                var path = "/"
                if let argv = initialRun, let name = argv.first, let skill = harness.skill(named: name) {
                    var rest = Array(argv.dropFirst()), online: Bool?
                    if let i = rest.firstIndex(of: "--online") { rest.remove(at: i); online = true }
                    do {
                        let id = try await manager.start(skill, argv: rest, online: online, since: nil, verbose: false)
                        path = "/#/run/\(id)"
                    } catch {
                        print("bibi: \(error)")
                    }
                }
                let url = "http://127.0.0.1:\(port)/?token=\(token)\(path.hasPrefix("/#") ? String(path.dropFirst()) : "")"
                print("bibi web UI: \(url)\nPress Ctrl-C to stop.")
                if openBrowser { _ = await Command.run(["open", url]) }
            },
            logger: {
                var l = Logger(label: "bibi")
                l.logLevel = .warning
                return l
            }()
        )
        try await app.runService()
    }

    public func makeRouter(manager: RunManager) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: Guard(token: token))
        if let root = Self.staticRoot {
            var quiet = Logger(label: "bibi.files")
            quiet.logLevel = .warning
            router.add(middleware: FileMiddleware(root, searchForIndexHtml: true, logger: quiet))
        }
        let api = API(harness: harness, manager: manager)
        api.register(router.group("api"))
        return router
    }
}

/// Host/Origin checks for everything; the token for /api.
struct Guard: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: String

    static func isLocal(_ hostPort: String) -> Bool {
        let host = hostPort.split(separator: ":").first.map(String.init) ?? ""
        return host == "127.0.0.1" || host == "localhost"
    }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let host = request.head.authority, Self.isLocal(host) else {
            throw HTTPError(.forbidden, message: "bad host")
        }
        if let origin = request.headers[.origin], origin != "null" {
            guard let u = URL(string: origin), let h = u.host(), Self.isLocal(h) else { throw HTTPError(.forbidden, message: "bad origin") }
        }
        if request.uri.path.hasPrefix("/api/") {
            let given = request.headers[HTTPField.Name("X-Bibi-Token")!] ?? request.uri.queryParameters["token"].map(String.init)
            guard given == token else { throw HTTPError(.unauthorized, message: "missing or wrong token") }
        }
        var response = try await next(request, context)
        response.headers[.cacheControl] = "no-store"
        response.headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        response.headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:"
        return response
    }
}
