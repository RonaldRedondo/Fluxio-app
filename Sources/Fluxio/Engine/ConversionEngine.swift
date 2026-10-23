import Foundation

/// Registro de conversores + ejecución de tareas en segundo plano (varios archivos a la vez) con progreso y cancelación.
@MainActor
final class ConversionEngine: ObservableObject {
    static let shared = ConversionEngine()

    struct Job {
        let title: String
        var progress: Double
        let token: CancellationToken
        /// Uno por archivo, en el mismo orden: cancelar uno solo para ese archivo.
        var fileTokens: [CancellationToken] = []
    }

    @Published private(set) var job: Job?

    private(set) var converters: [Converter] = []

    init() {
        // ➕ Para añadir formatos nuevos, registra aquí su conversor.
        register(ImageConverter())
        register(ImageToolsConverter())
        register(VectorConverter())
        register(MediaConverter())
        register(DocumentConverter())
        register(SpreadsheetConverter())
        register(SubtitleConverter())
        register(FontConverter())
        register(OfficeConverter())
        register(DataConverter())
        register(ComicConverter())
        register(ModelConverter())
        register(ArchiveConverter(mode: .convert))
        register(MediaToolsConverter())
        register(PDFToolsConverter())
        register(MetadataToolsConverter())
        register(ArchiveConverter(mode: .tools))
    }

    func register(_ converter: Converter) {
        converters.append(converter)
    }

    /// Máximo de gajos en una rueda antes de agrupar las opciones secundarias en "Más…".
    static let maxSlices = 8

    /// Opciones de una rueda para los archivos soltados.
    func options(for files: [FileInfo], mode: WheelMode) -> [WheelOption] {
        guard !files.isEmpty else { return [] }
        let all = converters.filter { $0.mode == mode }.flatMap { $0.options(for: files) }
        return Self.fold(WheelCustomizer.apply(all, files: files, mode: mode))
    }

    /// Si hay demasiadas opciones, las secundarias pasan a una segunda rueda ("Más…").
    /// Como mucho `maxSlices` gajos por rueda, para que los títulos se lean bien: las primeras opciones (las
    /// principales antes que las secundarias) y un «Más…» con el resto, que a su vez se reparte igual (puede
    /// haber un «Más…» dentro de otro).
    /// Las que la persona puso «En Más…» van siempre dentro.
    static func fold(_ options: [WheelOption]) -> [WheelOption] {
        let forced = options.filter(\.inMore).map { o -> WheelOption in var c = o; c.inMore = false; return c }
        let rest = options.filter { !$0.inMore }
        // Si todo está «En Más…», no tiene sentido una rueda con solo «Más…»: se muestran directamente.
        if rest.isEmpty { return fold(forced) }
        let ordered = rest.filter { !$0.secondary } + rest.filter(\.secondary)
        if forced.isEmpty {
            guard ordered.count > maxSlices else { return ordered }
            let keep = maxSlices - 1
            return Array(ordered.prefix(keep)) + [.more(fold(Array(ordered.dropFirst(keep))))]
        }
        let keep = maxSlices - 1
        return Array(ordered.prefix(keep)) + [.more(fold(Array(ordered.dropFirst(keep)) + forced))]
    }

    var isRunning: Bool { job != nil }

    /// Resultado de una tarea: lo creado y lo que falló (si algo falló).
    struct Outcome {
        var outputs: [URL] = []
        var failures: [(file: URL, error: Error)] = []
        var cancelled = false
        /// Lo creado por cada archivo, en el mismo orden en que se pasaron (una operación de grupo
        /// —unir, comprimir todo junto— da el mismo resultado a todos).
        var perFile: [[URL]] = []
    }

    /// Cuántos archivos se convierten a la vez (más núcleos = más a la vez, como máximo 4).
    nonisolated static let parallelLimit = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// Video y audio (FFmpeg ya usa todos los núcleos) y LibreOffice (va de uno en uno): como mucho 2 a la vez,
    /// para no calentar el Mac ni llenar la memoria. El resto, `parallelLimit`.
    nonisolated static func parallelLimit(for providerID: String) -> Int {
        ["media.convert", "media.tools", "office.convert"].contains(providerID) ? min(2, parallelLimit) : parallelLimit
    }

    /// Antes de empezar: si no hay permiso para leer el archivo, decirlo (y no «puede que esté dañado»).
    nonisolated private static func checkReadable(_ file: FileInfo) throws {
        guard FileManager.default.isReadableFile(atPath: file.url.path) else {
            throw ConversionError.message("No tengo permiso para leer “\(file.url.lastPathComponent)”. "
                                          + "Revisa sus permisos en Finder (Obtener información → Compartir y permisos).")
        }
    }

