import Foundation
import Combine

/// Una carpeta vigilada: todo archivo nuevo que entre en `path` se convierte a `target`.
struct WatchRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var target: String = "jpg"
    var enabled = true

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }
    /// Los resultados van a esta subcarpeta (así no se vuelven a convertir).
    static let outputFolderName = "Convertidos"
    var outputURL: URL { url.appendingPathComponent(Self.outputFolderName, isDirectory: true) }

    /// Formatos que se pueden elegir en Ajustes.
    static let targets: [(id: String, label: String)] = [
        ("jpg", "JPG"), ("png", "PNG"), ("webp", "WebP"), ("heic", "HEIC"), ("gif", "GIF"), ("svg", "SVG (vector)"),
        ("pdf", "PDF"), ("mp4", "MP4"), ("mov", "MOV"), ("webm", "WebM"), ("mp3", "MP3"), ("m4a", "M4A"),
        ("wav", "WAV"), ("docx", "Word (DOCX)"), ("txt", "Texto (TXT)"), ("md", "Markdown"), ("zip", "ZIP"),
    ]
}

/// Vigila las carpetas de Ajustes → Automático y convierte los archivos nuevos en cuanto terminan de copiarse.
@MainActor
final class FolderWatcher {
    static let shared = FolderWatcher()

    private final class Watch {
        let rule: WatchRule
        let source: DispatchSourceFileSystemObject
        /// Archivos que ya estaban o que ya se trataron (no se vuelven a convertir).
        var known: Set<String>
        /// Archivos nuevos esperando a que dejen de crecer: ruta → último tamaño visto y cuántas veces seguidas se repitió.
        var pending: [String: (size: Int, stable: Int)] = [:]
        init(rule: WatchRule, source: DispatchSourceFileSystemObject, known: Set<String>) {
            self.rule = rule; self.source = source; self.known = known
        }
    }

