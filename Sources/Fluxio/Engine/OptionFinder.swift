import Foundation

/// Buscar una opción por el nombre del formato ("png", "mp3"…), sin pasar por la rueda.
/// Lo usan las carpetas vigiladas y el comando `fluxio` de Terminal.
extension ConversionEngine {
    /// Todas las opciones de un archivo (también las de "Más…"), sin las que abren una ventana de edición.
    func allOptions(for file: FileInfo) -> [WheelOption] {
        func flatten(_ options: [WheelOption]) -> [WheelOption] {
            options.flatMap { option in option.children.map(flatten) ?? [option] }
        }
        var seen = Set<String>()
        return flatten(converters.flatMap { $0.options(for: file) })
            .filter { $0.editor == nil && seen.insert($0.id).inserted }
    }

    /// Opciones de un archivo agrupadas por rueda ("Convertir a", "Herramientas"), para menús.
    func optionGroups(for file: FileInfo) -> [(title: String, options: [WheelOption])] {
        func flatten(_ options: [WheelOption]) -> [WheelOption] {
            options.flatMap { option in option.children.map(flatten) ?? [option] }
        }
        return [WheelMode.convert, .tools].compactMap { mode in
            var seen = Set<String>()
            let options = flatten(converters.filter { $0.mode == mode }.flatMap { $0.options(for: file) })
                .filter { $0.editor == nil && seen.insert($0.id).inserted }
            return options.isEmpty ? nil : (mode.title, options)
        }
    }

    /// La opción que convierte `file` a `target` (ej: "jpg"), o `nil` si ese archivo no se puede convertir a eso.
    func option(for file: FileInfo, target: String) -> WheelOption? {
        let wanted = Self.normalize(target)
        let all = allOptions(for: file)
        return all.first { Self.key(of: $0) == wanted } ?? all.first { Self.titleKey(of: $0) == wanted }
    }

    /// Nombre corto de una opción: "image.convert.png" → "png".
    nonisolated static func key(of option: WheelOption) -> String {
        normalize(String(option.id.dropFirst(option.providerID.count + 1)))
    }

    /// Primera palabra del título: "MP3 audio" → "mp3". Si lo que sigue es un número, va junto:
    /// "JPEG 2000" → "jpeg2000" (así "jpg" no elige JPEG 2000 por error).
    nonisolated static func titleKey(of option: WheelOption) -> String {
        let words = option.title.split(separator: " ").map(String.init)
        guard let first = words.first else { return normalize(option.title) }
        if words.count > 1, words[1].allSatisfy(\.isNumber) { return normalize(first + words[1]) }
        return normalize(first)
    }

    nonisolated static func normalize(_ text: String) -> String {
        if text.lowercased() == "jpeg2000" { return "jp2" }
        var value = text.lowercased().trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(".") { value.removeFirst() }
        switch value {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        default: return value
        }
    }
}
