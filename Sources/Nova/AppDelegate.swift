import AppKit
import SwiftUI
import Combine

/// Gestiona el item de la barra de menú (NSStatusItem), el popover con la UI
/// SwiftUI y una ventana principal opcional.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {

    private let vm = ThermalViewModel()
    private let settings = AppSettings.shared
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    /// Posición y tamaño de la ventana principal al cerrarla, para reabrirla igual.
    private var mainWindowFrame: NSRect?
    private var prefsWindow: NSWindow?
    // Estado de interfaz (pestaña, "ver todos") que sobrevive a destruir el
    // contenido del desplegable y de la ventana al cerrarlos.
    private let popoverUI = MenuBarPopoverView.UIState()
    private let windowUI = MenuBarPopoverView.UIState()
    private var cancellables = Set<AnyCancellable>()
    /// Servidores de `servers.json`. Cada uno que responda añade su tramo al final del título.
    private var servers: [ServerStore] = []
    /// Ancho de cada tramo de servidor del título, en el orden en que aparecen, para saber
    /// sobre qué máquina se ha hecho clic.
    private var serverSegments: [(id: String, width: CGFloat)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --- Item de la barra de menú (junto a la batería) ---
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium",
                                   accessibilityDescription: "Nova")
            button.imagePosition = .imageLeading
            button.title = " --°"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // --- Popover (su vista SwiftUI se crea al abrirlo, ver togglePopover) ---
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        // --- Arranque del refresco + actualización del título ---
        vm.start()
        UpdateChecker.shared.start()
        vm.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        // Al cambiar la unidad hay que repintar el título de la barra.
        settings.$unit
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        setUpServers()
        updateStatusTitle()
    }

    // MARK: - Servidores remotos

    /// Arranca el sondeo de cada servidor configurado; su tramo del título se repinta con cada dato.
    private func setUpServers() {
        for config in ServerConfig.loadAll() {
            let store = ServerStore(config: config)
            servers.append(store)
            store.$snapshot.combineLatest(store.$online)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateStatusTitle() }
                .store(in: &cancellables)
            store.start()
        }
    }

    /// `  🖥 3%` por cada servidor que responde, en el color nativo de la barra.
    private func serverTitleSegments(font: NSFont) -> [(id: String, text: NSAttributedString)] {
        servers.compactMap { store in
            guard store.online, let cpu = store.snapshot?.cpu?.percent else { return nil }
            let text = NSMutableAttributedString(string: "  ", attributes: [.font: font])
            text.append(NSAttributedString(attachment: Self.serverGlyph(font: font)))
            text.append(NSAttributedString(string: " \(Int(cpu.rounded()))%",
                                           attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            return (store.id, text)
        }
    }

    /// Símbolo `server.rack` para incrustar en el título. Se pinta con `labelColor` al dibujarse,
    /// porque una imagen dentro de un texto no se tiñe sola como el `image` del botón.
    private static func serverGlyph(font: NSFont) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Servidor")?
            .withSymbolConfiguration(config) else { return attachment }
        let size = symbol.size
        attachment.image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        return attachment
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                    weight: .medium)
        let components = vm.menuBarComponents

        let segments = serverTitleSegments(font: font)
        serverSegments = segments.map { ($0.id, $0.text.size().width) }
        if !segments.isEmpty {
            // Con servidores, todo va en un título con atributos: temperatura y servidores en el
            // mismo item, para que macOS no los separe.
            let title = NSMutableAttributedString()
            let lead = components.isEmpty ? "--°" : ""
            title.append(NSAttributedString(string: " \(lead)", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            if !components.isEmpty {
                title.append(temperatureTitle(components, font: font))
            }
            segments.forEach { title.append($0.text) }
            button.attributedTitle = title
            return
        }

        guard !components.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = " --°"
            return
        }

        let hasColored = components.contains { $0.category != .soc }

        if !hasColored {
            // Caso habitual (p. ej. M5): solo SoC → temperatura pelada, color
            // nativo. Usamos el título normal para que macOS lo adapte solo.
            let value = settings.unit.convert(components[0].maxValue)
            button.attributedTitle = NSAttributedString(string: "")
            button.title = " \(Int(value.rounded()))°"
            return
        }

        button.attributedTitle = temperatureTitle(components, font: font)
    }

    /// Título de temperatura con atributos: SoC sin nombre y en color nativo; CPU/GPU con
    /// nombre y coloreados por severidad.
    private func temperatureTitle(_ components: [SensorGroup], font: NSFont) -> NSAttributedString {
        let title = NSMutableAttributedString()
        for (index, group) in components.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            let shown = Int(settings.unit.convert(group.maxValue).rounded())
            if group.category == .soc {
                // Solo temperatura, sin nombre, color nativo.
                title.append(NSAttributedString(
                    string: "\(shown)°",
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            } else {
                let segment = "\(group.category.rawValue) \(shown)°"
                title.append(NSAttributedString(string: segment, attributes: [
                    .foregroundColor: Self.nsColor(for: group.maxValue),
                    .font: font
                ]))
            }
        }
        return title
    }

    /// Escribe el informe de diagnóstico a un archivo y lo revela en el Finder.
    /// Usa el directorio temporal para no requerir permisos de TCC (Escritorio,
    /// Documentos…).
    func runDiagnostics() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nova-sensores.txt")
        do {
            try Diagnostics.writeReport(to: url)
            popover.performClose(nil)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("Nova: no se pudo escribir el diagnóstico: \(error)")
        }
    }

    /// Color (NSColor) según la misma regla de severidad de la app.
    private static func nsColor(for value: Double) -> NSColor {
        if value < 55 { return .systemGreen }
        if value <= 70 { return .systemYellow }
        return .systemRed
    }

    /// Crea la vista SwiftUI del desplegable. Se monta al abrirlo y se suelta al
    /// cerrarlo (`popoverDidClose`): una vista viva aunque el desplegable esté
    /// cerrado se sigue re-renderizando en cada refresco y retiene la memoria
    /// de SwiftUI y Charts.
    private func makePopoverContent() -> NSViewController {
        // El popover se ajusta al tamaño intrínseco de la vista SwiftUI, así que
        // la altura se adapta a los sensores visibles (con un tope, ver la vista).
        let local = MenuBarPopoverView(vm: vm,
                                       ui: popoverUI,
                                       onOpenWindow: { [weak self] in self?.openMainWindow() },
                                       onDiagnose: { [weak self] in self?.runDiagnostics() },
                                       onPreferences: { [weak self] in self?.openPreferences() },
                                       onQuit: { NSApp.terminate(nil) })
        let root: AnyView
        if servers.isEmpty {
            root = AnyView(local)
        } else {
            root = AnyView(MachinePopoverView(ui: popoverUI,
                                              servers: servers,
                                              local: local,
                                              onPreferences: { [weak self] in self?.openPreferences() },
                                              onQuit: { NSApp.terminate(nil) }))
        }
        let hosting = NSHostingController(
            rootView: root
                .environmentObject(settings)
                .environmentObject(UpdateChecker.shared)
        )
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    /// Abre el desplegable en la máquina pulsada (la temperatura o el tramo de un servidor). Si ya
    /// mostraba esa máquina lo cierra; si mostraba otra, cambia de máquina y se recoloca sin cerrarse.
    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        let (machine, anchor) = clickedMachine(in: button)
        if popover.isShown, popoverUI.machine == machine {
            popover.performClose(sender)
            return
        }
        popoverUI.machine = machine
        if popover.contentViewController == nil {
            popover.contentViewController = makePopoverContent()
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Máquina bajo el clic y el rectángulo al que apuntar la flecha del desplegable. Los tramos de
    /// servidor van al final del título; el margen derecho del botón es aproximado.
    private func clickedMachine(in button: NSStatusBarButton) -> (Machine, NSRect) {
        let bounds = button.bounds
        // Solo un clic de ratón tiene posición fiable; con teclado o VoiceOver se abre este Mac.
        guard !serverSegments.isEmpty, let event = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type)
        else { return (.local, bounds) }
        let x = button.convert(event.locationInWindow, from: nil).x
        var right = bounds.maxX - 4
        for segment in serverSegments.reversed() {
            let left = right - segment.width
            if x >= left {
                return (.server(segment.id), NSRect(x: left, y: bounds.minY, width: segment.width, height: bounds.height))
            }
            right = left
        }
        return (.local, NSRect(x: bounds.minX, y: bounds.minY, width: right - bounds.minX, height: bounds.height))
    }

    /// Abre (o trae al frente) la ventana principal con la lista detallada.
    func openMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Nova — Sensores"
            window.contentViewController = NSHostingController(
                rootView: ContentView(vm: vm, ui: windowUI).environmentObject(settings))
            window.isReleasedWhenClosed = false
            window.delegate = self
            if let frame = mainWindowFrame {
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
            mainWindow = window
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Al cerrar la ventana principal se suelta entera (se recrea al reabrirla)
    /// para que su vista deje de re-renderizarse y libere memoria.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        mainWindowFrame = window.frame
        window.contentViewController = nil
        mainWindow = nil
    }

    /// Abre (o trae al frente) la ventana de preferencias.
    func openPreferences() {
        if prefsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Preferencias"
            window.contentViewController = NSHostingController(
                rootView: PreferencesView().environmentObject(settings))
            window.isReleasedWhenClosed = false
            window.center()
            prefsWindow = window
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }
}
