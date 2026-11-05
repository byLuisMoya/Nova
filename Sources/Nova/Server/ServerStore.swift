import AppKit
import Combine
import CryptoKit
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
    /// Motivo por el que no se puede conectar aunque el servidor responda (certificado, emparejado).
    @Published private(set) var problem: String?
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
    private let pinning: CertificatePinning
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(config: ServerConfig) {
        self.config = config
        pinning = CertificatePinning(fingerprint: config.fingerprint ?? "")
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2.5
        c.timeoutIntervalForResource = 4
        c.waitsForConnectivity = false
        session = URLSession(configuration: c, delegate: pinning, delegateQueue: nil)
        if config.fingerprint?.isEmpty ?? true {
            problem = "Falta la huella del certificado. Vuelve a emparejar con nova-server/deploy.sh --pair."
        }
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

    /// Solo `https://`: sin cifrado el token viajaría en claro, así que un host `http://` se ignora.
    private var candidates: [URL] {
        var hosts = config.hosts.compactMap(URL.init(string:)).filter { $0.scheme == "https" }
        if let a = activeHost, let i = hosts.firstIndex(of: a) { hosts.insert(hosts.remove(at: i), at: 0) }
        return hosts
    }

    @MainActor
    private func poll() async {
        guard !(config.fingerprint?.isEmpty ?? true) else {
            if connecting { connecting = false }
            return
        }
        pinning.mismatch = false
        for host in candidates {
            if let s: ServerSnapshot = try? await get(host, path: "api/v1/snapshot") {
                snapshot = s
                lastOK = Date()
                if !online { online = true }
                if connecting { connecting = false }
                activeHost = host
                if problem != nil { problem = nil }
                if range == .long { refreshLong(force: false) }
                return
            }
        }
        if online { online = false }
        if connecting { connecting = false }
        let mismatch = pinning.mismatch
            ? "El certificado del servidor no coincide con el emparejado. Si lo has reinstalado, vuelve a emparejar con nova-server/deploy.sh --pair."
            : nil
        if problem != mismatch { problem = mismatch }
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

/// Acepta solo el certificado cuya huella SHA-256 se guardó al emparejar. No hay CA de por medio:
/// el certificado lo genera el propio servidor y la huella llega al Mac por SSH.
final class CertificatePinning: NSObject, URLSessionDelegate {
    private let fingerprint: String
    private let lock = NSLock()
    private var _mismatch = false

    /// Si la última petición se cortó porque el servidor presentó otro certificado.
    var mismatch: Bool {
        get { lock.withLock { _mismatch } }
        set { lock.withLock { _mismatch = newValue } }
    }

    init(fingerprint: String) {
        self.fingerprint = fingerprint.lowercased()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              !fingerprint.isEmpty
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if hex == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            mismatch = true
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
