import AppKit

/// El comando `fluxio` de Terminal (lo instala Ajustes → Automático). Ejemplos:
///   fluxio foto.heic a jpg
///   fluxio *.png a webp -o ~/Desktop
///   fluxio opciones video.mov
@MainActor
enum CommandLineTool {
    static let help = """
    Fluxio: convierte archivos desde Terminal.

    Uso:
      fluxio <archivos…> a <formato>      Convierte (ej: fluxio foto.heic a jpg)
      fluxio opciones <archivos…>          Muestra a qué formatos se puede convertir
      fluxio ayuda                         Muestra esta ayuda

    Opciones:
      -o, --salida <carpeta>   Guarda los resultados en esa carpeta
      --sobrescribir           Reemplaza archivos con el mismo nombre (nunca el original)

    El resto (calidad, tamaño, nombre…) se toma de Ajustes de Fluxio.
    """

    static func run(_ arguments: [String]) -> Int32 {
        _ = NSApplication.shared
        var args = arguments
        guard let first = args.first, !["ayuda", "help", "-h", "--help", "--ayuda"].contains(first) else {
            print(help); return 0
        }
        if ["opciones", "options", "--opciones"].contains(first) {
            args.removeFirst()
            return listOptions(paths: args)
        }

        var target: String?
        var output: String?
        var overwrite = false
        var paths: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch arg {
            case "-o", "--salida", "--out":
                output = next; i += 2; continue
            case "--a", "--to", "-t":
                target = next; i += 2; continue
            case "--sobrescribir", "--overwrite":
                overwrite = true
            case "a", "to":
                // "a png" = formato de destino (salvo que exista un archivo que se llame "a").
                if let next, !FileManager.default.fileExists(atPath: arg) { target = next; i += 2; continue }
                paths.append(arg)
            default:
                paths.append(arg)
            }
            i += 1
        }
        guard let target, !paths.isEmpty else {
            fail("Falta el formato o los archivos. Ejemplo: fluxio foto.heic a jpg")
            return 2
        }
        return convert(paths: paths, to: target, output: output, overwrite: overwrite)
    }

    // MARK: Opciones

    private static func listOptions(paths: [String]) -> Int32 {
        guard !paths.isEmpty else { fail("Indica un archivo. Ejemplo: fluxio opciones foto.png"); return 2 }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { fail("No existe: \(path)"); continue }
            let options = ConversionEngine.shared.allOptions(for: FileInfo(url: url))
            print("\(url.lastPathComponent):")
            if options.isEmpty { print("  (no hay conversiones para este archivo)") }
            var shown = Set<String>()
            for option in options {
                let key = ConversionEngine.key(of: option)
                guard shown.insert(key).inserted else { continue }
                print("  " + key.padding(toLength: max(18, key.count + 2), withPad: " ", startingAt: 0) + option.accessibilityLabel)
            }
        }
        return 0
    }

    // MARK: Convertir

    private static func convert(paths: [String], to target: String, output: String?, overwrite: Bool) -> Int32 {
        let engine = ConversionEngine.shared
        var policy = AppSettings.shared.outputPolicy
        if let output {
            let folder = URL(fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            policy.customFolder = folder
            policy.subfolder = nil
        }
        if overwrite { policy.overwrite = true }

        // Agrupa los archivos por la opción que les toca (una foto y un video pueden ir "a gif" a la vez).
        var groups: [(option: WheelOption, files: [FileInfo])] = []
        var problems = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                fail("No existe: \(path)"); problems += 1; continue
            }
            let file = FileInfo(url: url)
            guard let option = engine.option(for: file, target: target) else {
                fail("\(url.lastPathComponent) no se puede convertir a «\(target)». Prueba: fluxio opciones \"\(path)\"")
                problems += 1; continue
            }
            if let index = groups.firstIndex(where: { $0.option.id == option.id }) {
                groups[index].files.append(file)
            } else {
                groups.append((option, [file]))
            }
        }

        let showProgress = isatty(STDERR_FILENO) != 0
        for group in groups {
            var done = false
            engine.run(group.option, on: group.files, policy: policy, onProgress: { value in
                guard showProgress else { return }
                FileHandle.standardError.write(Data(String(format: "\r  %3.0f %%", value * 100).utf8))
            }) { outcome in
                if showProgress { FileHandle.standardError.write(Data("\r        \r".utf8)) }
                outcome.outputs.forEach { print("✓ " + $0.path) }
                for failure in outcome.failures {
                    fail("\(failure.file.lastPathComponent): \(failure.error.localizedDescription)")
                }
                if outcome.cancelled { fail("Cancelado.") }
                problems += outcome.failures.count + (outcome.cancelled ? 1 : 0)
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        return problems == 0 ? 0 : 1
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
    }
}
