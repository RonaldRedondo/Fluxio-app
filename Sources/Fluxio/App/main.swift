import AppKit

// Inter (la tipografía de Fluxio) va dentro de la app: se registra antes de dibujar nada.
Fonts.registerBundled()

//   Fluxio --fonttest  → dice qué tipografía se está usando (debe ser Inter).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--fonttest" {
    for style in [DesignTokens.Typography.body, DesignTokens.Typography.headline, DesignTokens.Typography.mono] {
        let font = Fonts.nsFont(style)
        print(font.fontName, font.pointSize)
    }
    exit(Fonts.isInterAvailable ? 0 : 1)
}

//   Fluxio --enginetest estado | <motor>  → qué motores hay, o instala uno (para probar).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--enginetest" {
    let arg = CommandLine.arguments[2]
    if arg == "estado" {
        for id in EngineID.allCases {
            print(id.rawValue, Engines.onMac(id).map { "en tu Mac: \($0)" } ?? (Engines.isInstalledByFluxio(id) ? "instalado por Fluxio" : "no está"))
        }
        exit(0)
    }
    guard let id = EngineID(rawValue: arg) else { print("motor desconocido"); exit(1) }
    let done = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    let start = Date()
    Task.detached {
        var last = -1
        do {
            try await Engines.install(id) { fraction, phase in
                let step = Int((fraction ?? 0) * 10)
                if step != last { last = step; print(String(format: "%3.0f %% %@", (fraction ?? 0) * 100, phase)) }
            }
            print(String(format: "✓ instalado en %.0f s", Date().timeIntervalSince(start)))
        } catch {
            print("✗ \(error.localizedDescription)"); status = 1
        }
        done.signal()
    }
    done.wait()
    exit(status)
}

// Comando `fluxio` de Terminal: Fluxio --cli <argumentos…>
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--cli" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    exit(MainActor.assumeIsolated { CommandLineTool.run(args) })
}

if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--queuetest" {
    let args = CommandLine.arguments
    exit(MainActor.assumeIsolated { QueueTest.run(folder: args[2], image1: args[3], image2: args[4], video: args[5]) })
}

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--watchtest" {
    exit(MainActor.assumeIsolated { WatchTest.run(folder: CommandLine.arguments[2], sample: CommandLine.arguments[3]) })
}

// Modo de prueba sin interfaz (lo usa el desarrollador para verificar conversiones):
//   Fluxio --selftest <archivo> <carpeta-de-salida>
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--selftest" {
    exit(MainActor.assumeIsolated { SelfTest.run(file: CommandLine.arguments[2], outputFolder: CommandLine.arguments[3]) })
}

//   Fluxio --batchtest <carpeta-de-salida> <archivo1> <archivo2> …
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--batchtest" {
    let args = CommandLine.arguments
    exit(MainActor.assumeIsolated { SelfTest.run(files: Array(args[3...]), outputFolder: args[2]) })
}

//   Fluxio --paralleltest <opción> <carpeta-de-salida> <archivos…>
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--paralleltest" {
    let args = CommandLine.arguments
    exit(MainActor.assumeIsolated {
        _ = NSApplication.shared
        return ParallelTest.run(optionID: args[2], outputFolder: args[3], files: Array(args[4...]))
    })
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot-settings" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Snapshot.settings(folder: CommandLine.arguments[2])
    }
    exit(0)
}

if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "--optionstest" {
    let args = CommandLine.arguments
    exit(MainActor.assumeIsolated { OptionsTest.run(folder: args[2], image: args[3], video: args[4], pdf: args[5]) })
}

// Fluxio --cancelonetest <carpeta-de-salida> <video1> <video2>: cancelar solo un archivo de un trabajo.
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--cancelonetest" {
    let args = CommandLine.arguments
    exit(MainActor.assumeIsolated { CancelTest.runOne(outputFolder: args[2], files: Array(args[3...4])) })
}

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--canceltest" {
    exit(CancelTest.run(file: CommandLine.arguments[2], outputFolder: CommandLine.arguments[3]))
}

if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--snapshot-progress" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Snapshot.progress(folder: CommandLine.arguments[2], file: CommandLine.arguments[3], optionID: CommandLine.arguments[4])
    }
    exit(0)
}

if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--snapshot-editors" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Snapshot.editors(folder: CommandLine.arguments[2], image: CommandLine.arguments[3], video: CommandLine.arguments[4])
    }
    exit(0)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--morphtest" {
    exit(MainActor.assumeIsolated { MorphTest.run(folder: CommandLine.arguments[2]) })
}

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--snapshot-full" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Snapshot.full(folder: CommandLine.arguments[2], files: Array(CommandLine.arguments[3...]))
    }
    exit(0)
}

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--snapshot" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Snapshot.run(folder: CommandLine.arguments[2], sample: CommandLine.arguments[3])
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // Solo barra de menú, sin icono en el Dock
    app.run()
}
