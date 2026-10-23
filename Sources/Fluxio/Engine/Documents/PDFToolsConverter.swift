import AppKit
import PDFKit
import Quartz
import ImageIO

/// Herramientas de PDF (rueda ⌘): organizar páginas, comprimir, dividir en páginas y unir varios PDF o imágenes en uno.
struct PDFToolsConverter: Converter {
    let id = "pdf.tools"
    let mode = WheelMode.tools

    private enum Tool: String {
        case merge, split, compress, organize
    }

    func options(for file: FileInfo) -> [WheelOption] {
        guard ImageFormat.detect(file) == .pdf else { return [] }
        var organize = option(.organize, "Organizar", "square.grid.2x2", "Organizar las páginas del PDF")
        organize.editor = .organize   // ordenar, girar, duplicar o borrar páginas
        return [
            organize,
            option(.compress, "Comprimir", "arrow.down.right.and.arrow.up.left", "Comprimir el PDF"),
            option(.split, "Dividir", "square.split.2x1", "Dividir en un PDF por página"),
        ]
    }

    /// Con varios archivos (PDF o imágenes) aparece "Unir en PDF".
    func options(for files: [FileInfo]) -> [WheelOption] {
        var result: [WheelOption] = []
        let allJoinable = files.allSatisfy { ImageFormat.detect($0) != nil || $0.conforms(to: .image) }
        if files.count > 1 && allJoinable {
            var merge = option(.merge, "Unir en PDF", "doc.on.doc", "Unir todos en un solo PDF")
            merge.editor = .order   // primero se elige el orden
            result.append(merge)
        }
        return result + commonOptions(for: files)
    }

    private func option(_ tool: Tool, _ title: String, _ symbol: String, _ label: String) -> WheelOption {
        WheelOption(id: "\(id).\(tool.rawValue)", providerID: id, title: title, symbol: symbol, accessibilityLabel: label)
    }

    // MARK: Unir

    func runBatch(_ option: WheelOption, on files: [FileInfo], context: JobContext) throws -> [URL]? {
        guard Tool(rawValue: action(of: option)) == .merge else { return nil }
        // El orden elegido en la ventana; si no hubo ventana (Terminal, carpetas vigiladas), por nombre como en Finder.
        let sorted = context.parameters["ordered"] == 1 ? files
            : files.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        let merged = PDFDocument()
        for (i, file) in sorted.enumerated() {
            try context.checkCancelled()
            if ImageFormat.detect(file) == .pdf {
                guard let doc = PDFDocument(url: file.url) else { throw ConversionError.unreadable(file.url.lastPathComponent) }
                if doc.isLocked { throw ConversionError.message("“\(file.url.lastPathComponent)” tiene contraseña.") }
                for p in 0..<doc.pageCount {
                    if let page = doc.page(at: p)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            } else {
                guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                      let image = ImageIOHelpers.orientedImage(from: source),
                      let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                else { throw ConversionError.unreadable(file.url.lastPathComponent) }
                merged.insert(page, at: merged.pageCount)
            }
            context.report(Double(i + 1) / Double(sorted.count) * 0.9)
        }
        let temp = context.temporaryURL(ext: "pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard merged.write(to: temp) else { throw ConversionError.writeFailed("PDF") }
        let base = sorted[0].url.deletingPathExtension().lastPathComponent
        return [try context.finalize(temp: temp, for: sorted[0].url, ext: "pdf", tag: "unido", baseName: base)]
    }

    // MARK: Organizar, dividir y comprimir

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let tool = Tool(rawValue: action(of: option)) else { throw ConversionError.unsupported }
        guard let doc = PDFDocument(url: file.url) else { throw ConversionError.unreadable(file.url.lastPathComponent) }
        if doc.isLocked { throw ConversionError.message("“\(file.url.lastPathComponent)” tiene contraseña.") }

        switch tool {
        case .split:
            guard doc.pageCount > 1 else { throw ConversionError.message("Este PDF solo tiene una página.") }
            // Todas las páginas dentro de una carpeta, para no llenar la carpeta original.
            let folder = context.temporaryURL(ext: "paginas")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let stem = file.url.deletingPathExtension().lastPathComponent
            let digits = String(doc.pageCount).count
            let wanted = try context.policy.pdf.pages(count: doc.pageCount)
            for (n, i) in wanted.enumerated() {
                try context.checkCancelled()
                let single = PDFDocument()
                if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
                let number = String(format: "%0\(digits)d", i + 1)
                single.write(to: folder.appendingPathComponent("\(stem) - página \(number).pdf"))
                context.report(Double(n + 1) / Double(wanted.count))
            }
            return [try context.finalize(temp: folder, for: file.url, ext: "", tag: "paginas")]

        case .compress:
            let temp = context.temporaryURL(ext: "pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            // El mismo filtro que usa Vista Previa en "Exportar → Reducir tamaño".
            let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
            var ok = false
            if let filter = QuartzFilter(url: filterURL) {
                ok = doc.write(to: temp, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
            }
            if !ok, #available(macOS 13.4, *) {
                ok = doc.write(to: temp, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            }
            guard ok else { throw ConversionError.writeFailed("PDF") }
            if let before = file.url.fileSize, let after = temp.fileSize, after >= before {
                throw ConversionError.message("“\(file.url.lastPathComponent)” ya está optimizado: no se pudo reducir más.")
            }
            return [try context.finalize(temp: temp, for: file.url, ext: "pdf", tag: "comprimido")]

        case .organize:
            guard let plan = ToolPayloadStore.shared.take(context.parameters["payload"], as: PDFOrganizePlan.self) else {
                throw ConversionError.message("Organizar páginas necesita su ventana: suelta el PDF en la rueda.")
            }
            let temp = context.temporaryURL(ext: "pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            try PDFOrganizer.write(plan, from: doc, to: temp)
            return [try context.finalize(temp: temp, for: file.url, ext: "pdf", tag: "organizado")]

        case .merge:
            throw ConversionError.unsupported
        }
    }
}
