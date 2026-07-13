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
                let now = Date()
                self.apply(raw, at: now)
                self.power = power
                self.fans = fans
                self.fanCount = fanCount
                self.thermalPressure = ThermalPressure.current
                if self.errorMessage == nil {
                    self.recordHistory(at: now, power: power)
                }
            }
        }
    }

    private func apply(_ raw: [RawSensor], at now: Date) {
        guard !raw.isEmpty else {
            // Fallo explícito, nunca silencioso.
            errorMessage = "No se encontraron sensores de temperatura.\n\n"
                + "Comprueba que ejecutas en un Mac con Apple Silicon. "
                + "(En una app con App Sandbox activo la lista sale vacía.)"
            return
        }

        errorMessage = nil
        let mapped = raw.map {
            TemperatureSensor(name: $0.name,
                              value: $0.value,
                              category: SensorCategory.classify($0.name))
        }
        groups = SensorGroup.build(from: mapped)
        lastUpdate = now
    }

    // MARK: - Histórico

    /// Añade una muestra al histórico de cada serie y recorta al tope.
    private func recordHistory(at now: Date, power: PowerReading?) {
        for group in groups {
            append(HistoryPoint(time: now, value: group.maxValue),
                   to: &tempHistory[group.category, default: []])
        }
        if let p = power {
            for c in p.components {
                append(HistoryPoint(time: now, value: c.watts),
                       to: &powerHistory[c.kind, default: []])
            }
            append(HistoryPoint(time: now, value: p.total), to: &powerTotalHistory)
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
