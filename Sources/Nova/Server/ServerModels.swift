import Foundation

/// Respuesta de `GET /api/v1/snapshot` de nova-server (ver `nova-server/src/model.rs`).
/// Todo es opcional salvo `host` y `ts`: el agente omite lo que aún no ha medido.
struct ServerSnapshot: Decodable {
    let host: String
    let ts: Double
    let cpu: CPU?
    let temp: Temp?
    let power: Power?
    let gpu: [GPU]?
    let memory: Memory?
    let load: [Double]?
    let uptimeS: Double?
    let processes: [Proc]?
    let filesystems: [Filesystem]?
    let docker: Docker?
    let services: [Service]?
    let events: Events?
    let disks: [Disk]?
    let history: ServerSeries?

    struct CPU: Decodable { let percent: Double?; let mhz: Double?; let cores: Int?; let model: String? }
    struct Temp: Decodable { let cpu: Double?; let fanRpm: Double? }
    struct Power: Decodable { let watts: Double?; let cpuWatts: Double?; let available: Bool? }
    struct GPU: Decodable, Identifiable {
        let name: String; let driver: String?; let integrated: Bool?; let state: String
        var id: String { name }
    }
    struct Memory: Decodable { let total: Double; let used: Double; let swapTotal: Double; let swapUsed: Double }
    struct Proc: Decodable, Identifiable {
        let pid: Int; let user: String; let name: String; let cpu: Double; let memBytes: Double; let command: String
        var id: Int { pid }
    }
    struct Filesystem: Decodable, Identifiable {
        let label: String; let mount: String; let total: Double; let used: Double
        var id: String { mount }
    }
    struct Docker: Decodable { let available: Bool; let containers: [Container] }
    struct Container: Decodable, Identifiable {
        let name: String; let image: String; let state: String; let status: String
        let cpu: Double?; let memBytes: Double?; let memPercent: Double?
        var id: String { name }
    }
    struct Service: Decodable, Identifiable { let name: String; let ok: Bool?; var id: String { name } }
    struct Events: Decodable { let eccCe: Int?; let eccUe: Int?; let oom: Int?; let throttle: Int? }
    struct Disk: Decodable, Identifiable {
        let name: String; let model: String?; let rotational: Bool?; let temp: Double?; let hours: Double?
        let wear: Double?; let passed: Bool?; let selfTest: String?; let standby: Bool?; let checkedAgoS: Double?
        var id: String { name }
    }
}

/// Serie temporal del agente: columnas paralelas, con `nil` donde no hubo lectura.
struct ServerSeries: Decodable {
    let t: [Double]
    let cpu: [Double?]
    let temp: [Double?]
    let power: [Double?]

    struct Point: Identifiable {
        let date: Date
        let value: Double
        let segment: Int
        /// Posición en la serie, no el instante: Swift Charts guarda cada `id` que ve, y con
        /// un id por instante ese diccionario crecería sin límite (ver `HistoryPoint`).
        let index: Int
        var id: Int { index }
    }

    /// Puntos sin nulos; un hueco de más de `gap` segundos (servidor apagado) abre un segmento,
    /// para que la línea no una el antes y el después del apagado.
    func points(_ values: [Double?], gap: Double) -> [Point] {
        var out: [Point] = []
        var segment = 0
        var last: Double?
        for (i, t) in t.enumerated() where i < values.count {
            guard let v = values[i] else { continue }
            if let l = last, t - l > gap { segment += 1 }
            last = t
            out.append(Point(date: Date(timeIntervalSince1970: t), value: v, segment: segment, index: out.count))
        }
        return out
    }
}

/// Servidores configurados en `~/Library/Application Support/Nova/servers.json`.
/// Sin ese fichero Nova no muestra nada de servidores.
struct ServerConfig: Codable, Identifiable {
    /// Nombre visible (selector e icono de la barra de menú).
    var name: String
    /// URLs base `https://` del agente, por orden de preferencia (p. ej. la IP local y la de Tailscale).
    var hosts: [String]
    var token: String
    /// SHA-256 (hex) del certificado del servidor. Nova solo acepta ese certificado.
    var fingerprint: String?
    /// URL `ssh://usuario@host:puerto` que abre el botón de terminal.
    var ssh: String?

    var id: String { name }

    private struct File: Codable { var servers: [ServerConfig] }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nova/servers.json")
    }

    static func loadAll() -> [ServerConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            // El nombre hace de id (selector, clic en la barra): uno repetido se ignora.
            var seen = Set<String>()
            return try JSONDecoder().decode(File.self, from: data).servers.filter { seen.insert($0.name).inserted }
        } catch {
            NSLog("Nova: \(fileURL.path) no es válido: \(error)")
            return []
        }
    }
}
