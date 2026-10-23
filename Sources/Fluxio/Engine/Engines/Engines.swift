import CryptoKit
import Foundation

/// Motores: programas grandes que Fluxio usa para algunos formatos (video, documentos de Office…). No van
/// dentro de la app para que no pese cientos de megas: se instalan con un clic desde Ajustes → Motores.
///
/// - Si el Mac ya tiene un motor (Homebrew, /usr/local, LibreOffice en Aplicaciones), se usa ese y no se
///   descarga nada.
/// - Si no, se descarga de la web oficial de su proyecto, se comprueba su huella (SHA-256) y se guarda en
///   ~/Library/Application Support/Fluxio/Motores. No pide contraseña ni usa Terminal.
enum EngineID: String, CaseIterable, Identifiable {
    case ffmpeg, pandoc, libreoffice, fonttools
    var id: String { rawValue }
}

struct EngineSpec {
    struct Download {
        let url: URL
        /// Huella oficial del archivo, para comprobar que llega intacto.
        let sha256: String?
        let bytes: Int64
    }

    let id: EngineID
    let name: String
    /// Qué añade a Fluxio.
    let adds: String
    /// Qué funciona sin él.
    let without: String
    let downloads: [Download]
    /// Espacio aproximado que ocupa instalado.
    let diskMB: Int
    /// Si no se puede instalar en este Mac, por qué (por ejemplo, la versión de macOS es antigua).
    var unavailable: String? = nil

    var downloadMB: Int { Int((downloads.reduce(0) { $0 + $1.bytes } + 524_287) / 1_048_576) }
}

