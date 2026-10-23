import AppKit

/// Convierte HTML en un PDF paginado usando el motor de texto de macOS (no necesita LaTeX).
enum HTMLToPDF {

    /// Envuelve el contenido en una página con el estilo de `DesignTokens.DocumentPDF`.
    static func page(title: String, body: String) -> String {
        let t = DesignTokens.DocumentPDF.self
        return """
        <html><head><meta charset="utf-8"><title>\(PDFText.escape(title))</title>
        <style>
        body { font-family: \(t.fontFamily), sans-serif; font-size: \(t.fontSizePt)pt; line-height: 1.45; color: #222; }
        h1, h2, h3, h4 { color: \(t.headingColor); font-weight: 600; }
        h1 { font-size: \(t.fontSizePt * 2)pt; } h2 { font-size: \(Int(Double(t.fontSizePt) * 1.6))pt; }
        h3 { font-size: \(Int(Double(t.fontSizePt) * 1.3))pt; }
        a { color: \(t.linkColor); }
        code, pre { font-family: Menlo, monospace; font-size: \(t.fontSizePt - 1)pt; }
        table { border-collapse: collapse; width: 100%; }
        td, th { border: 1px solid #ccc; padding: 4px 8px; font-size: \(t.fontSizePt)pt; text-align: left; }
        blockquote { color: #555; }
        img { max-width: 100%; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func render(html: String, to url: URL) throws {
        let work = {
            guard let data = html.data(using: .utf8),
                  let text = NSAttributedString(html: data,
                                                options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                                documentAttributes: nil)
            else { throw ConversionError.writeFailed("PDF") }

            let size = DesignTokens.DocumentPDF.pageSize
            let margin = DesignTokens.DocumentPDF.margin
            let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
            info.jobDisposition = .save
            info.paperSize = size
            info.topMargin = margin; info.bottomMargin = margin
            info.leftMargin = margin; info.rightMargin = margin
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false

            // Altura mínima: sizeToFit la ajusta al contenido (si no, sobra una página en blanco).
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width - margin * 2, height: 1))
            view.textStorage?.setAttributedString(text)
            view.isVerticallyResizable = true
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            view.sizeToFit()

            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            guard operation.run() else { throw ConversionError.writeFailed("PDF") }
        }
        // El motor de HTML de macOS solo funciona en el hilo principal.
        if Thread.isMainThread { try work() } else { try DispatchQueue.main.sync(execute: work) }
    }
}
