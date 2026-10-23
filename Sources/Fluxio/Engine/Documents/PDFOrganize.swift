import AppKit
import PDFKit

// MARK: - Organizar páginas de un PDF
//
// La ventana «Organizar páginas» decide qué páginas salen, en qué orden y con qué giro; aquí se escribe el PDF.

/// Lo elegido en la ventana. Viaja con `ToolPayloadStore` (parámetro "payload").
struct PDFOrganizePlan {
    struct Page {
        /// Página del PDF original (desde 0). Una página duplicada aparece dos veces.
        var source: Int
        /// Giro extra en grados, en el sentido del reloj (0, 90, 180 o 270).
        var rotation: Int
    }
    var pages: [Page]
    /// Todas las páginas con el ancho de la más estrecha (se escalan sin deformarse).
    var sameWidth = false
}

enum PDFOrganizer {
    static func write(_ plan: PDFOrganizePlan, from doc: PDFDocument, to url: URL) throws {
        guard !plan.pages.isEmpty else { throw ConversionError.message("No queda ninguna página.") }
        let pages = try plan.pages.map { entry -> (PDFPage, Int) in
            guard let page = doc.page(at: entry.source) else { throw ConversionError.unsupported }
            return (page, ((page.rotation + entry.rotation) % 360 + 360) % 360)
        }
        if plan.sameWidth {
            try writeScaled(pages, to: url)
        } else {
            // Sin escalar: se copian las páginas tal cual (conservan texto seleccionable y enlaces).
            let out = PDFDocument()
            for (page, rotation) in pages {
                guard let copy = page.copy() as? PDFPage else { continue }
                copy.rotation = rotation
                out.insert(copy, at: out.pageCount)
            }
            out.documentAttributes = doc.documentAttributes
            guard out.write(to: url) else { throw ConversionError.writeFailed("PDF") }
        }
    }

    /// Tamaño que se ve de la página (con su giro).
    static func visibleSize(_ page: PDFPage, rotation: Int) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// Redibuja cada página escalada al ancho de la más estrecha. El contenido sigue siendo vectorial.
    private static func writeScaled(_ pages: [(PDFPage, Int)], to url: URL) throws {
        let narrowest = pages.map { visibleSize($0.0, rotation: $0.1).width }.min() ?? 0
        guard narrowest > 0, let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.writeFailed("PDF")
        }
        for (page, rotation) in pages {
            guard let cgPage = page.pageRef else { continue }
            let size = visibleSize(page, rotation: rotation)
            let scale = narrowest / size.width
            var media = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            context.beginPage(mediaBox: &media)
            context.scaleBy(x: scale, y: scale)
            let target = CGRect(origin: .zero, size: size)
            // El giro de la propia página ya lo aplica `getDrawingTransform`; se le suma el elegido.
            let extra = Int32((rotation - page.rotation + 360) % 360)
            context.concatenate(cgPage.getDrawingTransform(.cropBox, rect: target, rotate: extra, preserveAspectRatio: true))
            context.clip(to: cgPage.getBoxRect(.cropBox))
            context.drawPDFPage(cgPage)
            context.endPage()
        }
        context.closePDF()
    }
}
