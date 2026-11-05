import AppKit
import Charts
import SwiftUI

/// Desplegable de un servidor remoto: cabecera, pestañas Sistema / Docker / Procesos y el
/// estado de sus servicios. Mismo patrón que `MenuBarPopoverView`: los datos vienen de un
/// `ServerStore` que vive fuera de la vista, y el estado de interfaz (pestaña, rango) también.
struct ServerPanelView: View {
    @ObservedObject var store: ServerStore
    var onPreferences: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ServerHeader(store: store)
            if let s = store.snapshot {
                ServerTabPicker(tab: $store.tab, docker: s.docker?.containers.count)
                Group {
                    switch store.tab {
                    case .system: ServerSystemView(store: store, s: s)
                    case .docker: ServerDockerView(docker: s.docker)
                    case .processes: ServerProcessView(processes: s.processes ?? [])
                    }
                }
                .opacity(store.online ? 1 : 0.45)
                ServerServicePills(services: s.services ?? [], online: store.online)
            } else if store.connecting {
                ServerMessage(icon: "antenna.radiowaves.left.and.right", title: "Conectando…", detail: nil)
            } else {
                ServerMessage(icon: "moon.zzz", title: "Servidor apagado o inaccesible",
                              detail: "Se conectará solo en cuanto arranque.")
            }
            HStack {
                Button(action: onPreferences) { Image(systemName: "gearshape") }
                    .help("Preferencias")
                Spacer()
                Button(action: onQuit) { Label("Salir", systemImage: "power") }
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(12)
        .frame(width: 420)
    }
}

// MARK: - Cabecera y pestañas

struct ServerHeader: View {
    @ObservedObject var store: ServerStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Cadena estática (sin `TimelineView`): un texto que se refresca cada segundo re-renderiza
    /// el desplegable entero y cierra los tooltips.
    private var status: String {
        if store.connecting { return "conectando…" }
        guard let last = store.lastOK else { return "sin conexión" }
        let time = Self.timeFormatter.string(from: last)
        return store.online ? "actualizado a las \(time)" : "sin conexión · último dato a las \(time)"
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [.blue, .blue.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "server.rack").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(store.snapshot?.host ?? store.name).font(.headline)
                Text(status).font(.caption).foregroundStyle(store.online ? Color.secondary : Color.orange)
            }
            Spacer()
            if store.config.ssh != nil {
                ServerHeaderButton(icon: "terminal", help: "Abrir SSH") { store.openTerminal() }
            }
            ServerHeaderButton(icon: "arrow.clockwise", help: "Actualizar") { store.refresh() }
        }
    }
}

struct ServerHeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct ServerTabPicker: View {
    @Binding var tab: ServerTab
    let docker: Int?

