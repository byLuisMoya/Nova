import Foundation

/// Gestiona el autoarranque en cada inicio de sesión escribiendo (o borrando)
/// un LaunchAgent en `~/Library/LaunchAgents`, **sin depender de firma** (a
/// diferencia de `SMAppService`, que exige un binario firmado y que con firma
/// ad-hoc es dudoso).
///
/// Usa el mismo `Label` y la misma ruta que el LaunchAgent que instala
/// `install.sh`, así que ambos son intercambiables: si el usuario instaló por
/// GitHub, `isEnabled` ya devolverá `true`, y este gestor puede desactivarlo.
///
/// Diseño deliberado:
///  - **Activar** solo escribe el `.plist`. launchd carga automáticamente los
///    agentes de `~/Library/LaunchAgents` en el próximo inicio de sesión, así
///    que NO hacemos `launchctl bootstrap` (evita lanzar una segunda instancia
///    encima de la que ya está corriendo).
///  - **Desactivar** solo borra el `.plist`. NO hacemos `launchctl bootout`
///    (si la app actual la arrancó launchd, `bootout` la cerraría de golpe).
///    Sin `KeepAlive`, el trabajo cargado no se relanza al salir, y al faltar
///    el fichero no volverá a arrancar en el siguiente login.
enum LoginItemManager {
    private static let label = "io.github.byluismoya.Nova"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// ¿Está activo el autoarranque? Se deduce de la existencia del LaunchAgent,
    /// que es la única fuente de verdad (no un booleano en UserDefaults).
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Activa o desactiva el autoarranque. Lanza si no se puede escribir/borrar.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try enable() } else { try disable() }
    }

    private static func enable() throws {
        let dir = agentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plistContents().write(to: agentURL, atomically: true, encoding: .utf8)
    }

    private static func disable() throws {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        try FileManager.default.removeItem(at: agentURL)
    }

    /// Ruta real del ejecutable dentro del bundle en ejecución (funciona igual
    /// esté la app en `/Applications` —instalación por brew— o en
    /// `~/Applications` —install.sh—).
    private static func executablePath() -> String {
        Bundle.main.executableURL?.path
            ?? (Bundle.main.bundlePath + "/Contents/MacOS/Nova")
    }

    private static func plistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath())</string>
            </array>
            <key>RunAtLoad</key>        <true/>
            <key>ProcessType</key>      <string>Interactive</string>
            <key>LimitLoadToSessionType</key> <string>Aqua</string>
        </dict>
        </plist>
        """
    }
}
