import Foundation
import Darwin

/// Genera un informe de diagnóstico con la lista cruda de todos los sensores de
/// temperatura, su valor y la categoría en que los clasifica la app. Sirve para
/// saber qué expone un chip concreto (p. ej. si un M3/M4 publica sensores de
/// CPU/GPU o solo de SoC) y ajustar la clasificación.
enum Diagnostics {

    /// Construye el informe como texto plano.
    static func buildReport() -> String {
        let raw = SensorReader.readTemperatureSensors()

        var out = ""
        out += "Nova — Diagnóstico de sensores de temperatura\n"
        out += "================================================\n"
        out += "Fecha:     \(timestamp())\n"
        out += "Chip:      \(sysctlString("machdep.cpu.brand_string"))\n"
        out += "macOS:     \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Sensores:  \(raw.count)\n\n"

        guard !raw.isEmpty else {
            out += "No se encontraron sensores.\n"
            out += "(¿App Sandbox activo, o no es un Mac con Apple Silicon?)\n"
            return out
        }

        // Detalle por sensor, ordenado por temperatura.
        out += "Detalle (ordenado por temperatura):\n"
        out += "-----------------------------------\n"
        for s in raw.sorted(by: { $0.value > $1.value }) {
            let category = SensorCategory.classify(s.name)
            out += "\(pad(s.name, 34)) \(String(format: "%6.1f", s.value))°C   [\(category.rawValue)]\n"
        }

        // Resumen por componente.
        out += "\nResumen por componente:\n"
        out += "-----------------------\n"
        let sensors = raw.map {
            TemperatureSensor(name: $0.name,
                              value: $0.value,
                              category: SensorCategory.classify($0.name))
        }
        for g in SensorGroup.build(from: sensors) {
            out += "\(pad(g.category.rawValue, 8)) x\(g.sensors.count)"
            out += "   máx \(String(format: "%.1f", g.maxValue))°C"
            out += "   med \(String(format: "%.1f", g.avgValue))°C\n"
        }

        out += appendPowerAndFans()

        out += "\nSi ves sensores que deberían ser CPU o GPU pero salen como [SoC]\n"
        out += "u [Otros], pásame este archivo y ajusto la clasificación.\n"
        return out
    }

    /// Sección de potencia (IOReport), ventiladores (SMC) y presión térmica.
    private static func appendPowerAndFans() -> String {
        var out = "\nPotencia (IOReport · Energy Model):\n"
        out += "-----------------------------------\n"
        // Dos lecturas: la primera inicializa el estado interno del lector.
        _ = PowerReader.read()
        Thread.sleep(forTimeInterval: 0.3)
        if let p = PowerReader.read() {
            out += "\(pad("CPU", 16))\(String(format: "%7.2f", p.cpu)) W\n"
            out += "\(pad("GPU", 16))\(String(format: "%7.2f", p.gpu)) W\n"
            out += "\(pad("Neural Engine", 16))\(String(format: "%7.2f", p.ane)) W\n"
            out += "\(pad("Memoria (DRAM)", 16))\(String(format: "%7.2f", p.dram)) W\n"
            out += "\(pad("TOTAL", 16))\(String(format: "%7.2f", p.total)) W\n"
        } else {
            out += "No disponible.\n"
        }

        out += "\nVentiladores (SMC):\n"
        out += "-------------------\n"
        let fans = FanReader.read()
        if FanReader.count() == 0 {
            out += "Sin ventiladores (equipo fanless).\n"
        } else if fans.isEmpty {
            out += "Detectados pero sin lectura de RPM.\n"
        } else {
            for f in fans { out += "Ventilador \(f.index): \(f.formatted)\n" }
        }

        out += "\nPresión térmica del sistema: \(ThermalPressure.current.label)\n"
        return out
    }

    /// Escribe el informe en `url` (UTF-8). Devuelve la URL.
    @discardableResult
    static func writeReport(to url: URL) throws -> URL {
        try buildReport().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "desconocido" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
