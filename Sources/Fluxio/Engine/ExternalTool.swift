import Foundation

/// Ejecuta herramientas externas: las que vienen dentro de Fluxio (WebP, Potrace), las que ya tiene el Mac
/// (Homebrew) y las de los motores que instala Fluxio (Ajustes → Motores). Nunca descarga nada.
enum ExternalTool {
    private static let systemPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String) -> URL? {
        let bundled = Bundle.main.resourceURL.map { [$0.appendingPathComponent("Tools")] } ?? []
        let engines = Engines.toolFolders.filter { !bundled.contains($0) }
        // En pruebas (FLUXIO_ENGINES_DIR) solo se usan los motores de esa carpeta, no los que ya tenga el Mac.
        let system = Engines.isTestFolder ? [] : systemPaths.map { URL(fileURLWithPath: $0) }
        // Primero los que Fluxio instaló y comprobó; los del Mac (Homebrew…), después.
        for dir in bundled + engines + system {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Busca la herramienta o lanza un error que indica qué motor instalar.
    static func require(_ name: String, engine: String) throws -> URL {
        guard let url = find(name) else { throw ConversionError.missingTool(name: name, install: engine) }
        return url
    }

    /// Ejecuta y espera. Si el usuario cancela, detiene el proceso.
    /// `onOutputLine` recibe cada línea que la herramienta escribe en su salida normal.
    /// `outputFile` guarda directamente en disco lo que la herramienta escribe (ej: gzip -c).
    static func run(_ tool: URL, arguments: [String], context: JobContext, currentDirectory: URL? = nil,
                    outputFile: URL? = nil, onOutputLine: ((String) -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let errorPipe = Pipe()
        process.standardError = errorPipe
        var errorData = Data()
        let lock = NSLock()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            errorData.append(chunk)
            // Solo guardamos el final: ffmpeg puede escribir mucho.
            if errorData.count > 64_000 { errorData = errorData.suffix(16_000) }
            lock.unlock()
        }

        let outputPipe = Pipe()
        if let onOutputLine {
            process.standardOutput = outputPipe
            var buffer = Data()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                buffer.append(handle.availableData)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    onOutputLine(line)
                }
            }
        } else if let outputFile {
            FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: outputFile)
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        func stopReading() {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputPipe.fileHandleForReading.readabilityHandler = nil
        }

        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            if context.isCancelled {
                process.terminate()
                finished.wait()
                stopReading()
                throw ConversionError.cancelled
            }
        }
        stopReading()

        if process.terminationStatus != 0 {
            lock.lock()
            let message = lastLines(of: String(decoding: errorData, as: UTF8.self))
            lock.unlock()
            throw ConversionError.toolFailed(name: tool.lastPathComponent,
                                             details: message.isEmpty ? "código \(process.terminationStatus)" : message)
        }
    }

    /// Ejecuta una herramienta rápida y devuelve lo que escribe (ej: ffprobe).
    static func capture(_ tool: URL, arguments: [String]) throws -> String {
        try captureData(tool, arguments: arguments).string
    }

    /// Igual que `capture`, pero devuelve los bytes (para XML con cualquier codificación).
    static func captureData(_ tool: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    static let system = (zip: URL(fileURLWithPath: "/usr/bin/zip"), unzip: URL(fileURLWithPath: "/usr/bin/unzip"),
                         tar: URL(fileURLWithPath: "/usr/bin/tar"), gzip: URL(fileURLWithPath: "/usr/bin/gzip"),
                         ditto: URL(fileURLWithPath: "/usr/bin/ditto"))

    private static func lastLines(of text: String, count: Int = 3) -> String {
        text.split(separator: "\n").suffix(count).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Data {
    var string: String { String(decoding: self, as: UTF8.self) }
}
