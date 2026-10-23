import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Metadatos (rueda ⌘ → «Metadatos…»)
//
// Ver, buscar, cambiar o quitar la información que llevan dentro las fotos, los PDF, el audio y el video.
// Siempre se guarda una copia ("-metadatos"); el original no se toca. En las fotos la imagen se copia tal cual,
// sin volver a comprimirla.

enum MetadataKind {
    case image, pdf, media

    static func of(_ file: FileInfo) -> MetadataKind? {
        if let format = ImageFormat.detect(file) { return format == .pdf ? .pdf : .image }
        if MediaFormat.kind(of: file).isMedia { return .media }
        return nil
    }
}

struct MetadataField: Identifiable, Hashable {
    /// "{Exif}|LensModel", "pdf|Title", "tags|artist".
    let id: String
    let group: String
    let key: String
    let label: String
    let value: String
    /// Solo se pueden cambiar los textos y números sueltos; lo demás se puede quitar pero no editar.
    let editable: Bool
}

struct MetadataGroup: Identifiable {
    let id: String
    let title: String
    var fields: [MetadataField]
}

/// Lo que el usuario cambió en la ventana.
struct MetadataEdits {
    var changes: [String: String] = [:]
    var removed: Set<String> = []
    var removeAll = false
    var isEmpty: Bool { changes.isEmpty && removed.isEmpty && !removeAll }
}

/// Los cambios viajan hasta el motor con un número (los parámetros de las herramientas solo admiten números).
final class MetadataEditStore: @unchecked Sendable {
    static let shared = MetadataEditStore()
    private var pending: [Int: MetadataEdits] = [:]
    private var next = 1
    private let lock = NSLock()

    func put(_ edits: MetadataEdits) -> Double {
        lock.lock(); defer { lock.unlock() }
        let token = next; next += 1
        pending[token] = edits
        return Double(token)
    }

    func take(_ token: Double?) -> MetadataEdits? {
        guard let token else { return nil }
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: Int(token))
    }
}

// MARK: Leer

enum MetadataReader {
    static func read(_ file: FileInfo) -> [MetadataGroup] {
        switch MetadataKind.of(file) {
        case .image: return image(file.url)
        case .pdf: return pdf(file.url)
        case .media: return media(file.url)
        case nil: return []
        }
    }

    /// Grupos de las fotos, con nombres claros. Los datos internos del fabricante (MakerApple…) no se muestran.
    static let imageGroups: [(key: String, title: String)] = [
        (kCGImagePropertyTIFFDictionary as String, "Cámara y archivo"),
        (kCGImagePropertyExifDictionary as String, "Exif"),
        (kCGImagePropertyExifAuxDictionary as String, "Exif (objetivo)"),
        (kCGImagePropertyGPSDictionary as String, "Ubicación (GPS)"),
        (kCGImagePropertyIPTCDictionary as String, "IPTC (autor y derechos)"),
    ]

