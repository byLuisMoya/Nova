import Foundation
import SwiftUI
import CIOKitHID

// MARK: - Botón de ayuda "?" con tooltip estable

/// Icono "?" con tooltip PROPIO (no el `.help` nativo de AppKit).
///
/// El tooltip nativo se cierra en cuanto el `NSHostingView` recibe una
/// actualización de SwiftUI, y como los datos se refrescan cada 2 s parpadea.
/// Aquí la visibilidad la controla un `@State` de hover que el refresco de datos
/// NO toca, así que una vez abierto se queda hasta que el ratón sale del icono.
struct InfoHint: View {
    let info: String
    var compact: Bool = false

    @State private var show = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(compact ? .caption2 : .caption)
            .foregroundStyle(show ? Color.accentColor : Color.secondary)
            .onHover { hovering in show = hovering }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(info)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(10)
            }
    }
}

// MARK: - Potencia (vatios por bloque del SoC)

/// Lectura instantánea del consumo por bloque, en vatios.
struct PowerReading {
    let cpu: Double
    let gpu: Double
    let ane: Double
    let dram: Double
    var total: Double { cpu + gpu + ane + dram }

    /// Los cuatro bloques en orden de presentación. Se muestran siempre todos
    /// (aunque estén a ≈ 0 W en reposo) para que la lista no salte de tamaño.
    var components: [PowerComponent] {
        [PowerComponent(kind: .cpu,  watts: cpu),
         PowerComponent(kind: .gpu,  watts: gpu),
         PowerComponent(kind: .ane,  watts: ane),
         PowerComponent(kind: .dram, watts: dram)]
    }
}

/// Un bloque de consumo concreto (para pintar filas/barras).
struct PowerComponent: Identifiable {
    enum Kind: String, CaseIterable {
        case cpu = "CPU", gpu = "GPU", ane = "Neural Engine", dram = "Memoria"
        var symbol: String {
            switch self {
            case .cpu:  return "cpu"
            case .gpu:  return "cpu.fill"
            case .ane:  return "brain.head.profile"
            case .dram: return "memorychip"
            }
        }
        var accent: Color {
            switch self {
            case .cpu:  return .blue
            case .gpu:  return .purple
            case .ane:  return .pink
            case .dram: return .orange
            }
        }
    }
    let kind: Kind
    let watts: Double
    var id: String { kind.rawValue }
    var formatted: String { String(format: "%.2f W", watts) }
}

/// Acceso al consumo eléctrico vía IOReport ("Energy Model"). Mantiene estado
/// interno en C entre llamadas, así que debe usarse siempre desde la misma cola.
enum PowerReader {
    static func read() -> PowerReading? {
        let p = NovaReadPower()
        guard p.valid != 0 else { return nil }
        return PowerReading(cpu: max(0, p.cpu), gpu: max(0, p.gpu),
                            ane: max(0, p.ane), dram: max(0, p.dram))
    }
}

// MARK: - Ventiladores (RPM)

struct FanReading: Identifiable {
    let index: Int
    let rpm: Double
    var id: Int { index }
    var formatted: String { String(format: "%.0f RPM", rpm) }
}

enum FanReader {
    // El número de ventiladores no cambia en caliente: se consulta una sola vez.
    private static let cachedCount = max(0, Int(NovaFanCount()))

    /// Número de ventiladores (0 en equipos sin ventilador, como los Air).
    static func count() -> Int { cachedCount }

    /// Lee las RPM actuales de todos los ventiladores presentes.
    static func read() -> [FanReading] {
        let n = cachedCount
        guard n > 0 else { return [] }
        var out: [FanReading] = []
        for i in 0..<n {
            let rpm = NovaFanRPM(Int32(i))
            if rpm >= 0 { out.append(FanReading(index: i, rpm: rpm)) }
        }
        return out
    }
}

// MARK: - Presión térmica (estado del sistema)

/// Estado térmico global que reporta macOS (`ProcessInfo.thermalState`).
/// Indica si el sistema está aplicando throttling por temperatura.
enum ThermalPressure {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:  self = .nominal
        case .fair:     self = .fair
        case .serious:  self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    static var current: ThermalPressure {
        ThermalPressure(ProcessInfo.processInfo.thermalState)
    }

    var label: String {
        switch self {
        case .nominal:  return "Normal"
        case .fair:     return "Moderado"
        case .serious:  return "Alto"
        case .critical: return "Crítico"
        }
    }

    /// Explicación mostrada en el tooltip.
    var info: String {
        switch self {
        case .nominal:
            return "El sistema no está limitado por temperatura."
        case .fair:
            return "Temperatura ligeramente elevada; el sistema empieza a "
                + "gestionar el consumo."
        case .serious:
            return "El sistema está reduciendo el rendimiento (throttling) para "
                + "bajar la temperatura."
        case .critical:
            return "Throttling agresivo: el rendimiento está muy limitado para "
                + "proteger el hardware."
        }
    }

    var color: Color {
        switch self {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .nominal:  return "checkmark.circle.fill"
        case .fair:     return "thermometer.medium"
        case .serious:  return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}