    private var watches: [UUID: Watch] = [:]
    /// En las pruebas automáticas: sin notificaciones ni Recientes.
    var quiet = false
    private var observer: AnyCancellable?
    private var timer: Timer?
    /// Las conversiones automáticas van de una en una, sin molestar a lo que hagas en la rueda.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    func start() {
        observer = AppSettings.shared.$watchRules.sink { [weak self] rules in self?.apply(rules) }
    }

    private func apply(_ rules: [WatchRule]) {
        let active = rules.filter { $0.enabled && FileManager.default.fileExists(atPath: $0.path) }
        // Quitar las que cambiaron o ya no están.
        for (id, watch) in watches where !active.contains(watch.rule) {
            watch.source.cancel()
            watches[id] = nil
        }
        for rule in active where watches[rule.id] == nil {
            let fd = open(rule.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename],
                                                                   queue: .main)
            // Lo que ya había al empezar a vigilar no se convierte.
            let watch = Watch(rule: rule, source: source, known: Set(Self.candidates(in: rule.url)))
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scan(rule.id) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watches[rule.id] = watch
        }
    }

    /// Archivos visibles de la carpeta (sin entrar en subcarpetas ni contar descargas a medias).
    private static func candidates(in folder: URL) -> [String] {
        let skip: Set<String> = ["download", "crdownload", "part", "partial", "tmp"]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                && !skip.contains($0.pathExtension.lowercased())
        }.map(\.path)
    }

    private func scan(_ id: UUID) {
        guard let watch = watches[id] else { return }
        let current = Self.candidates(in: watch.rule.url)
        watch.known.formIntersection(current)   // si se borra y vuelve a aparecer, cuenta como nuevo
        for path in current where !watch.known.contains(path) && watch.pending[path] == nil {
            watch.pending[path] = (-1, 0)
        }
        if !watch.pending.isEmpty { startTimer() }
    }

    /// Cada segundo comprueba si los archivos nuevos dejaron de crecer (copia o descarga terminada):
    /// se convierten cuando su tamaño no cambia durante `stableChecks` segundos seguidos.
    static let stableChecks = 3

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPending() }
        }
    }

    private func checkPending() {
        var anyLeft = false
        for watch in watches.values {
            for (path, last) in watch.pending {
                guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
                    watch.pending[path] = nil   // ya no existe
                    continue
                }
                let stable = size == last.size && size > 0 ? last.stable + 1 : 0
                if stable >= Self.stableChecks {
                    watch.pending[path] = nil
                    watch.known.insert(path)
                    convert(URL(fileURLWithPath: path), rule: watch.rule)
                } else {
                    watch.pending[path] = (size, stable)
                    anyLeft = true
                }
            }
        }
        if !anyLeft {
            timer?.invalidate()
            timer = nil
        }
    }

    private func convert(_ url: URL, rule: WatchRule) {
        let engine = ConversionEngine.shared
        let file = FileInfo(url: url)
        guard let option = engine.option(for: file, target: rule.target),
              let converter = engine.converters.first(where: { $0.id == option.providerID }) else { return }
        try? FileManager.default.createDirectory(at: rule.outputURL, withIntermediateDirectories: true)
        var policy = AppSettings.shared.outputPolicy
        policy.customFolder = rule.outputURL
        policy.subfolder = nil
        let context = JobContext(policy: policy) { _ in }

        queue.addOperation {
            let result = Result { try converter.run(option, on: file, context: context) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !FolderWatcher.shared.quiet else { return }
                    Self.report(result, file: url, option: option, rule: rule)
                }
            }
        }
    }

    private static func report(_ result: Result<[URL], Error>, file: URL, option: WheelOption, rule: WatchRule) {
        let settings = AppSettings.shared
        switch result {
        case .success(let outputs) where !outputs.isEmpty:
            RecentStore.shared.add(title: option.accessibilityLabel, outputs: outputs)
            if settings.showNotifications {
                Notifier.shared.notify(title: "Carpeta «\(rule.name)»",
                                       body: "\(file.lastPathComponent) → \(outputs[0].lastPathComponent)", files: outputs)
            }
        case .success:
            break
        case .failure(let error):
            if settings.showNotifications {
                Notifier.shared.notify(title: "Carpeta «\(rule.name)»",
                                       body: "No se pudo convertir \(file.lastPathComponent): \(error.localizedDescription)",
                                       files: [])
            }
        }
    }
}

/// El comando `fluxio` para Terminal: un pequeño archivo que llama a Fluxio.app.
enum TerminalCommand {
    /// Carpetas donde Terminal busca comandos y en las que se puede escribir sin contraseña.
    static let folders = ["/opt/homebrew/bin", "/usr/local/bin"]
    private static let marker = "# Creado por Fluxio"

    /// Dónde está instalado (si lo creó Fluxio).
    static var installedPath: String? {
        folders.map { $0 + "/fluxio" }.first { path in
            (try? String(contentsOfFile: path, encoding: .utf8))?.contains(marker) == true
        }
    }

    /// ¿Apunta a esta copia de Fluxio? (si moviste la app, hay que reinstalarlo)
    static var isCurrent: Bool {
        guard let path = installedPath, let executable = Bundle.main.executablePath else { return false }
        return (try? String(contentsOfFile: path, encoding: .utf8))?.contains(executable) == true
    }

    static func install() throws -> String {
        guard let executable = Bundle.main.executablePath else { throw ConversionError.unsupported }
        guard let folder = folders.first(where: { FileManager.default.isWritableFile(atPath: $0) }) else {
            throw ConversionError.message("No encontré una carpeta de comandos en la que se pueda escribir "
                                          + "(/opt/homebrew/bin o /usr/local/bin).")
        }
        let path = folder + "/fluxio"
        // MallocLargeCache=0: igual que en Info.plist (LSEnvironment), para no acumular memoria con muchas fotos grandes.
        let script = "#!/bin/sh\n\(marker)\nexport MallocLargeCache=0\nexec \"\(executable)\" --cli \"$@\"\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    static func uninstall() {
        if let path = installedPath { try? FileManager.default.removeItem(atPath: path) }
    }
}
