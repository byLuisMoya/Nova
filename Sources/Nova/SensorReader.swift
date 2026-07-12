import Foundation
import CIOKitHID

/// Una lectura cruda de un sensor de temperatura tal cual la expone HID.
struct RawSensor {
    let name: String
    let value: Double
}

/// Capa de acceso a los sensores de temperatura de Apple Silicon a través de
/// las APIs privadas `IOHIDEventSystemClient*` (declaradas en el módulo C
/// `CIOKitHID`). No requiere root ni entitlements. En un binario suelto de
/// SwiftPM no hay sandbox, así que la lectura funciona directamente.
enum SensorReader {

    // Página / uso HID del "vendor" Apple para sensores de temperatura.
    private static let kHIDPageAppleVendor: Int32 = 0xff00          // PrimaryUsagePage
    private static let kHIDUsageAppleVendorTemperature: Int32 = 0x0005 // PrimaryUsage

    // Tipo de evento HID de temperatura.
    private static let kIOHIDEventTypeTemperature: Int64 = 15

    /// Lee todos los sensores de temperatura disponibles.
    /// Devuelve un array vacío si no hay sensores (o si hubiese sandbox).
    static func readTemperatureSensors() -> [RawSensor] {
        // 1. Crear el cliente del sistema de eventos HID.
        guard let system = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            return []
        }

        // 2. Matching: sólo sensores de temperatura del vendor Apple.
        let matching: [String: Int32] = [
            "PrimaryUsagePage": kHIDPageAppleVendor,
            "PrimaryUsage": kHIDUsageAppleVendorTemperature
        ]
        IOHIDEventSystemClientSetMatching(system, matching as CFDictionary)

        // 3. Copiar los servicios que cumplen el matching.
        //    Con sandbox activo esta llamada devolvería una lista vacía.
        guard let services = IOHIDEventSystemClientCopyServices(system)?.takeRetainedValue() else {
            return []
        }

        let count = CFArrayGetCount(services)
        var results: [RawSensor] = []
        results.reserveCapacity(count)

        // El campo de valor de un evento de temperatura: (tipo << 16).
        let field = Int32(truncatingIfNeeded: kIOHIDEventTypeTemperature << 16)

        // 4. Recorrer cada servicio, leer nombre y valor.
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = unsafeBitCast(ptr, to: CFTypeRef.self)

            // Nombre: "Product" con fallback a "DeviceName".
            var name = copyStringProperty(service, "Product")
            if name.isEmpty {
                name = copyStringProperty(service, "DeviceName")
            }
            guard !name.isEmpty else { continue }

            // Copiar el evento de temperatura y leer su valor.
            guard let event = IOHIDServiceClientCopyEvent(service,
                                                          kIOHIDEventTypeTemperature,
                                                          0, 0)?.takeRetainedValue() else {
                continue
            }

            let value = IOHIDEventGetFloatValue(event, field)

            // Descartar lecturas claramente inválidas.
            guard value.isFinite, value > 0, value < 150 else { continue }
            results.append(RawSensor(name: name, value: value))
        }

        return results
    }

    /// Lee una propiedad de tipo String de un servicio HID.
    private static func copyStringProperty(_ service: CFTypeRef, _ key: String) -> String {
        guard let prop = IOHIDServiceClientCopyProperty(service, key as CFString)?.takeRetainedValue() else {
            return ""
        }
        // CFString cruza el puente a String automáticamente.
        return (prop as? String) ?? ""
    }
}
