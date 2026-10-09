import Foundation
import Combine

/// ViewModel con refresco automático. Lee los sensores en una cola de fondo
/// cada `refreshInterval` segundos y publica el resultado en el hilo principal.
final class ThermalViewModel: ObservableObject {

    @Published private(set) var groups: [SensorGroup] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdate: Date?

    // Señales adicionales (pestaña "Potencia").
    @Published private(set) var power: PowerReading?
    @Published private(set) var fans: [FanReading] = []
    /// Número de ventiladores físicos según el SMC (clave `FNum`). Distingue un
    /// equipo realmente sin ventilador (0) de uno con ventilador del que no se
    /// logra leer RPM (`fans` vacío pero `fanCount > 0`).
    @Published private(set) var fanCount: Int = 0
    @Published private(set) var thermalPressure: ThermalPressure = .nominal

    // Histórico para las gráficas (buffer circular por serie).
    @Published private(set) var tempHistory: [SensorCategory: [HistoryPoint]] = [:]
    @Published private(set) var powerHistory: [PowerComponent.Kind: [HistoryPoint]] = [:]
    @Published private(set) var powerTotalHistory: [HistoryPoint] = []

    /// Muestras conservadas por serie (150 × 2 s ≈ 5 min de historia).
    let historyCapacity = 150

    /// Intervalo de refresco (1–2 s según los requisitos).
    var refreshInterval: TimeInterval = 2.0 {
        didSet { if timer != nil { scheduleTimer() } }
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "io.github.byluismoya.Nova.sensors", qos: .utility)
    private var didStart = false

    // MARK: - Ciclo de vida

    /// Arranca la lectura periódica (idempotente).
    func start() {
        guard !didStart else { return }
        didStart = true
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        didStart = false
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Margen para que el sistema agrupe este despertar con otros (ahorro
        // de energía); unas décimas de holgura no se notan en la lectura.
        t.tolerance = refreshInterval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Lectura

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let raw = SensorReader.readTemperatureSensors()
            // IOReport y SMC se leen en la MISMA cola de fondo: el lector de
            // potencia guarda estado entre llamadas y no es thread-safe.
            let power = PowerReader.read()
            let fans = FanReader.read()
            let fanCount = FanReader.count()
            DispatchQueue.main.async {
                self.apply(raw, power: power, fans: fans, fanCount: fanCount, at: Date())
            }
        }
    }

    /// Aplica una lectura completa. Cada `@Published` asignado dispara un
    /// `objectWillChange` (y una invalidación de las vistas), así que solo se
    /// asigna lo que cambia y el histórico se construye en copias locales que
    /// se publican de una vez, no serie a serie.
    private func apply(_ raw: [RawSensor], power: PowerReading?, fans: [FanReading],
                       fanCount: Int, at now: Date) {
        if self.power != power { self.power = power }
        if self.fans != fans { self.fans = fans }
        if self.fanCount != fanCount { self.fanCount = fanCount }
        let pressure = ThermalPressure.current
        if thermalPressure != pressure { thermalPressure = pressure }

        guard !raw.isEmpty else {
            // Fallo explícito, nunca silencioso.
            if errorMessage == nil {
                errorMessage = "No se encontraron sensores de temperatura.\n\n"
                    + "Comprueba que ejecutas en un Mac con Apple Silicon. "
                    + "(En una app con App Sandbox activo la lista sale vacía.)"
            }
            return
        }

        if errorMessage != nil { errorMessage = nil }
        let mapped = raw.map {
            TemperatureSensor(name: $0.name,
                              value: $0.value,
                              category: SensorCategory.classify($0.name))
        }
        let newGroups = SensorGroup.build(from: mapped)
        if groups != newGroups { groups = newGroups }
        lastUpdate = now
        recordHistory(at: now, power: power)
    }

    // MARK: - Histórico

    /// Contador de muestras; su resto entre la capacidad da el hueco (`slot`)
    /// de cada punto, que le sirve de id acotado (ver `HistoryPoint`).
    private var sampleCount = 0

    /// Añade una muestra al histórico de cada serie y recorta al tope.
    private func recordHistory(at now: Date, power: PowerReading?) {
        let slot = sampleCount % historyCapacity
        sampleCount += 1

        var temps = tempHistory
        for group in groups {
            append(HistoryPoint(time: now, value: group.maxValue, slot: slot),
                   to: &temps[group.category, default: []])
        }
        tempHistory = temps

        if let p = power {
            var byKind = powerHistory
            for c in p.components {
                append(HistoryPoint(time: now, value: c.watts, slot: slot),
                       to: &byKind[c.kind, default: []])
            }
            powerHistory = byKind
            var total = powerTotalHistory
            append(HistoryPoint(time: now, value: p.total, slot: slot), to: &total)
            powerTotalHistory = total
        }
    }

    private func append(_ point: HistoryPoint, to series: inout [HistoryPoint]) {
        series.append(point)
        if series.count > historyCapacity {
            series.removeFirst(series.count - historyCapacity)
        }
    }

    // MARK: - Derivados para la barra de menú

    /// Componentes que se muestran por separado en la barra de menú, en orden
    /// CPU → GPU → SoC. Solo se incluyen los que tienen sensores (p. ej. en un
    /// M5 base solo existe SoC). Cada grupo agrega sus sensores por el máximo.
    var menuBarComponents: [SensorGroup] {
        [SensorCategory.cpu, .gpu, .soc].compactMap { category in
            groups.first { $0.category == category }
        }
    }
}
