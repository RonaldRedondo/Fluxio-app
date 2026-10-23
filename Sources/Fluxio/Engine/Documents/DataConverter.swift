import Foundation
import ImageIO
import PDFKit

/// JSON ↔ Plist (listas de propiedades de macOS). Las tablas JSON ↔ CSV/XLSX las hace SpreadsheetConverter.
struct DataConverter: Converter {
    let id = "data.convert"
    let mode = WheelMode.convert

    func options(for file: FileInfo) -> [WheelOption] {
        switch file.url.pathExtension.lowercased() {
        case "json":
            return [WheelOption(id: "\(id).plist", providerID: id, title: "Plist", symbol: "list.bullet.indent",
                                accessibilityLabel: "Convertir a lista de propiedades (plist)")]
        case "plist":
            return [WheelOption(id: "\(id).json", providerID: id, title: "JSON", symbol: "curlybraces",
                                accessibilityLabel: "Convertir a JSON")]
        default:
            return []
        }
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let target = action(of: option)
        guard let data = try? Data(contentsOf: file.url) else { throw ConversionError.unreadable(file.url.lastPathComponent) }
        let output: Data
        if target == "plist" {
            guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                throw ConversionError.unreadable(file.url.lastPathComponent)
            }
            output = try PropertyListSerialization.data(fromPropertyList: plistSafe(json), format: .xml, options: 0)
        } else {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                throw ConversionError.unreadable(file.url.lastPathComponent)
            }
            output = try JSONSerialization.data(withJSONObject: jsonSafe(plist), options: [.prettyPrinted, .sortedKeys])
        }
        let temp = context.temporaryURL(ext: target)
        defer { try? FileManager.default.removeItem(at: temp) }
        try output.write(to: temp)
        return [try context.finalize(temp: temp, for: file.url, ext: target)]
    }

    /// Los plist no admiten "null": se cambia por texto vacío.
    private func plistSafe(_ value: Any) -> Any {
        switch value {
        case is NSNull: return ""
        case let array as [Any]: return array.map(plistSafe)
        case let dict as [String: Any]: return dict.mapValues(plistSafe)
        default: return value
        }
    }

    /// JSON no admite fechas ni datos binarios: fechas en formato ISO y datos en base64.
    private func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let data as Data: return data.base64EncodedString()
        case let array as [Any]: return array.map(jsonSafe)
        case let dict as [String: Any]: return dict.mapValues(jsonSafe)
        default: return value
        }
    }
}

/// Cómics digitales: CBZ (un ZIP de imágenes) ↔ PDF.
struct ComicConverter: Converter {
    let id = "comic.convert"
    let mode = WheelMode.convert

    func options(for file: FileInfo) -> [WheelOption] {
        switch file.url.pathExtension.lowercased() {
        case "cbz":
            return [WheelOption(id: "\(id).pdf", providerID: id, title: "PDF", symbol: "doc.richtext",
                                accessibilityLabel: "Convertir el cómic a PDF")]
        case "pdf":
            return [WheelOption(id: "\(id).cbz", providerID: id, title: "CBZ", symbol: "books.vertical",
                                accessibilityLabel: "Convertir a cómic CBZ", secondary: true)]
        default:
            return []
        }
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let target = action(of: option)
        let fm = FileManager.default
        let work = context.temporaryURL(ext: "comic")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        if target == "cbz" {
            // Cada página, una imagen JPG numerada (001.jpg, 002.jpg…), dentro de un ZIP.
            let pages = try ImageIOHelpers.renderPDFPages(file.url, context: context)
            let digits = max(3, String(pages.count).count)
            var names: [String] = []
            for page in pages {
                try context.checkCancelled()
                let name = String(format: "%0\(digits)d.jpg", page.number)
                try ImageIOHelpers.write(ImageIOHelpers.adjusted(page.image, with: context.policy.image), as: .jpeg,
                                         metadata: [:], quality: max(context.policy.quality, 0.85),
                                         to: work.appendingPathComponent(name), context: context)
                names.append(name)
            }
            let temp = context.temporaryURL(ext: "cbz")
            defer { try? fm.removeItem(at: temp) }
            try ExternalTool.run(ExternalTool.system.zip, arguments: ["-q", "-0", temp.path] + names, context: context,
                                 currentDirectory: work)
            return [try context.finalize(temp: temp, for: file.url, ext: "cbz")]
        }

        // CBZ → PDF: las imágenes del ZIP, en orden de nombre, una por página.
        try ExternalTool.run(ExternalTool.system.ditto, arguments: ["-x", "-k", file.url.path, work.path], context: context)
        let imageExts = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "heic", "avif"]
        let found = (fm.enumerator(at: work, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { imageExts.contains($0.pathExtension.lowercased()) && !$0.path.contains("__MACOSX") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !found.isEmpty else { throw ConversionError.message("Este CBZ no contiene imágenes.") }
        var images: [CGImage] = []
        for (i, url) in found.enumerated() {
            try context.checkCancelled()
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = ImageIOHelpers.orientedImage(from: source) {
                images.append(image)
            }
            context.report(Double(i + 1) / Double(found.count) * 0.8)
        }
        let temp = context.temporaryURL(ext: "pdf")
        defer { try? fm.removeItem(at: temp) }
        try ImageIOHelpers.writePDF(images, to: temp)
        return [try context.finalize(temp: temp, for: file.url, ext: "pdf")]
    }
}
