import Foundation
import UniformTypeIdentifiers

/// Formatos de imagen.
enum ImageFormat: String, CaseIterable {
    case jpeg, png, webp, heic, tiff, avif, bmp, pdf, gif, ico, icns, jp2, tga, psd

    /// Los más usados: van en la rueda principal. El resto, dentro de "Más…".
    var isPrimary: Bool { [.jpeg, .png, .webp, .heic, .pdf].contains(self) }

    /// Extensión del archivo de salida.
    var ext: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .jp2: return "jp2"
        default: return rawValue
        }
    }

    var title: String {
        switch self {
        case .jpeg: return "JPG"
        case .webp: return "WebP"
        case .jp2: return "JPEG 2000"
        default: return rawValue.uppercased()
        }
    }

    var symbol: String {
        switch self {
        case .jpeg: return "photo"
        case .png: return "photo.on.rectangle"
        case .webp: return "globe"
        case .heic: return "iphone"
        case .tiff: return "printer"
        case .avif: return "sparkles"
        case .bmp: return "square.grid.3x3"
        case .pdf: return "doc.richtext"
        case .gif: return "photo.stack"
        case .ico: return "app"
        case .icns: return "app.badge"
        case .jp2: return "photo.artframe"
        case .tga: return "gamecontroller"
        case .psd: return "square.3.layers.3d"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        case .avif: return UTType("public.avif") ?? .image
        case .bmp: return .bmp
        case .pdf: return .pdf
        case .gif: return .gif
        case .ico: return .ico
        case .icns: return .icns
        case .jp2: return UTType("public.jpeg-2000") ?? .image
        case .tga: return UTType("com.truevision.tga-image") ?? .image
        case .psd: return UTType("com.adobe.photoshop-image") ?? .image
        }
    }

    /// Si el formato puede guardar transparencia.
    var supportsAlpha: Bool {
        switch self {
        case .jpeg, .bmp: return false
        default: return true
        }
    }

    /// Si usa compresión con pérdida (le aplica el ajuste de calidad).
    var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp, .jp2: return true
        default: return false
        }
    }

    /// Detecta el formato de un archivo (o `nil` si no es uno de estos).
    static func detect(_ file: FileInfo) -> ImageFormat? {
        guard let type = file.type else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        return allCases.first { $0 != .pdf && type.conforms(to: $0.utType) }
    }
}
