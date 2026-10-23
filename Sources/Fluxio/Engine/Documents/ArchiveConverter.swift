import Compression
import Foundation

/// Comprimidos con las herramientas que ya trae macOS (ditto, tar, gzip, bzip2, hdiutil).
/// Crear: ZIP, 7Z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ y GZIP. Extraer, además: RAR, ISO, DMG, CAB, BZ2 y XZ.
///
/// - En la rueda de **conversión**: descomprimir archivos comprimidos, cambiarlos de formato,
///   y comprimir carpetas.
/// - En la rueda de **herramientas** (⌘): comprimir cualquier archivo.
struct ArchiveConverter: Converter {
    let mode: WheelMode
    var id: String { mode == .tools ? "archive.tools" : "archive.convert" }

    enum Kind: String, CaseIterable {
        case zip, sevenZip = "7z", tar, tgz, tbz, txz, gz, bz2, xz, rar, iso, dmg, cab

        var ext: String {
            switch self {
            case .tgz: return "tar.gz"
            case .tbz: return "tar.bz2"
            case .txz: return "tar.xz"
            default: return rawValue
            }
        }

        var title: String {
            switch self {
            case .gz: return "GZIP"
            case .sevenZip: return "7Z"
            default: return ext.uppercased()
            }
        }

        var symbol: String { self == .zip || self == .sevenZip ? "archivebox" : "shippingbox" }

        /// Formatos que Fluxio sabe crear (los demás solo se extraen).
        static let creatable: [Kind] = [.zip, .sevenZip, .tgz, .tar, .tbz, .txz]
        /// Los más usados van en la rueda principal.
        var isPrimary: Bool { [.zip, .sevenZip, .tgz].contains(self) }
        /// Comprimen un solo archivo, no una carpeta.
        var isSingleFile: Bool { [.gz, .bz2, .xz].contains(self) }

