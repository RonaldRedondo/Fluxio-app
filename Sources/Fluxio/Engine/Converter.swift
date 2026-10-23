import Foundation

/// Un conversor sabe qué opciones ofrecer para unos archivos y cómo ejecutarlas.
///
/// Para añadir formatos nuevos: crea un tipo que cumpla este protocolo y
/// regístralo en `ConversionEngine.init`.
protocol Converter: Sendable {
    /// Identificador único del conversor (ej: "image.convert").
    var id: String { get }
    /// En qué rueda aparecen sus opciones.
    var mode: WheelMode { get }
    /// Opciones disponibles para un archivo concreto.
    func options(for file: FileInfo) -> [WheelOption]
    /// Opciones para varios archivos a la vez. Por defecto: las que sirven para todos.
    /// Un conversor puede añadir opciones que solo tienen sentido en grupo (ej: "Unir PDFs").
    func options(for files: [FileInfo]) -> [WheelOption]
    /// Ejecuta una opción sobre un archivo. Se llama en segundo plano.
    /// Devuelve los archivos creados.
    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL]
    /// Ejecuta una opción sobre todos los archivos juntos (ej: unir). `nil` = se hace archivo por archivo.
    func runBatch(_ option: WheelOption, on files: [FileInfo], context: JobContext) throws -> [URL]?
}

extension Converter {
    func options(for files: [FileInfo]) -> [WheelOption] {
        commonOptions(for: files)
    }

    func runBatch(_ option: WheelOption, on files: [FileInfo], context: JobContext) throws -> [URL]? {
        nil
    }

    /// Opciones válidas para TODOS los archivos, en el orden del primero.
    func commonOptions(for files: [FileInfo]) -> [WheelOption] {
        guard let first = files.first else { return [] }
        var result = options(for: first)
        for file in files.dropFirst() {
            let ids = Set(options(for: file).map(\.id))
            result.removeAll { !ids.contains($0.id) }
        }
        return result
    }

    /// La parte del id después del conversor: "image.tools.crop" → "crop".
    func action(of option: WheelOption) -> String {
        String(option.id.dropFirst(id.count + 1))
    }
}

/// Errores con mensajes claros en español.
enum ConversionError: LocalizedError {
    case cancelled
    case unreadable(String)
    case writeFailed(String)
    case missingTool(name: String, install: String)
    case toolFailed(name: String, details: String)
    case unsupported
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Conversión cancelada."
        case .unreadable(let name):
            return "No pude leer “\(name)”. Puede que el archivo esté dañado o que su formato no se pueda abrir."
        case .writeFailed(let format):
            return "No pude guardar el archivo en formato \(format)."
        case .missingTool(_, let install):
            return "Falta el motor «\(install)». Instálalo con un clic en Ajustes → Motores."
        case .toolFailed(let name, let details):
            return "La herramienta “\(name)” falló: \(details)"
        case .unsupported:
            return "Esta opción no está disponible para este archivo."
        case .message(let text):
            return text
        }
    }

    var isMissingTool: Bool {
        if case .missingTool = self { return true }
        return false
    }

    /// El motivo real cuando no se puede guardar (permiso, disco lleno…); si no se reconoce, `writeFailed`.
    static func saving(_ error: Error, in folder: URL, format: String) -> ConversionError {
        let name = folder.lastPathComponent
        switch (error as NSError).code {
        case NSFileWriteNoPermissionError:
            return .message("No tengo permiso para guardar en la carpeta “\(name)”. Elige otra carpeta en Ajustes → Guardar.")
        case NSFileWriteOutOfSpaceError:
            return .message("No queda espacio en el disco para guardar el resultado.")
        case NSFileWriteVolumeReadOnlyError:
            return .message("El disco de la carpeta “\(name)” es de solo lectura: no se puede guardar ahí.")
        default:
            return .writeFailed(format)
        }
    }
}

/// Reglas de dónde y cómo guardar los resultados (copia de los Ajustes en el momento de empezar).
struct OutputPolicy: Sendable {
    /// Carpeta fija elegida en Ajustes, o `nil` para guardar junto al original.
    var customFolder: URL?
    var overwrite: Bool
    /// Calidad para formatos con pérdida (0…1).
    var quality: Double
    /// Subcarpeta junto al original (ej: "Convertidos"), o `nil`.
    var subfolder: String? = nil
    var naming = NamingOptions()
    var image = ImageOptions()
    var media = MediaOptions()
    var pdf = PDFOptions()
}