    private static func image(_ url: URL) -> [MetadataGroup] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var groups: [MetadataGroup] = []
        // Datos generales (tamaño, color…): solo para ver.
        let general = props.compactMap { key, value -> MetadataField? in
            guard !(value is [String: Any]), let text = display(value) else { return nil }
            return MetadataField(id: "general|\(key)", group: "general", key: key, label: label(key), value: text, editable: false)
        }
        if !general.isEmpty { groups.append(MetadataGroup(id: "general", title: "Imagen", fields: general.sorted { $0.label < $1.label })) }
        for (groupKey, title) in imageGroups {
            guard let dict = props[groupKey] as? [String: Any] else { continue }
            let fields = dict.compactMap { key, value -> MetadataField? in
                guard let text = display(value) else { return nil }
                let editable = value is String || value is NSNumber
                return MetadataField(id: "\(groupKey)|\(key)", group: groupKey, key: key, label: label(key), value: text, editable: editable)
            }
            if !fields.isEmpty { groups.append(MetadataGroup(id: groupKey, title: title, fields: fields.sorted { $0.label < $1.label })) }
        }
        return groups
    }

    static let pdfKeys: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "Título"), (.authorAttribute, "Autor"), (.subjectAttribute, "Asunto"),
        (.keywordsAttribute, "Palabras clave"), (.creatorAttribute, "Creado con"), (.producerAttribute, "Productor"),
        (.creationDateAttribute, "Fecha de creación"), (.modificationDateAttribute, "Fecha de modificación"),
    ]

    private static func pdf(_ url: URL) -> [MetadataGroup] {
        guard let doc = PDFDocument(url: url) else { return [] }
        let attrs = doc.documentAttributes ?? [:]
        let fields = pdfKeys.compactMap { key, title -> MetadataField? in
            let raw = attrs[key]
            let isDate = raw is Date
            guard let text = raw.flatMap(display) ?? (isDate ? nil : "") else { return nil }
            return MetadataField(id: "pdf|\(key.rawValue)", group: "pdf", key: key.rawValue, label: title, value: text,
                                 editable: !isDate)
        }
        let info = [MetadataField(id: "info|pages", group: "info", key: "pages", label: "Páginas",
                                  value: "\(doc.pageCount)", editable: false)]
        return [MetadataGroup(id: "pdf", title: "Documento", fields: fields),
                MetadataGroup(id: "info", title: "Archivo", fields: info)]
    }

    private static func media(_ url: URL) -> [MetadataGroup] {
        guard let ffprobe = ExternalTool.find("ffprobe"),
              let text = try? ExternalTool.capture(ffprobe, arguments: [
                "-v", "error", "-show_entries", "format=duration,format_name:format_tags", "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let format = json["format"] as? [String: Any] else { return [] }
        let tags = (format["tags"] as? [String: Any]) ?? [:]
        // Los campos habituales aparecen aunque estén vacíos, para poder rellenarlos.
        var keys = Set(tags.keys.map { $0.lowercased() })
        keys.formUnion(["title", "artist", "album", "date", "genre", "comment"])
        let fields = keys.map { key -> MetadataField in
            let value = tags.first { $0.key.lowercased() == key }.flatMap { display($0.value) } ?? ""
            return MetadataField(id: "tags|\(key)", group: "tags", key: key, label: mediaLabel(key), value: value, editable: true)
        }.sorted { $0.label < $1.label }
        var info: [MetadataField] = []
        if let d = format["duration"] as? String, let seconds = Double(d) {
            info.append(MetadataField(id: "info|duration", group: "info", key: "duration", label: "Duración",
                                      value: String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)),
                                      editable: false))
        }
        return [MetadataGroup(id: "tags", title: "Etiquetas", fields: fields),
                MetadataGroup(id: "info", title: "Archivo", fields: info)].filter { !$0.fields.isEmpty }
    }

    private static func mediaLabel(_ key: String) -> String {
        let names = ["title": "Título", "artist": "Artista", "album": "Álbum", "album_artist": "Artista del álbum",
                     "date": "Fecha", "genre": "Género", "comment": "Comentario", "composer": "Compositor",
                     "track": "Pista", "encoder": "Codificado con", "creation_time": "Fecha de creación",
                     "copyright": "Derechos", "description": "Descripción"]
        return names[key] ?? label(key)
    }

    /// "LensModel" → "Lens Model"; "PixelXDimension" → "Pixel X Dimension".
    static func label(_ key: String) -> String {
        var out = ""
        let chars = Array(key.replacingOccurrences(of: "_", with: " "))
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase || (i + 1 < chars.count && chars[i + 1].isLowercase && chars[i - 1].isUppercase) {
                out.append(" ")
            }
            out.append(c)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func display(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let d as Date:
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.locale = Locale(identifier: "es")
            return f.string(from: d)
        case let a as [Any]:
            let parts = a.compactMap(display)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default: return nil
        }
    }
}

// MARK: Escribir (motor)

struct MetadataToolsConverter: Converter {
    let id = "metadata.tools"
    let mode = WheelMode.tools

    func options(for file: FileInfo) -> [WheelOption] {
        guard MetadataKind.of(file) != nil else { return [] }
        var option = WheelOption(id: "\(id).edit", providerID: id, title: "Metadatos…", symbol: "tag",
                                 accessibilityLabel: "Ver, cambiar o quitar los metadatos")
        option.editor = .metadata
        return [option]
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let kind = MetadataKind.of(file) else { throw ConversionError.unsupported }
        guard let edits = MetadataEditStore.shared.take(context.parameters["edits"]), !edits.isEmpty else {
            throw ConversionError.message("No has cambiado ningún metadato.")
        }
        let ext = file.url.pathExtension.isEmpty ? "dat" : file.url.pathExtension.lowercased()
        let temp = context.temporaryURL(ext: ext)
        defer { try? FileManager.default.removeItem(at: temp) }
        context.report(0.3)
        switch kind {
        case .image: try writeImage(file.url, edits: edits, to: temp)
        case .pdf: try writePDF(file.url, edits: edits, to: temp)
        case .media: try writeMedia(file.url, edits: edits, to: temp, context: context)
        }
        return [try context.finalize(temp: temp, for: file.url, ext: ext, tag: "metadatos")]
    }

