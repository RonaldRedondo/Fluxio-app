import Foundation
import PDFKit

/// Formatos de documento.
enum DocumentFormat: String, CaseIterable {
    case docx, md, txt, html, epub, pdf, odt, rtf
    // Formatos de texto técnico (pandoc): LaTeX, reStructuredText, Org, MediaWiki, AsciiDoc, Typst, Jupyter, Textile.
    case tex, rst, org, wiki, adoc, typ, ipynb, textile

    /// Destinos principales (los demás van en "Más…").
    static let primaryTargets: [DocumentFormat] = [.docx, .md, .txt, .html, .epub, .pdf]
    static let secondaryTargets: [DocumentFormat] = [.odt, .rtf, .tex, .rst, .org, .wiki, .adoc, .typ, .ipynb, .textile]

    var title: String {
        switch self {
        case .md: return "Markdown"
        case .tex: return "LaTeX"
        case .rst: return "reST"
        case .org: return "Org"
        case .wiki: return "MediaWiki"
        case .adoc: return "AsciiDoc"
        case .typ: return "Typst"
        case .ipynb: return "Jupyter"
        case .textile: return "Textile"
        default: return rawValue.uppercased()
        }
    }

    var ext: String { rawValue }

    var symbol: String {
        switch self {
        case .docx: return "doc.text"
        case .md: return "number"
        case .txt: return "text.alignleft"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .epub: return "book"
        case .pdf: return "doc.richtext"
        case .odt, .rtf: return "doc"
        case .tex: return "function"
        case .ipynb: return "chart.bar.doc.horizontal"
        case .wiki: return "globe"
        default: return "text.badge.plus"
        }
    }

    /// Nombre del lector y del escritor de pandoc (PDF se hace aparte, con las herramientas de macOS o LibreOffice).
    var pandocReader: String {
        switch self {
        case .md, .txt: return "markdown"
        case .tex: return "latex"
        case .wiki: return "mediawiki"
        case .adoc: return "asciidoc"
        case .typ: return "typst"
        default: return rawValue
        }
    }

    var pandocWriter: String {
        switch self {
        case .md: return "gfm"
        case .txt: return "plain"
        default: return pandocReader
        }
    }

    static func detect(_ file: FileInfo) -> DocumentFormat? {
        switch file.url.pathExtension.lowercased() {
        case "docx": return .docx
        case "md", "markdown": return .md
        case "txt", "text": return .txt
        case "html", "htm": return .html
        case "epub": return .epub
        case "pdf": return .pdf
        case "odt": return .odt
        case "rtf": return .rtf
        case "tex", "latex": return .tex
        case "rst": return .rst
        case "org": return .org
        case "wiki", "mediawiki": return .wiki
        case "adoc", "asciidoc": return .adoc
        case "typ": return .typ
        case "ipynb": return .ipynb
        case "textile": return .textile
        default: return nil
        }
    }
}

/// Convierte documentos con pandoc. PDF de salida: pandoc → HTML → PDF con macOS (sin LaTeX).
/// PDF de entrada: se extrae el texto con PDFKit (sin el diseño original).
struct DocumentConverter: Converter {
    let id = "document.convert"
    let mode = WheelMode.convert