enum Engines {
    static let folder: URL = {
        // Solo para pruebas: FLUXIO_ENGINES_DIR instala en otra carpeta.
        if let test = ProcessInfo.processInfo.environment["FLUXIO_ENGINES_DIR"] { return URL(fileURLWithPath: test) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluxio/Motores", isDirectory: true)
    }()

    /// Modo prueba (FLUXIO_ENGINES_DIR): se ignoran los motores que ya tenga el Mac.
    static let isTestFolder = ProcessInfo.processInfo.environment["FLUXIO_ENGINES_DIR"] != nil

    static func folder(_ id: EngineID) -> URL { folder.appendingPathComponent(id.rawValue, isDirectory: true) }

    // MARK: Catálogo

    static let all: [EngineSpec] = EngineID.allCases.map(spec)

    /// Mac con chip Apple (arm64) o Intel: cada uno descarga su versión de los motores.
    private static let isAppleChip: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    static func spec(_ id: EngineID) -> EngineSpec {
        let arm = isAppleChip
        func url(_ text: String) -> URL { URL(string: text)! }
        switch id {
        case .ffmpeg:
            let base = arm ? "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/"
                           : "https://ffmpeg.martin-riedl.de/download/macos/amd64/1789931006_9.0.2/"
            return EngineSpec(
                id: id, name: "FFmpeg (video y audio)",
                adds: "Convierte video y audio (MP4, MOV, MKV, WEBM, MP3, WAV, AAC, FLAC…), video → GIF, "
                    + "saca el sonido de un video y comprime videos.",
                without: "Imágenes, PDF, documentos y comprimidos funcionan sin él.",
                downloads: arm ? [
                    .init(url: url(base + "ffmpeg.zip"), sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924", bytes: 28_416_000),
                    .init(url: url(base + "ffprobe.zip"), sha256: "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6", bytes: 28_311_000),
                ] : [
                    .init(url: url(base + "ffmpeg.zip"), sha256: "7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4", bytes: 33_816_391),
                    .init(url: url(base + "ffprobe.zip"), sha256: "2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd", bytes: 33_719_233),
                ],
                diskMB: arm ? 150 : 170)
        case .pandoc:
            // Pandoc 3.12 pide macOS 15. En los Mac Intel con macOS 13 o 14 se usa la 3.8.1 (la última hecha
            // para macOS 13). Los Mac con chip Apple pueden actualizarse gratis a macOS 15.
            let modern = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
            let download: EngineSpec.Download
            if arm {
                download = .init(url: url("https://github.com/jgm/pandoc/releases/download/3.12.1/pandoc-3.12.1-arm64-macOS.zip"),
                                 sha256: "c2146cf33a583f3ac93eccddf1bb662371d5cfcce1aad1c87ad860cca1435d46", bytes: 42_313_957)
            } else if modern {
                download = .init(url: url("https://github.com/jgm/pandoc/releases/download/3.12.1/pandoc-3.12.1-x86_64-macOS.zip"),
                                 sha256: "81ed3e2cfecf096df15d407152f89a684fd65221082b919963f738e977fad3bc", bytes: 26_487_481)
            } else {
                download = .init(url: url("https://github.com/jgm/pandoc/releases/download/3.8.1/pandoc-3.8.1-x86_64-macOS.zip"),
                                 sha256: "b7b15d770738836c40c68ab51c0a20d4c4fa91fb0ace886cb52cff8334c03ead", bytes: 23_708_249)
            }
            return EngineSpec(
                id: id, name: "Pandoc (documentos)",
                adds: "Convierte entre Word (DOCX), ODT, RTF, HTML, Markdown, EPUB y texto.",
                without: "PDF, imágenes y hojas de cálculo funcionan sin él.",
                downloads: [download],
                diskMB: arm ? 160 : 110,
                unavailable: arm && !modern
                    ? "Necesita macOS 15 o posterior. Tu Mac puede actualizarse gratis en Ajustes del Sistema → General → "
                        + "Actualización de software."
                    : nil)
        case .libreoffice:
            return EngineSpec(
                id: id, name: "LibreOffice (Office antiguo y presentaciones)",
                adds: "Abre DOC, XLS, PPT, Pages, Numbers, Keynote y ODP; pasa presentaciones a PDF o imágenes, "
                    + "PDF a PowerPoint, y hace que Word → PDF respete el diseño original.",
                without: "DOCX, XLSX, CSV y PDF básicos funcionan sin él.",
                downloads: [arm
                    ? .init(url: url("https://download.documentfoundation.org/libreoffice/stable/26.8.1/mac/aarch64/LibreOffice_26.8.1_MacOS_aarch64.dmg"),
                            sha256: "ca074e0b13571efb30a31fc531c5f95e997030637325e5d5de92d67aefdf0dfc", bytes: 298_845_477)
                    : .init(url: url("https://download.documentfoundation.org/libreoffice/stable/26.8.1/mac/x86_64/LibreOffice_26.8.1_MacOS_x86-64.dmg"),
                            sha256: "4c7464313a529e9074400cbcdc894fc40ac4ef9421ded03b16b5a78d12cb155e", bytes: 309_092_706)],
                diskMB: 900)
        case .fonttools:
            return EngineSpec(
                id: id, name: "FontTools (fuentes tipográficas)",
                adds: "Convierte fuentes entre TTF, OTF, WOFF y WOFF2.",
                without: "Todo lo demás funciona sin él.",
                downloads: [arm
                    ? .init(url: url("https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-aarch64-apple-darwin-install_only_stripped.tar.gz"),
                            sha256: "9866e11cf2ae9caa1e671383786f248859a52dd8bfb702fb4c0dc2c65f1d36de", bytes: 25_052_618)
                    : .init(url: url("https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-x86_64-apple-darwin-install_only_stripped.tar.gz"),
                            sha256: "d09998f85752b646873a8a6bc7eea442a0d251b1c8d2413aa8ea06ef131c3335", bytes: 24_774_808)],
                diskMB: 90)
        }
    }

    // MARK: Dónde está cada motor

    private static let systemFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Si el Mac ya tiene el motor (instalado aparte de Fluxio), dónde está.
    static func onMac(_ id: EngineID) -> String? {
        if isTestFolder { return nil }
        func tool(_ name: String) -> String? {
            systemFolders.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        switch id {
        case .ffmpeg:
            guard let ffmpeg = tool("ffmpeg"), tool("ffprobe") != nil else { return nil }
            return URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().path
        case .pandoc: return tool("pandoc")
        case .libreoffice:
            return ["/Applications/LibreOffice.app", NSHomeDirectory() + "/Applications/LibreOffice.app"]
                .first { FileManager.default.isExecutableFile(atPath: $0 + "/Contents/MacOS/soffice") }
        case .fonttools: return tool("fonttools")
        }
    }

    /// Si Fluxio instaló el motor (en su carpeta).
    static func isInstalledByFluxio(_ id: EngineID) -> Bool {
        let base = folder(id)
        let check: [String]
        switch id {
        case .ffmpeg: check = ["ffmpeg", "ffprobe"]
        case .pandoc: check = ["pandoc"]
        case .libreoffice: check = ["LibreOffice.app/Contents/MacOS/soffice"]
        case .fonttools: check = ["python/bin/python3"]
        }
        return check.allSatisfy { FileManager.default.isExecutableFile(atPath: base.appendingPathComponent($0).path) }
    }

    static func isAvailable(_ id: EngineID) -> Bool { onMac(id) != nil || isInstalledByFluxio(id) }

    /// Herramientas que vienen dentro de Fluxio (WebP y Potrace) y las de los motores instalados por Fluxio.
    static var toolFolders: [URL] {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources.appendingPathComponent("Tools")) }
        folders.append(folder(.ffmpeg))
        folders.append(folder(.pandoc))
        return folders
    }

    static var sofficeInFluxio: URL { folder(.libreoffice).appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice") }
    static var pythonInFluxio: URL { folder(.fonttools).appendingPathComponent("python/bin/python3") }

    // MARK: Instalar y quitar

    /// Descarga, comprueba e instala. `progress` recibe (fracción 0…1 o nil si no se sabe, qué está haciendo).
    static func install(_ id: EngineID, progress: @escaping (Double?, String) -> Void) async throws {
        let spec = spec(id)
        if let reason = spec.unavailable { throw ConversionError.message(reason) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try checkFreeSpace(for: spec)
        let work = folder.appendingPathComponent(".\(id.rawValue)-descarga", isDirectory: true)
        let staging = folder.appendingPathComponent(".\(id.rawValue)-instalando", isDirectory: true)
        try? fm.removeItem(at: work)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: staging) }

        // 1) Descargar (80 % de la barra) y comprobar cada archivo.
        let total = Double(spec.downloads.reduce(0) { $0 + $1.bytes })
        var done = 0.0
        var files: [URL] = []
        for download in spec.downloads {
            let target = work.appendingPathComponent(download.url.lastPathComponent)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = done
            try await Downloader.fetch(download.url, to: target) { received in
                progress(min(0.8, (before + Double(received)) / total * 0.8), "Descargando…")
            }
            done += Double(download.bytes)
            if let expected = download.sha256 {
                progress(min(0.8, done / total * 0.8), "Comprobando la descarga…")
                guard try sha256(of: target) == expected else {
                    throw ConversionError.message("La descarga de \(spec.name) llegó dañada o cambió. Vuelve a intentarlo más tarde.")
                }
            }
            files.append(target)
        }
        // Último momento para cancelar: desde aquí se deja terminar, para no dejar el motor a medias.
        try Task.checkCancellation()

        // 2) Instalar en una carpeta provisional.
        progress(0.85, "Instalando…")
        switch id {
        case .ffmpeg:
            for zip in files { try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path]) }
        case .pandoc:
            let unpacked = work.appendingPathComponent("zip")
            try run("/usr/bin/ditto", ["-x", "-k", files[0].path, unpacked.path])
            guard let binary = find("pandoc", in: unpacked) else { throw broken(spec) }
            try fm.moveItem(at: binary, to: staging.appendingPathComponent("pandoc"))
        case .libreoffice:
            let mount = work.appendingPathComponent("disco")
            try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                         "-mountpoint", mount.path, files[0].path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            try run("/usr/bin/ditto", [mount.appendingPathComponent("LibreOffice.app").path,
                                       staging.appendingPathComponent("LibreOffice.app").path])
        case .fonttools:
            try run("/usr/bin/tar", ["-xzf", files[0].path, "-C", staging.path])
            progress(0.9, "Instalando FontTools…")
            // fontTools y brotli (para WOFF2) se instalan desde PyPI, el repositorio oficial de Python, con versión
            // fija y su huella SHA-256: si lo que llega no es exactamente eso, pip no instala nada.
            let requirements = work.appendingPathComponent("requisitos.txt")
            try Self.fontToolsRequirements.write(to: requirements, atomically: true, encoding: .utf8)
            try run(staging.appendingPathComponent("python/bin/python3").path,
                    ["-m", "pip", "install", "--disable-pip-version-check", "--no-warn-script-location",
                     "--quiet", "--require-hashes", "--only-binary=:all:", "-r", requirements.path])
        }

