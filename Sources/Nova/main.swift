import AppKit

// Modo diagnóstico por línea de comandos: `Nova --dump`.
// Vuelca la lista cruda de sensores por stdout y a ./Nova-sensores.txt, y
// sale sin arrancar la GUI (útil para probar en otra máquina, incluso por SSH).
if CommandLine.arguments.contains("--dump") || CommandLine.arguments.contains("--diagnose") {
    let report = Diagnostics.buildReport()
    print(report)
    let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Nova-sensores.txt")
    if (try? report.write(to: out, atomically: true, encoding: .utf8)) != nil {
        print("Guardado en: \(out.path)")
    }
    exit(0)
}

// Reduce el retardo de los tooltips (.help) a 300 ms. NSInitialToolTipDelay va
// en milisegundos y lo lee NSToolTipManager, el mecanismo que usa .help por
// debajo. Con register(defaults:) solo aplica a este proceso, sin tocar las
// preferencias globales del usuario. Debe hacerse antes de crear la UI.
UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])

// Punto de entrada del ejecutable SwiftPM.
// Levantamos una NSApplication como "accessory" (solo barra de menú, sin icono
// en el Dock ni menú principal), equivalente a LSUIElement = YES.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