/// Contexto de una tarea: progreso, cancelación y guardado de resultados.
final class JobContext: @unchecked Sendable {
    let policy: OutputPolicy
    /// Valores elegidos en una ventana de edición (ej: zona de recorte, inicio y fin del corte).
    let parameters: [String: Double]
    /// Compartido por todos los archivos de una misma tarea: cancelarlo los cancela todos.
    let token: CancellationToken
    /// Los de cada archivo (el modo Completo cancela una sola fila): si se cancela alguno de estos, esta tarea para.
    let fileTokens: [CancellationToken]
    private let progressHandler: @Sendable (Double) -> Void

    init(policy: OutputPolicy, parameters: [String: Double] = [:], token: CancellationToken = CancellationToken(),
         fileTokens: [CancellationToken] = [], progress: @escaping @Sendable (Double) -> Void) {
        self.policy = policy
        self.parameters = parameters
        self.token = token
        self.fileTokens = fileTokens
        self.progressHandler = progress
    }

    var isCancelled: Bool { token.isCancelled || fileTokens.contains { $0.isCancelled } }

    func cancel() { token.cancel() }

    func checkCancelled() throws {
        if isCancelled { throw ConversionError.cancelled }
    }

    /// Progreso dentro del archivo actual (0…1).
    func report(_ fraction: Double) {
        progressHandler(min(max(fraction, 0), 1))
    }

    /// Un archivo temporal donde escribir antes de mover al destino final.
    func temporaryURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("converso-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    /// Mueve un archivo temporal a su sitio definitivo, respetando los Ajustes.
    /// `ext` vacío = carpeta. `baseName` reemplaza el nombre del original (sin extensión).
    func finalize(temp: URL, for input: URL, ext: String, tag: String? = nil, baseName: String? = nil) throws -> URL {
        // Con varios archivos a la vez, elegir el nombre y mover se hace de uno en uno para no pisarse.
        Self.finalizeLock.lock(); defer { Self.finalizeLock.unlock() }
        let destination = OutputLocator.url(for: input, ext: ext, tag: tag, baseName: baseName, policy: policy)
        let fm = FileManager.default
        // Primero se lleva a un nombre oculto en la carpeta de destino (si es otro disco, aquí se copia). Solo cuando
        // ya está entero se pone en su sitio: si algo falla a medias (disco lleno, disco desconectado), el archivo
        // que había con ese nombre sigue intacto.
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".fluxio-\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            try fm.moveItem(at: temp, to: staged)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)   // cambio de golpe (mismo disco)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            try? fm.removeItem(at: staged)
            throw ConversionError.saving(error, in: destination.deletingLastPathComponent(),
                                         format: ext.isEmpty ? "carpeta" : ext.uppercased())
        }
        return destination
    }
}

extension JobContext {
    static let finalizeLock = NSLock()
}

/// Bandera de cancelación que se puede compartir entre hilos.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Decide el nombre del archivo de salida.
enum OutputLocator {
    static func url(for input: URL, ext: String, tag: String?, baseName: String? = nil, policy: OutputPolicy) -> URL {
        var folder = policy.customFolder ?? input.deletingLastPathComponent()
        if policy.customFolder == nil, let sub = policy.subfolder?.trimmingCharacters(in: .whitespaces), !sub.isEmpty {
            folder = folder.appendingPathComponent(sub.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Patrón de nombre de Ajustes: {nombre}, {formato}, {fecha}, {hora}.
        var base = policy.naming.expand(name: baseName ?? input.deletingPathExtension().lastPathComponent,
                                        ext: ext.isEmpty ? "carpeta" : ext)
        if let tag { base += "-\(tag)" }

        func make(_ name: String) -> URL {
            let url = folder.appendingPathComponent(name)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }

        let first = make(base)
        let isOriginal = first.standardizedFileURL.path == input.standardizedFileURL.path
        if !isOriginal && (policy.overwrite || !FileManager.default.fileExists(atPath: first.path)) {
            return first
        }
        // Ya existe: añadimos un número, "foto (1).png", "foto (2).png"…
        var n = 1
        while true {
            let candidate = make("\(base) (\(n))")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
