import Foundation

/// LibreOffice en modo invisible (sin ventanas): el que ya tenga el Mac o el que instala Fluxio
/// (Ajustes → Motores).
enum LibreOffice {
    private static var candidates: [String] {
        [Engines.sofficeInFluxio.path,   // primero el que instaló y comprobó Fluxio
         "/Applications/LibreOffice.app/Contents/MacOS/soffice",
         NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
    }

    static var isInstalled: Bool { candidates.contains { FileManager.default.isExecutableFile(atPath: $0) } }

    static func soffice() throws -> URL {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ConversionError.missingTool(name: "LibreOffice", install: "LibreOffice")
        }
        return URL(fileURLWithPath: path)
    }

    /// Perfil propio de Fluxio: así funciona aunque tengas LibreOffice abierto. Uno por proceso, para que la app y
    /// el comando `fluxio` de Terminal puedan usar LibreOffice a la vez.
    private static let profile = FileManager.default.temporaryDirectory
        .appendingPathComponent("fluxio-libreoffice-\(ProcessInfo.processInfo.processIdentifier)")
    /// LibreOffice no admite dos conversiones a la vez con el mismo perfil: se hacen de una en una.
    private static let lock = NSLock()

    /// Convierte `input` y devuelve el archivo creado (en una carpeta temporal que borra quien llama).
    /// `format` es lo que entiende LibreOffice: "pdf", "docx", "pptx", "csv:Text - txt - csv (StarCalc):44,34,76"…
    static func convert(_ input: URL, to format: String, outputExtension: String, inputFilter: String? = nil,
                        into folder: URL, context: JobContext) throws -> URL {
        let soffice = try soffice()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore"]
        if let inputFilter { args.append("--infilter=\(inputFilter)") }
        args += ["--convert-to", format, "--outdir", folder.path, input.path]

        lock.lock(); defer { lock.unlock() }
        try ExternalTool.run(soffice, arguments: args, context: context)
        let output = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(outputExtension)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.message("LibreOffice no pudo convertir “\(input.lastPathComponent)”.")
        }
        return output
    }
}

/// Presentaciones (PowerPoint, Keynote, ODP), documentos y hojas de cálculo que necesitan LibreOffice.
struct OfficeConverter: Converter {
    let id = "office.convert"
    let mode = WheelMode.convert

    private enum Kind { case presentation, document, spreadsheet, modernSheet, pdf }

    private static let presentations = ["pptx", "ppt", "pps", "ppsx", "odp", "key"]
    private static let documents = ["doc", "dot", "pages", "wpd", "wps"]   // DOCX, ODT, RTF los trata DocumentConverter
    private static let spreadsheets = ["xls", "xlt", "numbers"]
    private static let modernSheets = ["xlsx", "ods", "csv", "tsv"]         // ya convertibles entre sí; aquí se añade PDF

    private func kind(_ file: FileInfo) -> Kind? {
        let ext = file.url.pathExtension.lowercased()
        if Self.presentations.contains(ext) { return .presentation }
        if Self.documents.contains(ext) { return .document }
        if Self.spreadsheets.contains(ext) { return .spreadsheet }
        if Self.modernSheets.contains(ext) { return .modernSheet }
        if ext == "pdf" { return .pdf }
        return nil
    }

    func options(for file: FileInfo) -> [WheelOption] {
        let ext = file.url.pathExtension.lowercased()
        let targets: [(String, String, String)]
        switch kind(file) {
        case .presentation:
            targets = [("pdf", "PDF", "doc.richtext"), ("png", "PNG", "photo.on.rectangle"), ("jpg", "JPG", "photo"),
                       ("pptx", "PowerPoint", "rectangle.on.rectangle"), ("odp", "ODP", "rectangle.stack")]
                .filter { $0.0 != ext }
        case .document:
            targets = [("pdf", "PDF", "doc.richtext"), ("docx", "DOCX", "doc.text"), ("odt", "ODT", "doc"),
                       ("txt", "TXT", "text.alignleft")]
        case .spreadsheet:
            targets = [("xlsx", "XLSX", "tablecells"), ("ods", "ODS", "tablecells.badge.ellipsis"),
                       ("csv", "CSV", "list.bullet.rectangle"), ("pdf", "PDF", "doc.richtext")]
        case .modernSheet:
            targets = [("pdf", "PDF", "doc.richtext")]
        case .pdf:
            targets = [("pptx", "PowerPoint", "rectangle.on.rectangle")]
        case nil:
            return []
        }
        return targets.map {
            WheelOption(id: "\(id).\($0.0)", providerID: id, title: $0.1, symbol: $0.2,
                        accessibilityLabel: "Convertir a \($0.1)")
        }
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let target = action(of: option)
        guard let kind = kind(file) else { throw ConversionError.unsupported }
        let work = context.temporaryURL(ext: "office")
        defer { try? FileManager.default.removeItem(at: work) }
        context.report(0.05)

        // Presentación → imágenes: primero PDF, después una imagen por diapositiva.
        if kind == .presentation && (target == "png" || target == "jpg") {
            let pdf = try LibreOffice.convert(file.url, to: "pdf", outputExtension: "pdf", into: work, context: context)
            context.report(0.5)
            let slides = try ImageIOHelpers.renderPDFPages(pdf, context: context)
            let format: ImageFormat = target == "png" ? .png : .jpeg
            var outputs: [URL] = []
            for slide in slides {
                try context.checkCancelled()
                let temp = context.temporaryURL(ext: format.ext)
                try ImageIOHelpers.write(ImageIOHelpers.adjusted(slide.image, with: context.policy.image), as: format,
                                         metadata: [:], quality: context.policy.quality, to: temp, context: context)
                let tag = slides.count > 1 || (PDFDocumentPageCount.of(pdf) ?? 1) > 1 ? "diapositiva-\(slide.number)" : nil
                outputs.append(try context.finalize(temp: temp, for: file.url, ext: format.ext, tag: tag))
            }
            return outputs
        }

        let format: String
        var inputFilter: String?
        switch target {
        case "csv": format = "csv:Text - txt - csv (StarCalc):44,34,76"   // separado por comas, UTF-8
        case "txt": format = "txt:Text (encoded):UTF8"
        default: format = target
        }
        if kind == .pdf { inputFilter = "impress_pdf_import" }   // cada página del PDF se vuelve una diapositiva editable

        let result = try LibreOffice.convert(file.url, to: format, outputExtension: target, inputFilter: inputFilter,
                                             into: work, context: context)
        return [try context.finalize(temp: result, for: file.url, ext: target)]
    }
}
