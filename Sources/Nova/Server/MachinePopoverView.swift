import SwiftUI

/// Máquina que muestra el desplegable: este Mac o uno de los servidores configurados.
enum Machine: Hashable {
    case local
    case server(String)
}

/// Raíz del desplegable cuando hay servidores configurados: selector de máquina arriba y,
/// debajo, el desplegable de siempre (este Mac) o el del servidor elegido.
struct MachinePopoverView: View {
    @ObservedObject var ui: MenuBarPopoverView.UIState
    let servers: [ServerStore]
    let local: MenuBarPopoverView
    var onPreferences: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MachinePicker(machine: $ui.machine, servers: servers.map(\.config))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
            if case .server(let id) = ui.machine, let store = servers.first(where: { $0.id == id }) {
                ServerPanelView(store: store, onPreferences: onPreferences, onQuit: onQuit)
            } else {
                local
            }
        }
    }
}

/// En su propia vista y sin depender de los datos, para que los refrescos no re-evalúen el
/// `Picker` segmentado (ver `MenuBarPopoverView.TabPicker`).
struct MachinePicker: View {
    @Binding var machine: Machine
    let servers: [ServerConfig]

    var body: some View {
        Picker("", selection: $machine) {
            Label("Este Mac", systemImage: "laptopcomputer").tag(Machine.local)
            ForEach(servers) { server in
                Label(server.name, systemImage: "server.rack").tag(Machine.server(server.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