    /// Ejecuta una opción sobre varios archivos en segundo plano, varios a la vez.
    /// `onProgress` recibe el avance total (0…1) en el hilo principal, como mucho cada 1 %;
    /// `onFileProgress`, el avance de cada archivo (posición en `files`, 0…1).
    func run(_ option: WheelOption, on files: [FileInfo], policy: OutputPolicy, parameters: [String: Double] = [:],
             onProgress: @escaping @MainActor (Double) -> Void = { _ in },
             onFileProgress: @escaping @MainActor (Int, Double) -> Void = { _, _ in },
             completion: @escaping (Outcome) -> Void) {
        guard let converter = converters.first(where: { $0.id == option.providerID }) else {
            completion(Outcome(failures: files.map { ($0.url, ConversionError.unsupported) })); return
        }
        let token = CancellationToken()
        let progress = ProgressTable(count: files.count)
        let engine = self   // es único (`shared`): se puede guardar sin crear un ciclo
        let fileTokens = files.map { _ in CancellationToken() }
        // Cada archivo mira su propia bandera; una operación de grupo (unir…) mira las de todos.
        let makeContext: @Sendable (Int, [CancellationToken]) -> JobContext = { index, own in
            JobContext(policy: policy, parameters: parameters, token: token, fileTokens: own) { fraction in
                guard let overall = progress.set(index, fraction) else { return }
                Task { @MainActor in
                    engine.job?.progress = overall
                    onProgress(overall)
                    onFileProgress(index, fraction)
                }
            }
        }
        let context: @Sendable (Int) -> JobContext = { makeContext($0, [fileTokens[$0]]) }
        let title = files.count == 1 ? files[0].url.lastPathComponent : "\(files.count) archivos"
        job = Job(title: title, progress: 0, token: token, fileTokens: fileTokens)

        Task.detached(priority: .userInitiated) {
            var outcome = Outcome()
            do {
                // Operaciones de grupo (unir, comprimir todo junto…).
                if let batch = try converter.runBatch(option, on: files, context: makeContext(0, fileTokens)) {
                    outcome.outputs = batch
                    outcome.perFile = Array(repeating: batch, count: files.count)
                } else {
                    outcome = Self.runEach(converter, option, files, limit: Self.parallelLimit(for: converter.id),
                                           context: context)
                }
            } catch {
                outcome.failures = [(files[0].url, error)]
                outcome.perFile = Array(repeating: [], count: files.count)
            }
            if token.isCancelled { outcome.cancelled = true }
            let finished = outcome
            await MainActor.run {
                self.job = nil
                completion(finished)
            }
        }
    }

    /// Convierte cada archivo por separado, `limit` a la vez. Mantiene el orden original en el resultado.
    nonisolated private static func runEach(_ converter: Converter, _ option: WheelOption, _ files: [FileInfo],
                                            limit: Int, context: @Sendable (Int) -> JobContext) -> Outcome {
        let results = ResultTable(count: files.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = limit
        for (i, file) in files.enumerated() {
            let ctx = context(i)
            queue.addOperation {
                do {
                    try ctx.checkCancelled()
                    try checkReadable(file)
                    results.set(i, .success(try converter.run(option, on: file, context: ctx)))
                    ctx.report(1)   // archivo terminado: cuenta en la barra aunque el formato no informe de su avance
                } catch {
                    results.set(i, .failure(error))
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        var outcome = Outcome(perFile: Array(repeating: [], count: files.count))
        for (i, result) in results.all.enumerated() {
            switch result {
            case .success(let urls):
                outcome.outputs += urls
                outcome.perFile[i] = urls
            case .failure(ConversionError.cancelled): outcome.cancelled = true
            case .failure(let error): outcome.failures.append((files[i].url, error))
            case nil: break
            }
        }
        return outcome
    }

    func cancel() {
        job?.token.cancel()
    }

    /// Cancela solo un archivo del trabajo en curso (posición en `files`); los demás siguen.
    func cancel(fileAt index: Int) {
        guard let tokens = job?.fileTokens, tokens.indices.contains(index) else { return }
        tokens[index].cancel()
    }
}

/// Progreso de cada archivo; devuelve la media total solo si avanzó al menos un 1 % (para no saturar la interfaz).
private final class ProgressTable: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    private var lastSent = -1.0
    init(count: Int) { values = Array(repeating: 0, count: max(1, count)) }
    func set(_ index: Int, _ value: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        values[min(index, values.count - 1)] = value
        let total = values.reduce(0, +) / Double(values.count)
        guard total - lastSent >= 0.01 || total >= 1 else { return nil }
        lastSent = total
        return total
    }
}

/// Resultado de cada archivo, guardado desde varios hilos.
private final class ResultTable: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<[URL], Error>?]
    init(count: Int) { values = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: Result<[URL], Error>) {
        lock.lock(); values[index] = value; lock.unlock()
    }
    var all: [Result<[URL], Error>?] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
