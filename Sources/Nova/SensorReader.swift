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

    /// Un servicio HID de temperatura ya filtrado, con su nombre resuelto.
    private struct Service {
        let ref: CFTypeRef
        let name: String
    }

    // El cliente HID y la lista de servicios se crean UNA vez y se reutilizan:
    // crear el cliente y enumerar los servicios (y copiar sus nombres) en cada
    // refresco es lo más caro de la lectura. Los servicios retienen su cliente.
    // Acceso serializado con `lock` (cola de fondo del ViewModel + diagnóstico).
    private static var system: CFTypeRef?
    private static var services: [Service] = []
    private static let lock = NSLock()

    /// Lee todos los sensores de temperatura disponibles.
    /// Devuelve un array vacío si no hay sensores (o si hubiese sandbox).
    static func readTemperatureSensors() -> [RawSensor] {
        lock.lock()
        defer { lock.unlock() }

        if services.isEmpty { services = enumerateServices() }
        var results = read(services)
        // Si no sale ninguna lectura (lista vacía o servicios que dejaron de
        // responder), se vuelve a enumerar una vez antes de darla por buena.
        if results.isEmpty {
            services = enumerateServices()
            results = read(services)
        }
        return results
    }

    /// Valor actual de cada servicio, descartando lecturas inválidas.
    private static func read(_ services: [Service]) -> [RawSensor] {
        // El campo de valor de un evento de temperatura: (tipo << 16).
        let field = Int32(truncatingIfNeeded: kIOHIDEventTypeTemperature << 16)

        var results: [RawSensor] = []
        results.reserveCapacity(services.count)
        for service in services {
            // Copiar el evento de temperatura y leer su valor.
            guard let event = IOHIDServiceClientCopyEvent(service.ref,
                                                          kIOHIDEventTypeTemperature,
                                                          0, 0)?.takeRetainedValue() else {
                continue
            }

            let value = IOHIDEventGetFloatValue(event, field)

            // Descartar lecturas claramente inválidas.
            guard value.isFinite, value > 0, value < 150 else { continue }
            results.append(RawSensor(name: service.name, value: value))
        }
        return results
    }

    /// Crea el cliente HID (si no existe) y enumera los servicios de temperatura.
    private static func enumerateServices() -> [Service] {
        // 1. Crear el cliente del sistema de eventos HID.
        if system == nil {
            system = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
            guard let system else { return [] }

            // 2. Matching: sólo sensores de temperatura del vendor Apple.
            let matching: [String: Int32] = [
                "PrimaryUsagePage": kHIDPageAppleVendor,
                "PrimaryUsage": kHIDUsageAppleVendorTemperature
            ]
            IOHIDEventSystemClientSetMatching(system, matching as CFDictionary)
        }
        guard let system else { return [] }

        // 3. Copiar los servicios que cumplen el matching.
        //    Con sandbox activo esta llamada devolvería una lista vacía.
        guard let list = IOHIDEventSystemClientCopyServices(system)?.takeRetainedValue() as? [CFTypeRef] else {
            return []
        }

        // 4. Resolver el nombre de cada servicio.
        return list.compactMap { service in
            // Nombre: "Product" con fallback a "DeviceName".
            var name = copyStringProperty(service, "Product")
            if name.isEmpty {
                name = copyStringProperty(service, "DeviceName")
            }
            guard !name.isEmpty else { return nil }

            // Descartar los sensores de calibración (p. ej. "PMU tcal"): no son
            // medidas en vivo sino una constante de referencia del PMU, que se
            // queda clavada (~52°C) y, al ser la más alta, falsearía el máximo
            // del SoC. Los dies reales ("tdie"/"tdev") sí reflejan la temperatura.
            if name.lowercased().contains("tcal") { return nil }

            return Service(ref: service, name: name)
        }
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
