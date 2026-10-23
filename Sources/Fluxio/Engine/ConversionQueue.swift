import Foundation

/// La cola de archivos que comparten los dos modos (Lite y Completo).
/// Lo que se agrega o convierte en uno aparece en el otro, porque los dos usan esta misma cola.
///
/// - Un **elemento** es un archivo con la conversión elegida, su estado, su avance y lo que creó.
/// - Un **trabajo** es una conversión aplicada a varios archivos a la vez (como al soltar en la rueda).
///   Los trabajos se hacen de uno en uno, en orden; dentro de cada trabajo el motor convierte varios
///   archivos a la vez.
@MainActor
final class ConversionQueue: ObservableObject {
    static let shared = ConversionQueue()

    enum Status: Equatable {
        /// Agregado, esperando a que elijas un formato y pulses Convertir.
        case waiting
        /// Esperando su turno.
        case queued
        case converting
        case done
        case failed(String)
        case cancelled

        /// Ya terminó (bien o mal): se puede volver a convertir o quitar.
        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    /// Comparable: así la fila de la lista solo se vuelve a dibujar cuando cambia su propio archivo.
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let file: FileInfo
        /// La conversión elegida (ej: "Convertir a PNG"), o `nil` si aún no se eligió.
        var option: WheelOption?
        /// Valores elegidos en una ventana de edición (recorte, corte).
        var parameters: [String: Double] = [:]
        var status: Status = .waiting
        /// Avance de este archivo (0…1) y si el formato informa de su avance.
        var progress: Double = 0
        var progressKnown = false
        /// Archivos creados.
        var outputs: [URL] = []

        var name: String { file.url.lastPathComponent }
    }

    /// Avisos para quien lanzó un trabajo (la rueda los usa para su tarjeta de progreso y resultado).
    struct Callbacks {
        var onStart: () -> Void = {}
        var onProgress: (Double) -> Void = { _ in }
        var completion: (ConversionEngine.Outcome) -> Void = { _ in }
    }

    private struct Job {
        let id = UUID()
        let option: WheelOption
        var itemIDs: [UUID]
        let parameters: [String: Double]
        let callbacks: Callbacks
    }

    @Published private(set) var items: [Item] = []
    /// Trabajo en curso y los elementos que incluye.
    @Published private(set) var runningJobID: UUID?
    private var runningItemIDs: [UUID] = []
    private var pending: [Job] = []

    private let engine = ConversionEngine.shared
    private let settings = AppSettings.shared

    var isRunning: Bool { runningJobID != nil }
    /// En las pruebas automáticas se apaga, para no llenar tus Recientes ni mostrar notificaciones.
    var recordsHistory = true

    // MARK: - Agregar y elegir formato

    /// Agrega archivos a la lista, sin convertirlos todavía. Los que ya estaban esperando no se repiten.
    @discardableResult
    func add(_ urls: [URL]) -> [UUID] {
        var ids: [UUID] = []
        for url in urls {
            if let existing = items.first(where: { $0.file.url == url && $0.status == .waiting }) {
                ids.append(existing.id)
                continue
            }
            let item = Item(file: FileInfo(url: url))
            items.append(item)
            ids.append(item.id)
        }
        return ids
    }

    /// Conversiones posibles para un elemento (sin las que abren una ventana de edición).
    func options(for id: UUID) -> [WheelOption] {
        guard let item = item(id) else { return [] }
        return engine.allOptions(for: item.file)
    }

    func setOption(_ option: WheelOption?, for id: UUID) {
        update(id) { item in
            item.option = option
            if item.status.isFinished { item.status = .waiting }
        }
    }

    // MARK: - Convertir

    /// Convierte ya (la rueda lo usa al soltar): agrega los archivos y los pone en la fila.
    @discardableResult
    func submit(_ option: WheelOption, files: [FileInfo], parameters: [String: Double] = [:],
                callbacks: Callbacks = Callbacks()) -> UUID {
        var ids: [UUID] = []
        for file in files {
            var item = Item(file: file)
            item.option = option
            item.parameters = parameters
            item.status = .queued
            items.append(item)
            ids.append(item.id)
        }
        let job = Job(option: option, itemIDs: ids, parameters: parameters, callbacks: callbacks)
        pending.append(job)
        startNext()
        return job.id
    }

    /// Convierte los elementos indicados que tengan un formato elegido y no estén ya en marcha.
    /// Los que comparten formato van juntos en un mismo trabajo (así se convierten varios a la vez).
    func convert(_ ids: [UUID]) {
        var groups: [(option: WheelOption, parameters: [String: Double], ids: [UUID])] = []
        for id in ids {
            guard let item = item(id), let option = item.option,
                  item.status == .waiting || item.status.isFinished else { continue }
            if let i = groups.firstIndex(where: { $0.option.id == option.id && $0.parameters == item.parameters }) {
                groups[i].ids.append(id)
            } else {
                groups.append((option, item.parameters, [id]))
            }
        }
        for group in groups {
            for id in group.ids {
                update(id) { $0.status = .queued; $0.progress = 0; $0.progressKnown = false; $0.outputs = [] }
            }
            pending.append(Job(option: group.option, itemIDs: group.ids, parameters: group.parameters,
                               callbacks: Callbacks()))
        }
        startNext()
    }

