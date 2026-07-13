import SwiftUI
import AppKit

// MARK: - Color adaptativo claro/oscuro

extension Color {
    /// Color que resuelve a `light` u `dark` según la apariencia del sistema.
    /// Necesario porque los colores "crudos" del sistema (`.green`, `.yellow`)
    /// están pensados para fondo oscuro y pierden contraste en modo claro.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
    }

    // Paleta de estado compartida (severidad de temperatura y presión térmica),
    // para que el mismo nivel tenga el mismo color en toda la app. En claro,
    // tonos más oscuros/saturados con buen contraste; en oscuro, los vivos.
    static let statusGreen  = Color(light: Color(red: 0.16, green: 0.53, blue: 0.24), dark: .green)
    static let statusAmber  = Color(light: Color(red: 0.72, green: 0.47, blue: 0.00), dark: .yellow)
    static let statusOrange = Color(light: Color(red: 0.85, green: 0.38, blue: 0.02), dark: .orange)
    static let statusRed    = Color(light: Color(red: 0.80, green: 0.16, blue: 0.13), dark: .red)
}

// MARK: - Severidad / color

/// Nivel de severidad según la temperatura, con su color asociado.
/// Regla: verde < 55 °C · amarillo 55–70 °C · rojo > 70 °C.
enum Severity {
    case normal   // < 55 °C  → verde
    case warm     // 55–70 °C → amarillo
    case hot      // > 70 °C  → rojo

    init(value: Double) {
        if value < 55 {
            self = .normal
        } else if value <= 70 {
            self = .warm
        } else {
            self = .hot
        }
    }

    var color: Color {
        switch self {
        case .normal: return .statusGreen
        case .warm:   return .statusAmber
        case .hot:    return .statusRed
        }
    }
}

// MARK: - Categoría lógica

/// Componente lógico al que pertenece un sensor.
enum SensorCategory: String, CaseIterable, Identifiable {
    case cpu     = "CPU"
    case gpu     = "GPU"
    case soc     = "SoC"
    case battery = "Batería"
    case ssd     = "SSD"
    case other   = "Otros"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cpu:     return "cpu"
        case .gpu:     return "cpu.fill"
        case .soc:     return "memorychip"
        case .battery: return "battery.100"
        case .ssd:     return "internaldrive"
        case .other:   return "thermometer.medium"
        }
    }

    /// Color estable de la serie en las gráficas de historial (no depende de la
    /// temperatura; para eso está la codificación por severidad en los textos).
    var accent: Color {
        switch self {
        case .cpu:     return .blue
        case .gpu:     return .purple
        case .soc:     return .teal
        case .battery: return .green
        case .ssd:     return .orange
        case .other:   return .gray
        }
    }

    /// Descripción breve mostrada en el tooltip del icono "?".
    var info: String {
        switch self {
        case .cpu:
            return "CPU: núcleos del procesador. En Apple Silicon se dividen en "
                + "núcleos de rendimiento (P) y de eficiencia (E)."
        case .gpu:
            return "GPU: procesador gráfico, integrado en el mismo chip."
        case .soc:
            return "SoC (System on Chip): el chip Apple (M1–M5) completo, que "
                + "integra CPU, GPU, Neural Engine y controlador de memoria en "
                + "una sola pastilla. Estos sensores (PMU / tdie / tcal) miden la "
                + "temperatura global del chip, no de un bloque concreto."
        case .battery:
            return "Batería: temperatura medida por el controlador de carga "
                + "(gas gauge) de la batería."
        case .ssd:
            return "SSD: almacenamiento flash (NAND) del disco interno."
        case .other:
            return "Otros sensores del sistema no clasificados en las categorías "
                + "anteriores."
        }
    }

    /// Clasifica un nombre de sensor HID crudo en un componente lógico.
    /// Los nombres varían entre generaciones de chip, así que se basa en
    /// subcadenas frecuentes y se aplica por orden de prioridad.
    static func classify(_ rawName: String) -> SensorCategory {
        let n = rawName.lowercased()
        if n.contains("batt") || n.contains("gas gauge") { return .battery }
        if n.contains("nand") || n.contains("ssd") || n.contains("flash") { return .ssd }
        if n.contains("gpu") { return .gpu }
        if n.contains("cpu") || n.contains("pacc") || n.contains("ecpu")
            || n.contains("pcpu") || n.contains("core") || n.contains("efficiency")
            || n.contains("performance") { return .cpu }
        if n.contains("soc") || n.contains("pmgr") || n.contains("pmu")
            || n.contains("ane") || n.contains("tdie") || n.contains("tdev")
            || n.contains("mtr") || n.contains("die") { return .soc }
        return .other
    }
}

// MARK: - Sensor individual

struct TemperatureSensor: Identifiable {
    let name: String
    let value: Double
    let category: SensorCategory

    // Identidad ESTABLE por nombre (los sensores HID tienen nombre único). Usar
    // un UUID nuevo por refresco haría que SwiftUI recreara todas las filas cada
    // 2 s, provocando relayouts que cierran los tooltips (.help) al pasar el ratón.
    var id: String { name }

    var severity: Severity { Severity(value: value) }
}

// MARK: - Grupo por componente

struct SensorGroup: Identifiable {
    let category: SensorCategory
    let sensors: [TemperatureSensor]

    var id: String { category.id }

    var maxValue: Double { sensors.map(\.value).max() ?? 0 }

    var avgValue: Double {
        guard !sensors.isEmpty else { return 0 }
        return sensors.map(\.value).reduce(0, +) / Double(sensors.count)
    }

    /// La severidad del grupo se basa en su valor máximo.
    var severity: Severity { Severity(value: maxValue) }

    /// Construye los grupos a partir de una lista plana de sensores,
    /// respetando el orden canónico de las categorías.
    static func build(from sensors: [TemperatureSensor]) -> [SensorGroup] {
        let grouped = Dictionary(grouping: sensors, by: \.category)
        return SensorCategory.allCases.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return SensorGroup(category: category,
                               sensors: items.sorted { $0.value > $1.value })
        }
    }
}