    var body: some View {
        HStack(spacing: 4) {
            item(.system, icon: "gauge.with.dots.needle.33percent", title: "Sistema", count: nil)
            item(.docker, icon: "shippingbox", title: "Docker", count: docker)
            item(.processes, icon: "cpu", title: "Procesos", count: nil)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func item(_ t: ServerTab, icon: String, title: String, count: Int?) -> some View {
        Button { tab = t } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
                if let count {
                    Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.12)))
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tab == t ? Color.primary.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Selector de rango en su propia vista: no lee el snapshot, así que el refresco de datos no
/// re-evalúa el `Picker` segmentado (ver `MenuBarPopoverView.TabPicker`).
struct ServerRangePicker: View {
    @Binding var range: ServerChartRange

    var body: some View {
        Picker("", selection: $range) {
            ForEach(ServerChartRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
    }
}

// MARK: - Sistema

struct ServerSystemView: View {
    @ObservedObject var store: ServerStore
    let s: ServerSnapshot

    private var discreteGPUs: [ServerSnapshot.GPU] { (s.gpu ?? []).filter { $0.integrated != true } }

    var body: some View {
        let series = store.series
        let gap: Double = store.range == .short ? 30 : 180
        VStack(spacing: 10) {
            HStack {
                Text("Gráficas").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ServerRangePicker(range: $store.range)
            }
            HStack(spacing: 8) {
                ServerMetricCard(title: "CPU", value: ServerFormat.pct(s.cpu?.percent),
                                 subtitle: s.cpu?.mhz.map { "\(Int($0)) MHz" } ?? "",
                                 color: .blue, points: series?.points(series?.cpu ?? [], gap: gap) ?? [],
                                 domain: 0...100)
                ServerMetricCard(title: "Temperatura",
                                 value: s.temp?.cpu.map { String(format: "%.0f °C", $0) } ?? "—",
                                 subtitle: s.temp?.fanRpm.map { "ventilador \(Int($0)) rpm" } ?? "sin lectura de ventilador",
                                 color: .orange, points: series?.points(series?.temp ?? [], gap: gap) ?? [],
                                 domain: nil)
                ServerMetricCard(title: "Consumo", value: s.power?.watts.map { String(format: "%.1f W", $0) } ?? "—",
                                 subtitle: powerSubtitle,
                                 color: .green, points: series?.points(series?.power ?? [], gap: gap) ?? [],
                                 domain: nil)
            }
            VStack(spacing: 10) {
                if let m = s.memory {
                    ServerUsageBar(icon: "memorychip", title: "Memoria",
                                   detail: m.swapUsed > 0 ? "swap \(ServerFormat.mem(m.swapUsed))" : nil,
                                   used: m.used, total: m.total, format: ServerFormat.mem)
                }
                ForEach(s.filesystems ?? []) { fs in
                    ServerUsageBar(icon: "internaldrive", title: fs.label, detail: fs.mount == "/" ? nil : fs.mount,
                                   used: fs.used, total: fs.total, format: ServerFormat.disk)
                }
                if let disks = s.disks, !disks.isEmpty {
                    Divider().opacity(0.5)
                    ForEach(disks) { ServerDiskRow(d: $0) }
                }
            }
            .serverCard()
            VStack(alignment: .leading, spacing: 5) {
                ServerInfoRow(label: "GPU", value: gpuText)
                ServerInfoRow(label: "Carga", value: loadText)
                ServerInfoRow(label: "Eventos", value: eventsText)
            }
            .serverCard()
        }
    }

    private var powerSubtitle: String {
        guard s.power?.available == true else { return "sin sensor RAPL" }
        var parts: [String] = []
        if let w = s.power?.cpuWatts { parts.append(String(format: "CPU %.1f", w)) }
        if let g = discreteGPUs.first?.state { parts.append("GPU \(g)") }
        return parts.joined(separator: " · ")
    }

    private var gpuText: String {
        let gpus = discreteGPUs.isEmpty ? (s.gpu ?? []) : discreteGPUs
        guard !gpus.isEmpty else { return "—" }
        return gpus.map { gpu in
            let note = gpu.state == "dormida" ? " (sin uso, casi no gasta)" : ""
            return "\(gpu.name): \(gpu.state)\(note)"
        }.joined(separator: "\n")
    }

    private var loadText: String {
        let load = s.load?.first.map { String(format: "%.2f", $0) } ?? "—"
        let up = s.uptimeS.map { " · encendido \(ServerFormat.duration($0))" } ?? ""
        return load + up
    }

    private var eventsText: String {
        guard let e = s.events else { return "—" }
        let ecc = e.eccCe.map { "ECC \($0)/\(e.eccUe ?? 0)" } ?? "ECC n/d"
        let oom = "OOM \(e.oom.map(String.init) ?? "—")"
        let thr = "throttling \(e.throttle.map(String.init) ?? "—")"
        return [ecc, oom, thr].joined(separator: " · ")
    }
}

struct ServerMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let points: [ServerSeries.Point]
    let domain: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            ServerSparkline(points: points, color: color, domain: domain).frame(height: 30).clipped().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .serverCard()
    }
}

struct ServerSparkline: View {
    let points: [ServerSeries.Point]
    let color: Color
    let domain: ClosedRange<Double>?

    private var yDomain: ClosedRange<Double> {
        if let domain { return domain }
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.25, 0.5)
        return max(0, lo - pad)...(hi + pad)
    }

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("t", p.date), y: .value("v", p.value), series: .value("s", p.segment))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
    }
}

struct ServerUsageBar: View {
    let icon: String
    let title: String
    let detail: String?
    let used: Double
    let total: Double
    let format: (Double) -> String

    private var fraction: Double { total > 0 ? min(1, max(0, used / total)) : 0 }
    private var tint: Color { fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .blue }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                (Text(title) + Text(detail.map { " · \($0)" } ?? "").foregroundColor(.secondary)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(format(used)) de \(format(total))").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint).frame(width: g.size.width * fraction)
                }
            }
            .frame(height: 5)
        }
    }
}

struct ServerDiskRow: View {
    let d: ServerSnapshot.Disk