    /// Convierte todo lo nuevo que tenga formato elegido. Lo que falló o se canceló se reintenta uno a uno.
    func convertAll() {
        convert(items.filter { $0.option != nil && $0.status == .waiting }.map(\.id))
    }

    /// Cuántos elementos se convertirían con "Convertir todo".
    var readyCount: Int {
        items.filter { $0.option != nil && $0.status == .waiting }.count
    }

    // MARK: - Cancelar y quitar

    /// Cancela un elemento. Si ya se está convirtiendo, solo ese archivo: los que se convierten junto a él siguen
    /// (salvo en una operación de grupo, como unir, que se cancela entera).
    func cancel(_ id: UUID) {
        if let index = runningItemIDs.firstIndex(of: id) {
            engine.cancel(fileAt: index)
            return
        }
        for i in pending.indices { pending[i].itemIDs.removeAll { $0 == id } }
        pending.removeAll { $0.itemIDs.isEmpty }
        update(id) { $0.status = .cancelled }
    }

    /// Cancela un trabajo completo (la rueda lo usa con su botón "Cancelar").
    func cancelJob(_ jobID: UUID) {
        if jobID == runningJobID {
            engine.cancel()
        } else if let index = pending.firstIndex(where: { $0.id == jobID }) {
            let job = pending.remove(at: index)
            job.itemIDs.forEach { id in update(id) { $0.status = .cancelled } }
            var outcome = ConversionEngine.Outcome()
            outcome.cancelled = true
            job.callbacks.completion(outcome)
        }
    }

    /// Quita un elemento de la lista (si se está convirtiendo, primero hay que cancelarlo).
    func remove(_ id: UUID) {
        guard !runningItemIDs.contains(id) else { return }
        for i in pending.indices { pending[i].itemIDs.removeAll { $0 == id } }
        pending.removeAll { $0.itemIDs.isEmpty }
        items.removeAll { $0.id == id }
    }

    /// Quita de la lista todo lo que ya terminó.
    func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    // MARK: - Ejecución

    private func startNext() {
        guard runningJobID == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let ids = job.itemIDs.filter { item($0) != nil }
        let files = ids.compactMap { item($0)?.file }
        guard !files.isEmpty else { startNext(); return }

        runningJobID = job.id
        runningItemIDs = ids
        ids.forEach { id in update(id) { $0.status = .converting } }
        job.callbacks.onStart()

        engine.run(job.option, on: files, policy: settings.outputPolicy, parameters: job.parameters,
                   onProgress: { value in job.callbacks.onProgress(value) },
                   onFileProgress: { [weak self] index, fraction in
                       guard let self, ids.indices.contains(index) else { return }
                       self.update(ids[index]) { $0.progress = fraction; if fraction > 0 { $0.progressKnown = true } }
                   },
                   completion: { [weak self] outcome in
                       self?.finish(job, ids: ids, outcome: outcome)
                   })
    }

    private func finish(_ job: Job, ids: [UUID], outcome: ConversionEngine.Outcome) {
        for (index, id) in ids.enumerated() {
            let file = item(id)?.file.url
            let created = outcome.perFile.indices.contains(index) ? outcome.perFile[index] : []
            update(id) { item in
                item.outputs = created
                if !created.isEmpty {
                    item.status = .done
                    item.progress = 1
                } else if let failure = outcome.failures.first(where: { $0.file == file }) {
                    item.status = .failed(failure.error.localizedDescription)
                } else if outcome.cancelled {
                    item.status = .cancelled
                } else if let first = outcome.failures.first {
                    item.status = .failed(first.error.localizedDescription)   // operación de grupo que falló
                } else {
                    item.status = .failed("No se creó ningún archivo.")
                }
            }
        }
        if recordsHistory, !outcome.outputs.isEmpty {
            RecentStore.shared.add(title: job.option.accessibilityLabel, outputs: outcome.outputs)
            if settings.showNotifications, let message = Self.summary(of: outcome) {
                Notifier.shared.notify(title: "Fluxio", body: message, files: outcome.outputs)
            }
        }
        runningJobID = nil
        runningItemIDs = []
        job.callbacks.completion(outcome)
        startNext()
    }

    /// Mensaje corto con el resultado de un trabajo ("Listo: foto.png"), o `nil` si no se creó nada.
    static func summary(of outcome: ConversionEngine.Outcome) -> String? {
        let outputs = outcome.outputs
        guard !outputs.isEmpty else { return nil }
        var message = outputs.count == 1 ? "Listo: \(outputs[0].lastPathComponent)"
                                         : "Listo: \(outputs.count) archivos creados"
        if !outcome.failures.isEmpty {
            let names = outcome.failures.prefix(3).map(\.file.lastPathComponent).joined(separator: ", ")
            message += "\nNo se pudieron convertir \(outcome.failures.count): \(names)"
        } else if outcome.cancelled {
            message += "\nSe canceló antes de terminar."
        }
        return message
    }

    /// Mensaje de error cuando un trabajo no creó nada.
    static func failureMessage(of outcome: ConversionEngine.Outcome) -> String {
        if outcome.cancelled { return "Conversión cancelada." }
        if let first = outcome.failures.first {
            let more = outcome.failures.count > 1 ? " (y \(outcome.failures.count - 1) archivo(s) más)" : ""
            return first.error.localizedDescription + more
        }
        return "No se creó ningún archivo."
    }

    // MARK: - Ayudantes

    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
