import SwiftUI

/// Ventana principal opcional, con dos pestañas:
///  · Temperatura: lista detallada de sensores agrupados por componente.
///  · Potencia:    consumo por bloque (CPU/GPU/ANE/DRAM), ventiladores y
///                 presión térmica del sistema.
struct ContentView: View {
    @ObservedObject var vm: ThermalViewModel
    @EnvironmentObject var settings: AppSettings
    @State private var tab: Tab = .temperature

    enum Tab: Hashable { case temperature, power }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Picker("", selection: $tab) {
                Label("Temperatura", systemImage: "thermometer.medium").tag(Tab.temperature)
                Label("Potencia", systemImage: "bolt.fill").tag(Tab.power)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let error = vm.errorMessage {
                errorView(error)
            } else if vm.groups.isEmpty {
                ProgressView("Leyendo sensores…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch tab {
                case .temperature: temperatureTab
                case .power:       PowerTab(vm: vm)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 480)
    }

    // MARK: - Pestaña Temperatura

    private var temperatureTab: some View {
        VStack(spacing: 0) {
            if vm.tempHistory.values.contains(where: { $0.count >= 2 }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Últimos 5 min")
                        .font(.caption).foregroundStyle(.secondary)
                    TempHistoryChart(history: vm.tempHistory, unit: settings.unit)
                        .frame(height: 160)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                Divider()
            }
            List {
                ForEach(vm.groups) { group in
                    Section {
                        ForEach(group.sensors) { sensor in
                            sensorRow(sensor)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Común

    private var toolbar: some View {
        HStack {
            Image(systemName: "thermometer.sun")
                .foregroundStyle(.primary)
            Text("Nova")
                .font(.title3.weight(.semibold))
            Spacer()
            if let update = vm.lastUpdate {
                Label(update.formatted(date: .omitted, time: .shortened),
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                vm.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refrescar ahora")
        }
        .padding(12)
    }

    private func groupHeader(_ group: SensorGroup) -> some View {
        HStack {
            Label(group.category.rawValue, systemImage: group.category.symbol)
                .font(.subheadline.weight(.semibold))
            InfoHint(info: group.category.info)
            Spacer()
            Text("máx \(settings.unit.format(group.maxValue)) · med \(settings.unit.format(group.avgValue))")
                .font(.caption)
                .foregroundStyle(group.severity.color)
                .monospacedDigit()
        }
    }

    private func sensorRow(_ sensor: TemperatureSensor) -> some View {
        HStack {
            Circle()
                .fill(sensor.severity.color)
                .frame(width: 10, height: 10)
            Text(sensor.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(settings.unit.format(sensor.value))
                .monospacedDigit()
                .foregroundStyle(sensor.severity.color)
                .fontWeight(.medium)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("No se encontraron sensores")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Reintentar") { vm.refresh() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Pestaña Potencia

/// Consumo eléctrico por bloque, ventiladores y presión térmica del sistema.
struct PowerTab: View {
    @ObservedObject var vm: ThermalViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pressureCard
                powerCard
                if vm.powerHistory.values.contains(where: { $0.count >= 2 }) {
                    historyCard
                }
                if vm.fans.isEmpty {
                    fanlessNote
                } else {
                    fansCard
                }
            }
            .padding(16)
        }
    }

    // Presión térmica (estado nativo de macOS).
    private var pressureCard: some View {
        let p = vm.thermalPressure
        return HStack(spacing: 12) {
            Image(systemName: p.symbol)
                .font(.title2)
                .foregroundStyle(p.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Presión térmica")
                        .font(.subheadline.weight(.semibold))
                    InfoHint(info: p.info, compact: true)
                }
                Text(p.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(p.color)
            }
            Spacer()
        }
        .padding(12)
        .background(p.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    // Consumo por bloque, con barras y total.
    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Consumo", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let p = vm.power {
                    Text(String(format: "%.2f W", p.total))
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
            }

            if let p = vm.power {
                let peak = max(p.components.map(\.watts).max() ?? 1, 0.5)
                ForEach(p.components) { c in
                    PowerBar(component: c, peak: peak)
                }
                Text("Vía IOReport · «Energy Model». Sin root ni entitlements.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Midiendo consumo…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // Historial de consumo (área apilada por bloque = consumo total).
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Historial (últimos 5 min)", systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.semibold))
            PowerHistoryChart(history: vm.powerHistory)
                .frame(height: 170)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var fansCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ventiladores", systemImage: "fanblades.fill")
                .font(.subheadline.weight(.semibold))
            ForEach(vm.fans) { fan in
                HStack {
                    Text("Ventilador \(fan.index + 1)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(fan.formatted)
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var fanlessNote: some View {
        Label("Este Mac no tiene ventilador (refrigeración pasiva).",
              systemImage: "wind")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

/// Barra horizontal para un bloque de consumo, escalada al pico actual.
/// Reutilizada por la ventana detallada y por el desplegable.
struct PowerBar: View {
    let component: PowerComponent
    let peak: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(component.kind.rawValue, systemImage: component.kind.symbol)
                    .font(.caption)
                Spacer()
                Text(component.formatted)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, component.watts / peak))))
                }
            }
            .frame(height: 6)
        }
    }
}
