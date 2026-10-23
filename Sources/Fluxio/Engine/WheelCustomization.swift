import Foundation
import UniformTypeIdentifiers

// MARK: - Personalizar la rueda
//
// Para cada tipo de archivo (fotos, video…) y cada rueda (Convertir, Herramientas), la persona elige el orden de
// las opciones y si van a la vista, dentro de «Más…» u ocultas. Se guarda en los ajustes y se aplica al momento.

enum WheelCategory: String, CaseIterable, Identifiable {
    case photos, video, audio, pdf, documents, spreadsheets, presentations, actions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Fotos"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .documents: return "Documentos"
        case .spreadsheets: return "Hojas de cálculo"
        case .presentations: return "Presentaciones"
        case .actions: return "Acciones"
        }
    }

    var symbol: String {
        switch self {
        case .photos: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .documents: return "doc.text"
        case .spreadsheets: return "tablecells"
        case .presentations: return "rectangle.on.rectangle"
        case .actions: return "bolt"
        }
    }

    /// Ruedas que se pueden personalizar en esta categoría.
    var modes: [WheelMode] { self == .actions ? [.actions] : [.convert, .tools] }

    /// Archivos de ejemplo (solo por su extensión) para saber qué opciones existen en la categoría.
    var samples: [String] {
        switch self {
        case .photos: return ["jpg", "png", "heic"]
        case .video: return ["mp4", "mov"]
        case .audio: return ["mp3", "wav"]
        case .pdf: return ["pdf"]
        case .documents: return ["docx", "md", "txt"]
        case .spreadsheets: return ["xlsx", "csv"]
        case .presentations: return ["pptx", "key"]
        case .actions: return ["jpg"]
        }
    }

    /// La categoría de un archivo, si tiene una.
    static func of(_ file: FileInfo) -> WheelCategory? {
        if let format = ImageFormat.detect(file) { return format == .pdf ? .pdf : .photos }
        let kind = MediaFormat.kind(of: file)
        if kind.isVideo { return .video }
        if kind.isMedia { return .audio }
        let ext = file.url.pathExtension.lowercased()
        if ["docx", "doc", "odt", "rtf", "md", "markdown", "txt", "html", "htm", "epub", "pages", "tex"].contains(ext) { return .documents }
        if ["xlsx", "xls", "csv", "tsv", "ods", "numbers"].contains(ext) { return .spreadsheets }
        if ["pptx", "ppt", "key", "odp"].contains(ext) { return .presentations }
        return nil
    }

    /// La categoría común de varios archivos (si son de tipos distintos, ninguna).
    static func of(_ files: [FileInfo]) -> WheelCategory? {
        let all = Set(files.compactMap(of))
        return all.count == 1 && files.allSatisfy({ of($0) != nil }) ? all.first : nil
    }
}

struct WheelLayout: Codable, Equatable {
    enum Placement: String, Codable, CaseIterable {
        case visible, more, hidden
    }
    /// Orden de las opciones (identificadores).
    var order: [String] = []
    var placement: [String: Placement] = [:]
}

enum WheelCustomizer {
    static func key(_ category: WheelCategory, _ mode: WheelMode) -> String { "\(category.rawValue).\(mode)" }

    /// Todas las opciones que existen en una categoría y rueda (sin agrupar en «Más…»).
    @MainActor
    static func defaultOptions(_ category: WheelCategory, _ mode: WheelMode) -> [WheelOption] {
        var seen = Set<String>()
        let samples = category.samples.map { FileInfo(url: URL(fileURLWithPath: "/tmp/muestra.\($0)")) }
        let options: [WheelOption]
        if mode == .actions {
            options = FileActions.options(for: [samples[0]])
        } else {
            let engine = ConversionEngine.shared
            options = samples.flatMap { sample in
                engine.converters.filter { $0.mode == mode }.flatMap { $0.options(for: [sample]) }
            }
        }
        return options.filter { $0.children == nil && seen.insert($0.id).inserted }
    }

    /// Aplica lo que eligió la persona (orden, a la vista, en «Más…», oculta). Las opciones que no conoce (por
    /// ejemplo «Collage» o «Unir», que solo salen con varios archivos) van primero, como estaban.
    @MainActor
    static func apply(_ options: [WheelOption], files: [FileInfo], mode: WheelMode) -> [WheelOption] {
        let category: WheelCategory? = mode == .actions ? .actions : WheelCategory.of(files)
        guard let category, let layout = AppSettings.shared.wheelLayouts[key(category, mode)] else { return options }
        let rank = Dictionary(layout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let unknown = options.filter { rank[$0.id] == nil }
        let known = options.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return (unknown + known).compactMap { option in
            var o = option
            switch layout.placement[option.id] {
            case .hidden: return nil
            case .more: o.secondary = true; o.inMore = true
            case .visible: o.secondary = false; o.inMore = false
            case nil: break
            }
            return o
        }
    }
}
