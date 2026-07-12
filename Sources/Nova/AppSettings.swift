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

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.unitKey)
        unit = raw.flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
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

            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 180)
    }
}
