// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nova",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Target en C que declara los símbolos PRIVADOS de IOKit
        // (IOHIDEventSystemClient*). Sustituye al bridging header de Xcode:
        // en SwiftPM se importa como módulo (`import CIOKitHID`).
        .target(
            name: "CIOKitHID"
        ),
        // Ejecutable (app de barra de menú, AppKit + SwiftUI).
        .executableTarget(
            name: "Nova",
            dependencies: ["CIOKitHID"],
            linkerSettings: [
                // Los símbolos IOHID* viven en IOKit.framework.
                .linkedFramework("IOKit"),
                // Los símbolos IOReport* (potencia) viven en libIOReport.dylib.
                .linkedLibrary("IOReport")
            ]
        )
    ]
)
