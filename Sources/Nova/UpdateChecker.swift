import Foundation
import Combine

/// Comprueba si hay una versión de Nova más nueva publicada en GitHub Releases.
///
/// Nova no se autoactualiza: solo avisa (icono en la cabecera del desplegable) y
/// enlaza a la release. Consulta la API pública de GitHub al arrancar y cada
/// `interval`, sin token (el límite anónimo de 60 peticiones/h sobra).
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Versión más nueva disponible (p. ej. "1.5"), o `nil` si estamos al día.
    @Published private(set) var availableVersion: String?
    /// Página de la release más reciente.
    @Published private(set) var releaseURL = URL(string: "https://github.com/byLuisMoya/Nova/releases/latest")!

    private static let apiURL = URL(string: "https://api.github.com/repos/byLuisMoya/Nova/releases/latest")!
    private let interval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    /// Versión del bundle en ejecución. Sin bundle (binario suelto de
    /// `swift build`) no hay versión que comparar y no se comprueba nada.
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    func start() {
        guard currentVersion != nil, timer == nil else { return }
        check()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    private func check() {
        guard let current = currentVersion else { return }
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        // Sesión efímera: sin caché en disco ni cookies para una consulta tan pequeña.
        URLSession(configuration: .ephemeral).dataTask(with: request) { [weak self] data, _, _ in
            // Sin red o respuesta inesperada: se ignora y se reintenta en el próximo ciclo.
            guard let data, let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            let newer = Self.isVersion(latest, newerThan: current) ? latest : nil
            DispatchQueue.main.async {
                self?.availableVersion = newer
                self?.releaseURL = release.html_url
            }
        }.resume()
    }

    /// Compara versiones numéricas por componentes ("1.10" > "1.9").
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
