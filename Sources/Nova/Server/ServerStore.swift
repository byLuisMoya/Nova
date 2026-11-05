import AppKit
import Combine
import Foundation

enum ServerChartRange: String, CaseIterable { case short = "30 min", long = "24 h" }
enum ServerTab: Hashable { case system, docker, processes }

/// Estado de un servidor remoto: consulta su agente cada `pollInterval` segundos y prueba sus
/// direcciones en orden hasta que una responde. Vive en el AppDelegate (no en la vista), porque
/// el icono de la barra de menú necesita el dato aunque el desplegable esté cerrado.
final class ServerStore: ObservableObject, Identifiable {
    @Published private(set) var snapshot: ServerSnapshot?
    @Published private(set) var lastOK: Date?
    @Published private(set) var online = false
    @Published private(set) var connecting = true
    @Published private(set) var longHistory: ServerSeries?
    @Published var tab: ServerTab = .system
    @Published var range: ServerChartRange = .short {
        didSet { if range == .long { refreshLong(force: true) } }
    }

    let config: ServerConfig
    var id: String { config.id }
    var name: String { config.name }

    private let pollInterval: TimeInterval = 5
    private var activeHost: URL?
    private var inFlight = false
    private var longFetchedAt: Date?
    private var timer: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2.5
        c.timeoutIntervalForResource = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(config: ServerConfig) {
        self.config = config
    }

    var series: ServerSeries? { range == .short ? snapshot?.history : longHistory }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = pollInterval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        Task { @MainActor in
            await poll()
            inFlight = false
        }
    }

    private var candidates: [URL] {
        var hosts = config.hosts.compactMap(URL.init(string:))
        if let a = activeHost, let i = hosts.firstIndex(of: a) { hosts.insert(hosts.remove(at: i), at: 0) }
        return hosts
    }

    @MainActor
    private func poll() async {
        for host in candidates {
            if let s: ServerSnapshot = try? await get(host, path: "api/v1/snapshot") {
                snapshot = s
                lastOK = Date()
                if !online { online = true }
                if connecting { connecting = false }
                activeHost = host
                if range == .long { refreshLong(force: false) }
                return
            }
        }
        if online { online = false }
        if connecting { connecting = false }
    }

    private func refreshLong(force: Bool) {
        guard let host = activeHost else { return }
        if !force, let at = longFetchedAt, Date().timeIntervalSince(at) < 60 { return }
        longFetchedAt = Date()
        Task { @MainActor in
            if let h: ServerSeries = try? await get(host, path: "api/v1/history", query: "range=24h") { longHistory = h }
        }
    }

    private func get<T: Decodable>(_ host: URL, path: String, query: String? = nil) async throws -> T {
        guard var comps = URLComponents(url: host.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        comps.query = query
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decoder.decode(T.self, from: data)
    }

    func openTerminal() {
        guard let ssh = config.ssh, let url = URL(string: ssh) else { return }
        NSWorkspace.shared.open(url)
    }
}
