import SwiftUI
import Combine

// MARK: - Unidad de temperatura

/// Unidad en que se MUESTRA la temperatura. Los sensores siempre se leen y se
/// almacenan en °C; la conversión es solo de presentación (la severidad y sus
/// colores se siguen calculando sobre los °C reales).
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var symbol: String { self == .celsius ? "°C" : "°F" }

    /// Convierte un valor en °C a la unidad seleccionada.
    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9.0 / 5.0 + 32.0
    }

    /// Formatea un valor en °C. Con `unit` añade el sufijo (°C/°F); sin él, solo
    /// el grado (para sitios compactos como la barra de menú).
    func format(_ celsius: Double, unit: Bool = true) -> String {
        String(format: unit ? "%.0f%@" : "%.0f°",
               convert(celsius), unit ? symbol : "")
    }
}

// MARK: - Ajustes de la app (persistidos en UserDefaults)

/// Preferencias del usuario. Singleton observable; los cambios se guardan al
/// instante y las vistas que lo observan (`@EnvironmentObject`) se refrescan.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let unitKey = "temperatureUnit"

    @Published var unit: TemperatureUnit {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey) }
    }

    /// Autoarranque en cada inicio de sesión. NO se persiste en UserDefaults: la
    /// fuente de verdad es si existe el LaunchAgent (`LoginItemManager`), así que
    /// refleja también el que pueda haber instalado `install.sh`. Por defecto es
    /// `false` en instalaciones por Homebrew (que no crean el LaunchAgent).
    @Published private(set) var launchAtLogin: Bool

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.unitKey)
        unit = raw.flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        launchAtLogin = LoginItemManager.isEnabled
    }

    /// Cambia el autoarranque y re-lee el estado real (si falla, revierte solo).
    func setLaunchAtLogin(_ enabled: Bool) {
        try? LoginItemManager.setEnabled(enabled)
        launchAtLogin = LoginItemManager.isEnabled
    }
}

// MARK: - Ventana de preferencias

struct PreferencesView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferencias")
                .font(.title3.weight(.semibold))

            HStack {
                Text("Unidad de temperatura")
                Spacer()
                Picker("", selection: $settings.unit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Text("Los sensores se leen en °C; el cambio de unidad solo afecta a "
                 + "cómo se muestra. Los colores por severidad no cambian.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Abrir al iniciar sesión")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Text("Instala un LaunchAgent para que Nova arranque sola en cada "
                 + "inicio de sesión. Tiene efecto a partir del próximo login.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 280)
    }
}