    private var sleepingWithoutData: Bool { d.standby == true && d.model == nil }

    private var color: Color {
        if sleepingWithoutData { return .secondary }
        switch d.passed {
        case true: return .green
        case false: return .red
        default: return .secondary
        }
    }

    private var icon: String {
        if sleepingWithoutData { return "moon.zzz.fill" }
        switch d.passed {
        case true: return "checkmark.circle.fill"
        case false: return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }

    private var status: String {
        if sleepingWithoutData { return "en reposo" }
        switch d.passed {
        case true: return "sano"
        case false: return "FALLO SMART"
        default: return "sin datos"
        }
    }

    private var details: String {
        var parts: [String] = []
        if let t = d.temp { parts.append(String(format: "%.0f °C", t)) }
        if let w = d.wear { parts.append(String(format: "desgaste %.0f %%", w)) }
        if let h = d.hours { parts.append("\(Int(h)) h encendido") }
        if let st = d.selfTest { parts.append(st) }
        if d.standby == true { parts.append("en reposo") }
        if let ago = d.checkedAgoS, ago > 900 || d.standby == true {
            parts.append("leído hace \(ServerFormat.duration(ago))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.name).font(.callout.weight(.medium))
                    Text(d.model ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status).font(.caption).foregroundStyle(color)
                }
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct ServerInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

// MARK: - Docker

struct ServerDockerView: View {
    let docker: ServerSnapshot.Docker?

    var body: some View {
        if let docker, docker.available {
            let running = docker.containers.filter { $0.state == "running" }.count
            VStack(alignment: .leading, spacing: 6) {
                Text("\(running) en marcha · \(docker.containers.count - running) parados")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(docker.containers) { c in
                            ServerContainerRow(c: c)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxHeight: 430)
            }
            .serverCard()
        } else {
            ServerMessage(icon: "shippingbox", title: "Docker no disponible", detail: nil).serverCard()
        }
    }
}

struct ServerContainerRow: View {
    let c: ServerSnapshot.Container

    private var color: Color {
        switch c.state {
        case "running": return c.status.contains("unhealthy") ? .orange : .green
        case "restarting", "paused": return .orange
        case "dead": return .red
        default: return .secondary
        }
    }

    private var usage: String {
        guard c.state == "running" else { return "" }
        let cpu = c.cpu.map { String(format: "%.1f %%", $0) } ?? "—"
        let mem = c.memBytes.map(ServerFormat.small) ?? "—"
        return "\(cpu) · \(mem)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(c.image).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(usage).font(.caption).monospacedDigit()
                Text(c.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Procesos

struct ServerProcessView: View {
    let processes: [ServerSnapshot.Proc]

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Proceso")
                Spacer()
                Text("CPU").frame(width: 52, alignment: .trailing)
                Text("Mem").frame(width: 58, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(processes) { p in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text("\(p.user) · \(p.pid) · \(p.command)").font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 6)
                            Text(String(format: "%.1f %%", p.cpu)).font(.callout).monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                            Text(ServerFormat.small(p.memBytes)).font(.callout).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(maxHeight: 430)
            Text("CPU en % del total de la máquina").font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .serverCard()
    }
}

// MARK: - Comunes

struct ServerServicePills: View {
    let services: [ServerSnapshot.Service]
    let online: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(services) { s in
                HStack(spacing: 4) {
                    Circle().fill(color(s)).frame(width: 6, height: 6)
                    Text(s.name).font(.caption).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }

    private func color(_ s: ServerSnapshot.Service) -> Color {
        guard online else { return .secondary }
        switch s.ok {
        case true: return .green
        case false: return .red
        default: return .secondary
        }
    }
}

struct ServerMessage: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

enum ServerFormat {
    /// Memoria en GiB, rotulada «GB» como en el Monitor de Actividad.
    static func mem(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }

    /// Discos en unidades decimales, como las anuncia el fabricante.
    static func disk(_ bytes: Double) -> String {
        bytes >= 1e12 ? String(format: "%.2f TB", bytes / 1e12) : String(format: "%.1f GB", bytes / 1e9)
    }

    static func small(_ bytes: Double) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", bytes / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.0f MB", bytes / 1_048_576) }
        return String(format: "%.0f KB", bytes / 1024)
    }

    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f %%", $0) } ?? "—" }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }
}

extension View {
    func serverCard() -> some View {
        padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}
