import Foundation
import UniformTypeIdentifiers

/// Las tres ruedas que puede mostrar Fluxio.
enum WheelMode: String, CaseIterable, Identifiable, Codable {
    case convert, tools, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "Convertir a"
        case .tools: return "Herramientas"
        case .actions: return "Acciones"
        }
    }

    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .actions: return "bolt"
        }
    }

    var accessibilityName: String {
        switch self {
        case .convert: return "Rueda de conversión"
        case .tools: return "Rueda de herramientas"
        case .actions: return "Rueda de acciones"
        }
    }
}

/// Una opción dentro de la rueda (un "gajo").
struct WheelOption: Identifiable, Hashable {
    /// Identificador único, por ejemplo "image.convert.png".
    let id: String
    /// Qué conversor o servicio la ejecuta.
    let providerID: String
    /// Texto corto que se ve en la rueda ("PNG", "Comprimir").
    let title: String
    /// Icono SF Symbol.
    let symbol: String
    /// Frase completa para VoiceOver ("Convertir a PNG").
    let accessibilityLabel: String
    /// Si antes de ejecutar hay que abrir una ventana para elegir algo (recorte, corte).
    var editor: EditorKind? = nil
    /// Opción menos habitual: si la rueda tiene muchas, va dentro de "Más…".
    var secondary = false
    /// La persona la puso «En Más…» (Personalizar rueda): va siempre dentro de «Más…», haya sitio o no.
    var inMore = false
    /// Para "Más…": las opciones de la segunda rueda.
    var children: [WheelOption]? = nil

    /// Gajo "Más…" que abre una segunda rueda.
    static func more(_ children: [WheelOption]) -> WheelOption {
        WheelOption(id: "more", providerID: "more", title: "Más…", symbol: "ellipsis.circle",
                    accessibilityLabel: "Más opciones (\(children.count))", children: children)
    }

    /// La misma opción, marcada como secundaria.
    var asSecondary: WheelOption {
        var copy = self
        copy.secondary = true
        return copy
    }
}

/// Ventanas de edición que algunas herramientas abren antes de ejecutarse.
enum EditorKind: String, Hashable {
    /// Elegir zona de recorte → parámetros "x", "y", "w", "h" (0…1, desde arriba a la izquierda).
    case crop
    /// Elegir inicio y fin → parámetros "start", "end" (segundos).
    case trim
    /// Elegir el orden de varios archivos (unir) → parámetro "ordered" = 1 y los archivos en ese orden.
    case order
    /// Editar foto → un parámetro por ajuste (ver `PhotoAdjustments.groups`).
    case photoEdit
    /// Metadatos → parámetro "edits": el número con el que `MetadataEditStore` guarda los cambios.
    case metadata
    /// Anotar, añadir fondo y ocultar zonas → parámetro "payload": el número con el que `ToolPayloadStore`
    /// guarda lo dibujado (flechas, zonas, fondo elegido…).
    case annotate, background, redact
    /// Collage con varias fotos → parámetro "payload" (`CollageRequest`: diseño y orden de las fotos).
    case collage
    /// Video: velocidad → "speed"; fotogramas → "count" y "t0"…; dividir → "count" y "c0"… (segundos).
    case speed, frames, split
    /// Audio: normalizar → "loudness", "range", "peak"; canales → "mono", "left", "right"; pitido → "count", "s0", "e0"…
    case normalize, channels, bleep
    /// Organizar páginas de un PDF → parámetro "payload" (`PDFOrganizePlan`: páginas, giros y mismo ancho).
    case organize

    /// Ventanas que trabajan con un archivo cada vez: con varios, se abren una tras otra ("1 de 3"), cada uno
    /// con lo suyo. «Unir» y «Collage» trabajan con todos a la vez.
    var isPerFile: Bool { self != .order && self != .collage }
}

/// Información básica de un archivo soltado en la ventana.
struct FileInfo: Hashable {
    let url: URL
    let type: UTType?

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        self.type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    func conforms(to other: UTType) -> Bool {
        type?.conforms(to: other) ?? false
    }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
