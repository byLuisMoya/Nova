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
        vm.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        // Al cambiar la unidad hay que repintar el título de la barra.
        settings.$unit
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                    weight: .medium)
        let components = vm.menuBarComponents

        guard !components.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = " --°"
            return
        }

        // SoC se muestra SIN nombre y en el color nativo de la barra (blanco),
        // como el resto de iconos. CPU/GPU (si el chip los expone) van con
        // nombre y coloreados por severidad.
        let hasColored = components.contains { $0.category != .soc }

        if !hasColored {
            // Caso habitual (p. ej. M5): solo SoC → temperatura pelada, color
            // nativo. Usamos el título normal para que macOS lo adapte solo.
            let value = settings.unit.convert(components[0].maxValue)
            button.attributedTitle = NSAttributedString(string: "")
            button.title = " \(Int(value.rounded()))°"
            return
        }

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
        button.attributedTitle = title
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
        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(vm: vm,
                                         ui: popoverUI,
                                         onOpenWindow: { [weak self] in self?.openMainWindow() },
                                         onDiagnose: { [weak self] in self?.runDiagnostics() },
                                         onPreferences: { [weak self] in self?.openPreferences() },
                                         onQuit: { NSApp.terminate(nil) })
                .environmentObject(settings)
        )
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if popover.contentViewController == nil {
                popover.contentViewController = makePopoverContent()
            }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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
