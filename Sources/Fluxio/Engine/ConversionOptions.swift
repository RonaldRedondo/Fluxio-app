import Foundation

// Ajustes que se aplican a cada conversión (se eligen en Ajustes de Fluxio).
// Todos tienen un valor por defecto que deja el resultado igual que antes.

/// Imágenes: tamaño, escala de grises, volteo y metadatos.
struct ImageOptions: Codable, Equatable, Sendable {
    enum Resize: String, CaseIterable, Codable, Sendable {
        case none, percent, longEdge, width

        var label: String {
            switch self {
            case .none: return "Tamaño original"
            case .percent: return "Porcentaje"
            case .longEdge: return "Lado más largo"
            case .width: return "Ancho fijo"
            }
        }
    }

    enum Flip: String, CaseIterable, Codable, Sendable {
        case none, horizontal, vertical

        var label: String {
            switch self {
            case .none: return "Sin voltear"
            case .horizontal: return "Horizontal (espejo)"
            case .vertical: return "Vertical (de cabeza)"
            }
        }
    }

    var resize: Resize = .none
    var percent = 50
    var longEdge = 1920
    var width = 1200
    var grayscale = false
    var flip: Flip = .none
    var keepMetadata = true
    /// Colores al convertir una imagen en vector SVG (2 = blanco y negro).
    var traceColors = 8

    init(resize: Resize = .none, percent: Int = 50, longEdge: Int = 1920, width: Int = 1200, grayscale: Bool = false,
         flip: Flip = .none, keepMetadata: Bool = true, traceColors: Int = 8) {
        self.resize = resize; self.percent = percent; self.longEdge = longEdge; self.width = width
        self.grayscale = grayscale; self.flip = flip; self.keepMetadata = keepMetadata; self.traceColors = traceColors
    }

    /// Lee ajustes guardados por versiones anteriores aunque les falten opciones nuevas.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageOptions()
        resize = try c.decodeIfPresent(Resize.self, forKey: .resize) ?? d.resize
        percent = try c.decodeIfPresent(Int.self, forKey: .percent) ?? d.percent
        longEdge = try c.decodeIfPresent(Int.self, forKey: .longEdge) ?? d.longEdge
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? d.width
        grayscale = try c.decodeIfPresent(Bool.self, forKey: .grayscale) ?? d.grayscale
        flip = try c.decodeIfPresent(Flip.self, forKey: .flip) ?? d.flip
        keepMetadata = try c.decodeIfPresent(Bool.self, forKey: .keepMetadata) ?? d.keepMetadata
        traceColors = try c.decodeIfPresent(Int.self, forKey: .traceColors) ?? d.traceColors
    }

    /// Escala a aplicar a una imagen de este tamaño (nunca agranda salvo con porcentaje > 100).
    func scale(width w: Int, height h: Int) -> CGFloat {
        switch resize {
        case .none: return 1
        case .percent: return CGFloat(max(1, percent)) / 100
        case .longEdge: return min(1, CGFloat(longEdge) / CGFloat(max(w, h, 1)))
        case .width: return min(1, CGFloat(width) / CGFloat(max(w, 1)))
        }
    }

    var changesPixels: Bool { resize != .none || grayscale || flip != .none }
}

/// Video y audio: resolución, códec, calidad y bitrate.
struct MediaOptions: Codable, Equatable, Sendable {
    enum Resolution: Int, CaseIterable, Codable, Sendable {
        case original = 0, p2160 = 2160, p1080 = 1080, p720 = 720, p480 = 480

        var label: String { self == .original ? "Original" : "\(rawValue)p" }
    }

    enum VideoCodec: String, CaseIterable, Codable, Sendable {
        case original, h264, hevc, av1

        var label: String {
            switch self {
            case .original: return "Igual que el original (más rápido)"
            case .h264: return "H.264 (compatible con todo)"
            case .hevc: return "HEVC / H.265 (pesa menos)"
            case .av1: return "AV1 (pesa mucho menos, más lento)"
            }
        }
    }

    enum Quality: String, CaseIterable, Codable, Sendable {
        case high, balanced, small

        var label: String {
            switch self {
            case .high: return "Alta"
            case .balanced: return "Equilibrada"
            case .small: return "Archivo pequeño"
            }
        }
    }

    var resolution: Resolution = .original
    var codec: VideoCodec = .original
    var quality: Quality = .balanced
    /// kbps de audio; 0 = automático.
    var audioBitrate = 0

    static let audioBitrates = [0, 96, 128, 192, 256, 320]
}

/// PDF: qué páginas usar y con qué resolución convertirlas en imagen.
struct PDFOptions: Codable, Equatable, Sendable {
    /// Ej: "1-3, 5, 8-". Vacío = todas.
    var pageRange = ""
    /// Puntos por pulgada al convertir páginas en imagen.
    var dpi = 144

    static let dpiChoices = [72, 144, 200, 300]

    /// Índices de página (desde 0) que entran en el rango (todas si está vacío).
    /// Lanza un error claro si el texto no se entiende.
    func pages(count: Int) throws -> [Int] {
        let text = pageRange.replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return Array(0..<count) }
        var result: [Int] = []
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            let first: Int?, last: Int?
            switch bounds.count {
            case 1: first = Int(bounds[0]); last = first
            case 2: first = bounds[0].isEmpty ? 1 : Int(bounds[0]); last = bounds[1].isEmpty ? count : Int(bounds[1])
            default: first = nil; last = nil
            }
            guard let a = first, let b = last, a >= 1, b >= a else {
                throw ConversionError.message("No entiendo el rango de páginas «\(pageRange)». Usa algo como 1-3, 5, 8-")
            }
            for page in a...min(b, count) where !result.contains(page - 1) { result.append(page - 1) }
        }
        guard !result.isEmpty else {
            throw ConversionError.message("El rango «\(pageRange)» no incluye ninguna página (el PDF tiene \(count)).")
        }
        return result
    }
}

/// Nombre de los archivos que crea Fluxio.
struct NamingOptions: Codable, Equatable, Sendable {
    /// Palabras que se reemplazan: {nombre}, {formato}, {fecha}, {hora}.
    var pattern = "{nombre}"
    /// Nombre de la subcarpeta cuando se guarda en "una subcarpeta junto al original".
    var subfolder = "Convertidos"

    static let tokens = ["{nombre}", "{formato}", "{fecha}", "{hora}"]

    /// Aplica el patrón. `name` es el nombre del original sin extensión.
    func expand(name: String, ext: String, date: Date = Date()) -> String {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH.mm"
        var result = pattern.isEmpty ? "{nombre}" : pattern
        result = result.replacingOccurrences(of: "{nombre}", with: name)
            .replacingOccurrences(of: "{formato}", with: ext.uppercased())
            .replacingOccurrences(of: "{fecha}", with: day.string(from: date))
            .replacingOccurrences(of: "{hora}", with: time.string(from: date))
        // Sin caracteres que macOS no permite en nombres de archivo.
        result = result.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? name : result
    }
}