    func options(for file: FileInfo) -> [WheelOption] {
        guard let source = DocumentFormat.detect(file) else { return [] }
        let targets: [DocumentFormat] = source == .pdf
            ? [.txt, .docx, .md, .html]
            : (DocumentFormat.primaryTargets + DocumentFormat.secondaryTargets).filter { $0 != source }
        return targets.map { format in
            WheelOption(id: "\(id).\(format.rawValue)", providerID: id, title: format.title, symbol: format.symbol,
                        accessibilityLabel: "Convertir a \(format.title)",
                        secondary: DocumentFormat.secondaryTargets.contains(format))
        }
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let target = DocumentFormat(rawValue: String(option.id.dropFirst(id.count + 1))),
              let source = DocumentFormat.detect(file) else { throw ConversionError.unsupported }
        let temp = context.temporaryURL(ext: target.ext)
        defer { try? FileManager.default.removeItem(at: temp) }

        // PDF → texto: no hace falta pandoc.
        if source == .pdf && target == .txt {
            try PDFText.plainText(of: file.url, options: context.policy.pdf).write(to: temp, atomically: true, encoding: .utf8)
            return [try context.finalize(temp: temp, for: file.url, ext: target.ext)]
        }

        // Word, ODT y RTF → PDF: con LibreOffice el PDF respeta el diseño original (tablas, imágenes, márgenes).
        if target == .pdf, [.docx, .odt, .rtf].contains(source), LibreOffice.isInstalled {
            let work = context.temporaryURL(ext: "office")
            defer { try? FileManager.default.removeItem(at: work) }
            let pdf = try LibreOffice.convert(file.url, to: "pdf", outputExtension: "pdf", into: work, context: context)
            return [try context.finalize(temp: pdf, for: file.url, ext: "pdf")]
        }

        let pandoc = try ExternalTool.require("pandoc", engine: "Pandoc")
        var input = file.url
        var reader = source.pandocReader
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        if source == .pdf {
            // Texto del PDF convertido en HTML sencillo, que pandoc entiende.
            let html = context.temporaryURL(ext: "html")
            try PDFText.simpleHTML(of: file.url, options: context.policy.pdf).write(to: html, atomically: true, encoding: .utf8)
            input = html; reader = "html"; cleanup = html
        }
        context.report(0.2)
        try context.checkCancelled()

        let title = file.url.deletingPathExtension().lastPathComponent
        let resourcePath = file.url.deletingLastPathComponent().path

        if target == .pdf {
            let fragment = try ExternalTool.capture(pandoc, arguments: [
                "-f", reader, "-t", "html", "--resource-path", resourcePath, "--embed-resources", input.path])
            guard !fragment.isEmpty else { throw ConversionError.unreadable(file.url.lastPathComponent) }
            context.report(0.6)
            try HTMLToPDF.render(html: HTMLToPDF.page(title: title, body: fragment), to: temp)
        } else {
            var args = ["-f", reader, "-t", target.pandocWriter, "--resource-path", resourcePath, "-o", temp.path]
            switch target {
            case .html: args += ["--standalone", "--embed-resources", "--metadata", "pagetitle=\(title)"]
            case .epub: args += ["--metadata", "title=\(title)"]
            case .txt: args += ["--wrap=none"]
            case .tex, .rtf: args += ["--standalone"]   // documento completo, que se abre tal cual
            default: break
            }
            try ExternalTool.run(pandoc, arguments: args + [input.path], context: context)
        }
        return [try context.finalize(temp: temp, for: file.url, ext: target.ext)]
    }
}

/// Saca el texto de un PDF.
enum PDFText {
    static func plainText(of url: URL, options: PDFOptions = PDFOptions()) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let pages = try options.pages(count: doc.pageCount).compactMap { doc.page(at: $0)?.string }
        let text = pages.joined(separator: "\n\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConversionError.message("Este PDF no tiene texto seleccionable (puede ser una imagen escaneada).")
        }
        return text
    }

    /// Une las líneas en párrafos (un salto de línea del PDF no suele ser un párrafo nuevo).
    static func simpleHTML(of url: URL, options: PDFOptions = PDFOptions()) throws -> String {
        let text = try plainText(of: url, options: options)
        var paragraphs: [String] = []
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = "" }
                continue
            }
            current += current.isEmpty ? line : " " + line
            if let last = line.last, ".!?:".contains(last) {
                paragraphs.append(current); current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        let body = paragraphs.map { "<p>\(escape($0))</p>" }.joined(separator: "\n")
        return "<html><body>\n\(body)\n</body></html>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
