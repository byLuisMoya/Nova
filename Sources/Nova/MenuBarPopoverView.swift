import SwiftUI

/// Contenido del desplegable (popover) de la barra de menú, con dos pestañas:
///  · Temperatura: temperaturas agrupadas por componente (+ lista completa).
///  · Potencia:    consumo por bloque, ventiladores y presión térmica.
struct MenuBarPopoverView: View {
    @ObservedObject var vm: ThermalViewModel
    @EnvironmentObject var settings: AppSettings
    var onOpenWindow: () -> Void
    var onDiagnose: () -> Void
    var onPreferences: () -> Void
    var onQuit: () -> Void

    @State private var showAll = false
    @State private var tab: Tab = .temperature
    @State private var showLaunchHint = false

    enum Tab: Hashable { case temperature, power }

    /// Tope de altura de la lista; por encima, aparece scroll.
    private let maxListHeight: CGFloat = 360

    /// Altura estimada de la lista de temperatura según los sensores visibles
    /// (determinista, sin medir la vista, para que el popover se adapte estable).
    private var listHeight: CGFloat {
        let base: CGFloat = 20       // padding vertical
        let groupUnit: CGFloat = 72  // fila de grupo + tarjeta sparkline + espaciado
        let sensorUnit: CGFloat = 24 // fila de sensor + espaciado
        var h = base + CGFloat(vm.groups.count) * groupUnit
        if showAll {
            let sensors = vm.groups.reduce(0) { $0 + $1.sensors.count }
            h += CGFloat(sensors) * sensorUnit
        }
        return h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = vm.errorMessage {
                errorView(error)
            } else if vm.groups.isEmpty {
                loadingView
            } else {
                Picker("", selection: $tab) {
                    Label("Temperatura", systemImage: "thermometer.medium").tag(Tab.temperature)
                    Label("Potencia", systemImage: "bolt.fill").tag(Tab.power)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()

                switch tab {
                case .temperature: temperatureTab
                case .power:       powerTab
                }
            }

            Divider()
            footer
        }
        .frame(width: 280)
    }

    // MARK: - Pestaña Temperatura

    private var temperatureTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(vm.groups) { group in
                        groupRow(group)
                        if showAll {
                            ForEach(group.sensors) { sensor in
                                sensorRow(sensor)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            // La altura se adapta a los sensores visibles y solo hace scroll
            // cuando el contenido supera el tope.
            .frame(height: min(listHeight, maxListHeight))

            Divider()
            Toggle("Ver todos los sensores", isOn: $showAll)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Pestaña Potencia

    private var powerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Presión térmica.
            HStack(spacing: 8) {
                Image(systemName: vm.thermalPressure.symbol)
                    .foregroundStyle(vm.thermalPressure.color)
                Text("Presión térmica")
                InfoHint(info: vm.thermalPressure.info)
                Spacer()
                Text(vm.thermalPressure.label)
                    .fontWeight(.medium)
                    .foregroundStyle(vm.thermalPressure.color)
            }
            .font(.callout)

            Divider()

            // Consumo por bloque.
            if let p = vm.power {
                HStack {
                    Label("Consumo", systemImage: "bolt.fill")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.2f W", p.total))
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
                if vm.powerTotalHistory.count >= 2 {
                    Sparkline(points: vm.powerTotalHistory, color: .orange)
                        .sparklineCard(.orange, height: 34)
                }
                let peak = max(p.components.map(\.watts).max() ?? 1, 0.5)
                ForEach(p.components) { c in
                    PowerBar(component: c, peak: peak)
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Midiendo consumo…").foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            // Ventiladores.
            if !vm.fans.isEmpty {
                Divider()
                ForEach(vm.fans) { fan in
                    HStack {
                        Label("Ventilador \(fan.index + 1)", systemImage: "fanblades.fill")
                        Spacer()
                        Text(fan.formatted).monospacedDigit().fontWeight(.medium)
                    }
                    .font(.callout)
                }
            } else if vm.fanCount > 0 {
                Label("Ventilador detectado, sin lectura de RPM", systemImage: "fanblades")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Sin ventilador (refrigeración pasiva)", systemImage: "wind")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Secciones comunes

    private var header: some View {
        HStack {
            Image(systemName: "thermometer.sun")
                .foregroundStyle(.primary)
            Text("Nova")
                .font(.headline)
            if !settings.launchAtLogin {
                launchAtLoginHint
            }
            Spacer()
            if let update = vm.lastUpdate {
                // Cadena estática (no `style: .time`, que se auto-refresca cada
                // segundo y re-renderiza el popover, cerrando los tooltips).
                Text(Self.timeFormatter.string(from: update))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Aviso discreto (solo cuando el autoarranque está desactivado): al pasar
    /// el ratón explica que Nova no arrancará sola; al hacer clic abre Preferencias.
    private var launchAtLoginHint: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            // Naranja vivo (con toque rojo) en claro, para que resalte sobre el
            // fondo claro sin apagarse; naranja del sistema en oscuro.
            .foregroundStyle(Color(light: Color(red: 0.91, green: 0.35, blue: 0.05), dark: .orange))
            .onHover { hovering in showLaunchHint = hovering }
            .onTapGesture { onPreferences() }
            .popover(isPresented: $showLaunchHint, arrowEdge: .bottom) {
                Text("Nova no se iniciará automáticamente al encender el equipo. "
                     + "Actívalo en Preferencias (\u{2699}\u{FE0E}) → “Abrir al iniciar sesión”.")
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(10)
            }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func groupRow(_ group: SensorGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: group.category.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(group.category.rawValue)
                    .font(.system(.body, design: .rounded))
                InfoHint(info: group.category.info)
                Spacer()
                Text(settings.unit.format(group.maxValue))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(group.severity.color)
                Circle()
                    .fill(group.severity.color)
                    .frame(width: 9, height: 9)
            }
            let points = vm.tempHistory[group.category] ?? []
            if points.count >= 2 {
                Sparkline(points: points, color: group.severity.color)
                    .sparklineCard(group.severity.color, height: 26)
            }
        }
    }

    private func sensorRow(_ sensor: TemperatureSensor) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sensor.severity.color)
                .frame(width: 6, height: 6)
            Text(sensor.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(settings.unit.format(sensor.value))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(sensor.severity.color)
        }
        .padding(.leading, 30)
    }

    private var loadingView: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Leyendo sensores…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(16)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sin sensores", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button {
                onOpenWindow()
            } label: {
                Label("Ventana", systemImage: "macwindow")
            }
            Button {
                onPreferences()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Preferencias (unidad de temperatura…)")
            Spacer()
            Button {
                onDiagnose()
            } label: {
                Image(systemName: "stethoscope")
            }
            .help("Guardar diagnóstico de sensores en un archivo y mostrarlo en el Finder")
            Button {
                onQuit()
            } label: {
                Label("Salir", systemImage: "power")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