    private func split(_ id: String) -> (group: String, key: String) {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    /// Copia la imagen tal cual (sin volver a comprimirla) con los metadatos cambiados.
    private func writeImage(_ url: URL, edits: MetadataEdits, to temp: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil)
        else { throw ConversionError.unreadable(url.lastPathComponent) }

        let metadata: CGMutableImageMetadata
        if edits.removeAll {
            metadata = CGImageMetadataCreateMutable()
        } else {
            metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
                ?? CGImageMetadataCreateMutable()
            for id in edits.removed {
                let (group, key) = split(id)
                if let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, group as CFString, key as CFString),
                   let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) {
                    CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
                }
            }
            for (id, text) in edits.changes where !edits.removed.contains(id) {
                let (group, key) = split(id)
                let value: CFTypeRef = Double(text).map { NSNumber(value: $0) } ?? (text as NSString)
                CGImageMetadataSetValueMatchingImageProperty(metadata, group as CFString, key as CFString, value)
            }
        }
        var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
        if edits.removeAll { options[kCGImageMetadataShouldExcludeGPS] = true }
        if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) { return }

        // Algunos formatos no permiten copiar sin recomprimir: se escribe de nuevo con las propiedades cambiadas.
        guard let dest2 = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { throw ConversionError.writeFailed(url.pathExtension) }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        for (groupKey, _) in MetadataReader.imageGroups {
            if edits.removeAll { props[groupKey] = kCFNull; continue }
            guard var dict = props[groupKey] as? [String: Any] else { continue }
            for id in edits.removed where split(id).group == groupKey { dict[split(id).key] = kCFNull }
            for (id, text) in edits.changes where split(id).group == groupKey { dict[split(id).key] = Double(text) ?? text as Any }
            props[groupKey] = dict
        }
        props[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        CGImageDestinationAddImageFromSource(dest2, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest2) else { throw ConversionError.writeFailed(url.pathExtension) }
    }

    private func writePDF(_ url: URL, edits: MetadataEdits, to temp: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw ConversionError.message("“\(url.lastPathComponent)” tiene contraseña.") }
        var attrs: [AnyHashable: Any] = edits.removeAll ? [:] : (doc.documentAttributes ?? [:])
        if !edits.removeAll {
            for id in edits.removed { attrs[PDFDocumentAttribute(rawValue: split(id).key)] = nil }
            for (id, text) in edits.changes where !edits.removed.contains(id) {
                let key = PDFDocumentAttribute(rawValue: split(id).key)
                if key == .keywordsAttribute {
                    attrs[key] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                } else {
                    attrs[key] = text.isEmpty ? nil : text
                }
            }
        }
        doc.documentAttributes = attrs
        guard doc.write(to: temp) else { throw ConversionError.writeFailed("PDF") }
    }

    private func writeMedia(_ url: URL, edits: MetadataEdits, to temp: URL, context: JobContext) throws {
        let ffmpeg = try ExternalTool.require("ffmpeg", engine: "FFmpeg")
        var args = ["-hide_banner", "-nostdin", "-y", "-i", url.path, "-map", "0", "-c", "copy",
                    "-map_metadata", edits.removeAll ? "-1" : "0"]
        if !edits.removeAll {
            for id in edits.removed { args += ["-metadata", "\(split(id).key)="] }
            for (id, text) in edits.changes where !edits.removed.contains(id) { args += ["-metadata", "\(split(id).key)=\(text)"] }
        }
        // MP4 y MOV: así guardan también las etiquetas que no son las de siempre.
        if ["mp4", "m4a", "mov", "m4v"].contains(url.pathExtension.lowercased()) { args += ["-movflags", "use_metadata_tags"] }
        try ExternalTool.run(ffmpeg, arguments: args + [temp.path], context: context) { _ in }
    }
}