        static func detect(_ url: URL) -> Kind? {
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tgz }
            if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tbz }
            if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .txz }
            return Kind(rawValue: url.pathExtension.lowercased())
        }
    }

    func options(for file: FileInfo) -> [WheelOption] {
        let source = Kind.detect(file.url)
        switch mode {
        case .convert:
            if file.isDirectory {
                return Kind.creatable.map { packOption($0, "Comprimir carpeta en \($0.title)") }
            }
            guard let source else { return [] }
            var result = [option("extract", "Extraer", "arrow.up.bin", "Descomprimir")]
            if source.isSingleFile { return result }   // un .gz/.bz2/.xz suelto contiene un solo archivo
            result += Kind.creatable.filter { $0 != source }.map { packOption($0, "Convertir a \($0.title)") }
            return result
        case .tools:
            if source != nil { return [] }   // ya está comprimido
            var result = Kind.creatable.map { packOption($0, "Comprimir en \($0.title)").asSecondary }
            if !file.isDirectory {
                result.insert(option("gz", "GZIP", "arrow.down.right.and.arrow.up.left", "Comprimir en GZIP").asSecondary,
                              at: 3)
            }
            return result
        case .actions:
            return []
        }
    }

    private func packOption(_ kind: Kind, _ label: String) -> WheelOption {
        var o = option(kind.rawValue, kind.title, kind.symbol, label)
        o.secondary = !kind.isPrimary
        return o
    }

    /// Con varios archivos en la rueda ⌘: se comprimen todos juntos en "Archivo.zip", como en Finder.
    func options(for files: [FileInfo]) -> [WheelOption] {
        guard mode == .tools, files.count > 1 else { return commonOptions(for: files) }
        return [option("zipall", "ZIP", "archivebox", "Comprimir todos en un ZIP"),
                option("7zall", "7Z", "archivebox.fill", "Comprimir todos en un 7Z"),
                option("tgzall", "TAR.GZ", "shippingbox", "Comprimir todos en un TAR.GZ")]
    }

    func runBatch(_ option: WheelOption, on files: [FileInfo], context: JobContext) throws -> [URL]? {
        let act = action(of: option)
        guard let kind: Kind = ["zipall": .zip, "7zall": .sevenZip, "tgzall": .tgz][act] else { return nil }
        let fm = FileManager.default
        let first = files[0].url

        // Si vienen de carpetas distintas, los juntamos en una carpeta temporal.
        var parent = first.deletingLastPathComponent()
        var names = files.map { $0.url.lastPathComponent }
        var staging: URL?
        defer { if let staging { try? fm.removeItem(at: staging) } }
        if Set(files.map { $0.url.deletingLastPathComponent().standardizedFileURL }).count > 1 || Set(names).count < names.count {
            let folder = context.temporaryURL(ext: "juntos")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            staging = folder
            names = []
            for file in files {
                var name = file.url.lastPathComponent
                var n = 1
                while names.contains(name) { name = "\(n)-\(file.url.lastPathComponent)"; n += 1 }
                try fm.copyItem(at: file.url, to: folder.appendingPathComponent(name))
                names.append(name)
            }
            parent = folder
        }
        context.report(0.3)

        let temp = context.temporaryURL(ext: kind.ext)
        defer { try? fm.removeItem(at: temp) }
        try pack(kind, parent: parent, names: names, into: temp, context: context)
        return [try context.finalize(temp: temp, for: first, ext: kind.ext, baseName: "Archivo")]
    }

    private func option(_ action: String, _ title: String, _ symbol: String, _ label: String) -> WheelOption {
        WheelOption(id: "\(id).\(action)", providerID: id, title: title, symbol: symbol, accessibilityLabel: label)
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let action = String(option.id.dropFirst(id.count + 1))
        let input = file.url
        let fm = FileManager.default

        if action == "extract" {
            return [try extract(input, context: context)]
        }
        guard let target = Kind(rawValue: action) else { throw ConversionError.unsupported }

        // Si el original ya es un comprimido, primero lo abrimos en una carpeta temporal.
        var contentsParent = input.deletingLastPathComponent()
        var itemNames = [input.lastPathComponent]
        var baseName = input.lastPathComponent        // "foto.jpg" → "foto.jpg.zip", como hace Finder
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }

        if let source = Kind.detect(input), !file.isDirectory {
            let folder = context.temporaryURL(ext: "contenido")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            scratch = folder
            try unpack(input, kind: source, into: folder, context: context)
            contentsParent = folder
            itemNames = try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != "__MACOSX" }
            baseName = Self.stem(of: input)
        }
        context.report(0.4)

        let temp = context.temporaryURL(ext: target.ext)
        defer { try? fm.removeItem(at: temp) }
        if target == .gz {
            try ExternalTool.run(ExternalTool.system.gzip, arguments: ["-c", "-9", input.path], context: context,
                                 outputFile: temp)
        } else {
            try pack(target, parent: contentsParent, names: itemNames, into: temp, context: context)
        }
        return [try context.finalize(temp: temp, for: input, ext: target.ext, baseName: baseName)]
    }

    /// Descomprime junto al original. Si dentro hay una sola carpeta o archivo, se saca directamente.
    private func extract(_ input: URL, context: JobContext) throws -> URL {
        guard let kind = Kind.detect(input) else { throw ConversionError.unsupported }
        let fm = FileManager.default
        let folder = context.temporaryURL(ext: "contenido")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        if kind.isSingleFile {
            let inner = Self.stem(of: input)
            let temp = folder.appendingPathComponent(inner)
            try decompressSingle(input, kind: kind, to: temp, context: context)
            let innerURL = URL(fileURLWithPath: inner)
            return try context.finalize(temp: temp, for: input, ext: innerURL.pathExtension,
                                        baseName: innerURL.deletingPathExtension().lastPathComponent)
        }

        try unpack(input, kind: kind, into: folder, context: context)
        context.report(0.8)
        let items = try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        guard !items.isEmpty else { throw ConversionError.message("“\(input.lastPathComponent)” está vacío.") }

        if items.count == 1 {
            let only = folder.appendingPathComponent(items[0])
            let isDir = (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let ext = isDir ? "" : only.pathExtension
            let base = isDir ? only.lastPathComponent : only.deletingPathExtension().lastPathComponent
            return try context.finalize(temp: only, for: input, ext: ext, baseName: base)
        }
        let output = folder.appendingPathComponent("salida")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        for item in items {
            try fm.moveItem(at: folder.appendingPathComponent(item), to: output.appendingPathComponent(item))
        }
        return try context.finalize(temp: output, for: input, ext: "", baseName: Self.stem(of: input))
    }

    private func unpack(_ input: URL, kind: Kind, into folder: URL, context: JobContext) throws {
        let tool = ExternalTool.self
        switch kind {
        case .zip:
            try tool.run(tool.system.ditto, arguments: ["-x", "-k", input.path, folder.path], context: context)
        case .gz, .bz2, .xz:
            try decompressSingle(input, kind: kind, to: folder.appendingPathComponent(Self.stem(of: input)), context: context)
        case .dmg:
            try mountAndCopy(input, into: folder, context: context)
        case .sevenZip, .tar, .tgz, .tbz, .txz, .rar, .iso, .cab:
            // El tar de macOS (libarchive) abre todos estos. Ignora rutas absolutas y "../" por seguridad.
            try tool.run(tool.system.tar, arguments: ["-xf", input.path, "-C", folder.path], context: context)
        }
    }

    /// Crea un comprimido con `names` (archivos o carpetas dentro de `parent`).
    private func pack(_ kind: Kind, parent: URL, names: [String], into output: URL, context: JobContext) throws {
        let tool = ExternalTool.self
        // Un nombre que empieza por "-" (ej. "-T") no debe leerse como opción: tar recibe "--" antes de los
        // nombres y zip, "./nombre" (los guarda igual, sin el "./").
        let tarNames = ["--"] + names
        switch kind {
        case .zip:
            if names.count == 1 {
                // ditto crea ZIP iguales a "Comprimir" de Finder.
                try tool.run(tool.system.ditto, arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                                           parent.appendingPathComponent(names[0]).path, output.path],
                             context: context)
            } else {
                try tool.run(tool.system.zip, arguments: ["-r", "-q", "-y", output.path] + names.map { "./" + $0 },
                             context: context, currentDirectory: parent)
            }
        case .sevenZip:
            try tool.run(tool.system.tar, arguments: ["-c", "--format", "7zip", "-f", output.path, "-C", parent.path] + tarNames,
                         context: context)
        case .tar:
            try tool.run(tool.system.tar, arguments: ["-cf", output.path, "-C", parent.path] + tarNames, context: context)
        case .tgz:
            try tool.run(tool.system.tar, arguments: ["-czf", output.path, "-C", parent.path] + tarNames, context: context)
        case .tbz:
            try tool.run(tool.system.tar, arguments: ["-cjf", output.path, "-C", parent.path] + tarNames, context: context)
        case .txz:
            try tool.run(tool.system.tar, arguments: ["-cJf", output.path, "-C", parent.path] + tarNames, context: context)
        default:
            throw ConversionError.unsupported
        }
    }

    private func decompressSingle(_ input: URL, kind: Kind, to output: URL, context: JobContext) throws {
        let tool: URL
        switch kind {
        case .gz: tool = ExternalTool.system.gzip
        case .bz2: tool = URL(fileURLWithPath: "/usr/bin/bzip2")
        default: return try decompressXZ(input, to: output, context: context)
        }
        try ExternalTool.run(tool, arguments: ["-d", "-c", input.path], context: context, outputFile: output)
    }

    /// .xz con el descompresor de macOS (LZMA): no hace falta instalar nada.
    private func decompressXZ(_ input: URL, to output: URL, context: JobContext) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        do {
            let filter = try OutputFilter(.decompress, using: .lzma) { data in
                if let data { try writer.write(contentsOf: data) }
            }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try context.checkCancelled()
                try filter.write(chunk)
            }
            try filter.finalize()
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.message("No se pudo descomprimir el archivo .xz (puede estar dañado).")
        }
    }

    /// DMG: se monta en modo solo lectura (sin que aparezca en el Escritorio), se copia el contenido y se expulsa.
    private func mountAndCopy(_ dmg: URL, into folder: URL, context: JobContext) throws {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let mount = context.temporaryURL(ext: "montaje")
        try ExternalTool.run(hdiutil, arguments: ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                                  "-mountpoint", mount.path, dmg.path], context: context)
        defer {
            _ = try? ExternalTool.capture(hdiutil, arguments: ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: mount.path)
            .filter { !$0.hasPrefix(".") }   // archivos ocultos del disco (.Trashes, .fseventsd…)
        for item in items {
            try ExternalTool.run(ExternalTool.system.ditto,
                                 arguments: [mount.appendingPathComponent(item).path, folder.appendingPathComponent(item).path],
                                 context: context)
        }
    }

    /// "fotos.tar.gz" → "fotos", "datos.csv.gz" → "datos.csv", "fotos.zip" → "fotos".
    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz", ".zip", ".7z", ".tar", ".gz",
                       ".bz2", ".xz", ".rar", ".iso", ".dmg", ".cab"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