        // 3) Comprobar que funciona antes de darlo por instalado.
        progress(0.97, "Comprobando…")
        try verify(id, in: staging)
        let final = folder(id)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: staging, to: final)
        progress(1, "Instalado")
    }

    /// Versiones exactas de fontTools y brotli, con las huellas de PyPI (Python 3.12, chip Apple e Intel).
    private static let fontToolsRequirements = """
    fonttools==4.66.1 \\
        --hash=sha256:8526b2b7ec4db6b81efb83438be52b1264eda9a4994d867163cfe8c65581ce8d \\
        --hash=sha256:6946fe7bfb28590a1fd4061a17609c9a843952deb65dcf30d1fe725070c3e7a4 \\
        --hash=sha256:7234ae9e28db64273fbbfa72caebd0a97e3bdba6b05064114741b9539ef339d0
    brotli==1.2.0 \\
        --hash=sha256:35d382625778834a7f3061b15423919aa03e4f5da34ac8e02c074e4b75ab4f84 \\
        --hash=sha256:7a61c06b334bd99bc5ae84f1eeb36bfe01400264b3c352f968c6e30a10f9d08b

    """

    /// Fases en las que el botón «Cancelar» detiene la instalación (las de antes de instalar).
    static let cancellablePhases: Set<String> = ["Preparando…", "Descargando…", "Comprobando la descarga…"]

    /// Antes de descargar: ¿cabe la descarga y el motor instalado? Si no, se dice cuánto falta (y no se descarga nada).
    private static func checkFreeSpace(for spec: EngineSpec) throws {
        let needed = Int64(spec.downloadMB + spec.diskMB) * 1_048_576
        guard let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, free < needed else { return }
        let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        throw ConversionError.message("Para instalar \(spec.name) hacen falta unos \(size(needed)) libres y en tu Mac "
                                      + "quedan \(size(free)). Libera espacio y vuelve a intentarlo.")
    }

    static func remove(_ id: EngineID) throws {
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// Quita la copia que ya tenía el Mac (no la instaló Fluxio): si es de Homebrew, se desinstala con
    /// Homebrew; si no (LibreOffice en Aplicaciones, un programa suelto), va a la Papelera (recuperable).
    static func removeFromMac(_ id: EngineID) throws {
        guard let path = onMac(id) else { return }
        let formula: String? = {
            switch id {
            case .ffmpeg: return "ffmpeg"
            case .pandoc: return "pandoc"
            case .fonttools: return "fonttools"
            case .libreoffice: return nil
            }
        }()
        let target = id == .ffmpeg ? URL(fileURLWithPath: path).appendingPathComponent("ffmpeg") : URL(fileURLWithPath: path)
        let real = target.resolvingSymlinksInPath().path
        if let formula, real.contains("/Cellar/"),
           let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            do {
                try run(brew, ["uninstall", formula])
            } catch {
                throw ConversionError.message("Homebrew no pudo quitar \(spec(id).name): \(error.localizedDescription)")
            }
            return
        }
        let items = id == .ffmpeg ? ["ffmpeg", "ffprobe"].map { URL(fileURLWithPath: path).appendingPathComponent($0) }
                                  : [URL(fileURLWithPath: path)]
        for item in items { try FileManager.default.trashItem(at: item, resultingItemURL: nil) }
    }

    // MARK: Ayudantes

    private static func verify(_ id: EngineID, in base: URL) throws {
        let spec = spec(id)
        switch id {
        case .ffmpeg:
            for name in ["ffmpeg", "ffprobe"] {
                let tool = base.appendingPathComponent(name)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
                guard (try? run(tool.path, ["-version"])) != nil else { throw broken(spec) }
            }
        case .pandoc:
            guard (try? run(base.appendingPathComponent("pandoc").path, ["--version"])) != nil else { throw broken(spec) }
        case .libreoffice:
            let soffice = base.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice")
            guard FileManager.default.isExecutableFile(atPath: soffice.path) else { throw broken(spec) }
        case .fonttools:
            guard (try? run(base.appendingPathComponent("python/bin/python3").path,
                            ["-c", "import fontTools, brotli"])) != nil else { throw broken(spec) }
        }
    }

    private static func broken(_ spec: EngineSpec) -> ConversionError {
        .message("\(spec.name) se descargó pero no funciona en este Mac. Vuelve a intentarlo o avísame.")
    }

    private static func find(_ name: String, in folder: URL) -> URL? {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            if item.lastPathComponent == name, FileManager.default.isExecutableFile(atPath: item.path) { return item }
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ConversionError.toolFailed(name: URL(fileURLWithPath: tool).lastPathComponent,
                                             details: text.split(separator: "\n").suffix(2).joined(separator: " "))
        }
        return text
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Descarga un archivo informando de cuánto lleva.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, onProgress: @escaping (Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func fetch(_ url: URL, to destination: URL, onProgress: @escaping (Int64) -> Void) async throws {
        let downloader = Downloader(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        // «Cancelar» en Motores: se corta la descarga al momento.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status >= 400 {
            moveError = ConversionError.message("El servidor de descarga respondió con un error (\(status)). Inténtalo más tarde.")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: ConversionError.cancelled)
        } else if let error {
            continuation?.resume(throwing: ConversionError.message(
                "No se pudo descargar (\(error.localizedDescription)). Comprueba la conexión a internet."))
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
