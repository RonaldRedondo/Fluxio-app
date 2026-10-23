import Foundation
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import Vision
import CoreImage

/// Convierte entre JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP y PDF.
struct ImageConverter: Converter {
    /// Como mucho tantas capas al pasar un GIF animado a PSD (más haría archivos enormes).
    static let maxPSDLayers = 100

    let id = "image.convert"
    let mode = WheelMode.convert

    func options(for file: FileInfo) -> [WheelOption] {
        let source = ImageFormat.detect(file)
        if VectorConverter.isSVG(file) { return [] }   // los SVG los convierte VectorConverter
        // Cualquier imagen que macOS sepa leer (incluye GIF, RAW…) o un PDF.
        guard source != nil || file.conforms(to: .image) else { return [] }
        // Para PDF solo ofrecemos las imágenes más útiles; el resto de su rueda son formatos de documento.
        let targets: [ImageFormat] = source == .pdf ? [.jpeg, .png, .tiff] : ImageFormat.allCases.filter { $0 != source }
        return targets
            .map { format in
                WheelOption(id: "\(id).\(format.rawValue)", providerID: id, title: format.title,
                            symbol: format.symbol, accessibilityLabel: "Convertir a \(format.title)",
                            secondary: !format.isPrimary)
            }
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let target = ImageFormat(rawValue: String(option.id.dropFirst(id.count + 1))) else {
            throw ConversionError.unsupported
        }
        let quality = context.policy.quality

        // PDF → imágenes (una por página)
        if ImageFormat.detect(file) == .pdf {
            let pages = try ImageIOHelpers.renderPDFPages(file.url, context: context)
            let multiPage = (PDFDocumentPageCount.of(file.url) ?? pages.count) > 1
            var outputs: [URL] = []
            for (i, page) in pages.enumerated() {
                try context.checkCancelled()
                let temp = context.temporaryURL(ext: target.ext)
                try ImageIOHelpers.write(ImageIOHelpers.adjusted(page.image, with: context.policy.image), as: target,
                                         metadata: [:], quality: quality, to: temp, context: context)
                let tag = multiPage ? "pagina-\(page.number)" : nil
                outputs.append(try context.finalize(temp: temp, for: file.url, ext: target.ext, tag: tag))
                context.report(0.5 + Double(i + 1) / Double(pages.count) * 0.5)
            }
            return outputs
        }

        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadable(file.url.lastPathComponent)
        }

        // Imagen → PDF (los TIFF de varias páginas se convierten en un PDF de varias páginas)
        if target == .pdf {
            let count = file.conforms(to: .tiff) ? CGImageSourceGetCount(source) : 1
            var images: [CGImage] = []
            for i in 0..<count {
                try context.checkCancelled()
                if let image = ImageIOHelpers.orientedImage(from: source, index: i) {
                    images.append(ImageIOHelpers.adjusted(image, with: context.policy.image))
                }
                context.report(Double(i + 1) / Double(count) * 0.8)
            }
            guard !images.isEmpty else { throw ConversionError.unreadable(file.url.lastPathComponent) }
            let temp = context.temporaryURL(ext: "pdf")
            try ImageIOHelpers.writePDF(images, to: temp)
            return [try context.finalize(temp: temp, for: file.url, ext: "pdf")]
        }

        // Imagen → PSD con capas editables: los objetos de la foto separados en capas (o una capa con el
        // nombre del archivo si no hay objetos), o una capa por fotograma (GIF animado, TIFF de varias
        // páginas…), con solo el primero visible.
        if target == .psd {
            let frames = min(CGImageSourceGetCount(source), Self.maxPSDLayers)
            let name = file.url.deletingPathExtension().lastPathComponent
            var layers: [PSDWriter.Layer] = []
            var images: [CGImage] = []
            for i in 0..<frames {
                try context.checkCancelled()
                guard let frame = ImageIOHelpers.orientedImage(from: source, index: i) else { continue }
                let image = ImageIOHelpers.adjusted(frame, with: context.policy.image)
                images.append(image)
                layers.append(PSDWriter.Layer(name: frames > 1 ? "Fotograma \(i + 1)" : name,
                                              image: image, visible: i == 0))
                context.report(Double(i + 1) / Double(frames) * 0.7)
            }
            guard !layers.isEmpty else { throw ConversionError.unreadable(file.url.lastPathComponent) }
            let temp = context.temporaryURL(ext: "psd")
            defer { try? FileManager.default.removeItem(at: temp) }
            // Una sola imagen: personas, animales y objetos van cada uno en su capa, en carpetas.
            if layers.count == 1, #available(macOS 14.0, *), let image = images.first,
               let scene = try? ObjectLayers.split(image, name: name) {
                context.report(0.85)
                try PSDWriter.write(scene, width: image.width, height: image.height, to: temp)
            } else {
                context.report(0.85)
                try PSDWriter.write(layers, to: temp)
            }
            return [try context.finalize(temp: temp, for: file.url, ext: "psd")]
        }

        // Imagen → imagen
        guard let image = ImageIOHelpers.orientedImage(from: source) else {
            throw ConversionError.unreadable(file.url.lastPathComponent)
        }
        context.report(0.4)
        try context.checkCancelled()
        let temp = context.temporaryURL(ext: target.ext)
        let options = context.policy.image
        try ImageIOHelpers.write(ImageIOHelpers.adjusted(image, with: options), as: target,
                                 metadata: options.keepMetadata ? ImageIOHelpers.metadata(from: source) : [:],
                                 quality: quality, to: temp, context: context)
        return [try context.finalize(temp: temp, for: file.url, ext: target.ext)]
    }
}

/// Herramientas rápidas para imágenes (rueda Cmd).
struct ImageToolsConverter: Converter {
    let id = "image.tools"
    let mode = WheelMode.tools

    private enum Tool: String {
        case crop, rotate, removeBackground, compress, half, strip, edit, annotate, background, redact, collage
    }

    func options(for file: FileInfo) -> [WheelOption] {
        guard let format = ImageFormat.detect(file), format != .pdf else { return [] }
        // A la vista: recortar, editar, anotar, añadir fondo, ocultar y comprimir (y «Metadatos…», que añade su
        // propio conversor). Lo demás va en «Más…».
        func windowed(_ tool: Tool, _ title: String, _ symbol: String, _ label: String, _ editor: EditorKind) -> WheelOption {
            var o = option(tool, title, symbol, label)
            o.editor = editor
            return o
        }
        var result: [WheelOption] = [
            windowed(.crop, "Recortar…", "crop", "Recortar imagen", .crop),
            windowed(.edit, "Editar…", "slider.horizontal.3", "Editar la foto: luz, color y detalle", .photoEdit),
            windowed(.annotate, "Anotar…", "pencil.tip.crop.circle", "Anotar con flechas, texto, formas y números", .annotate),
            windowed(.background, "Fondo…", "photo.on.rectangle", "Poner la foto sobre un fondo", .background),
            windowed(.redact, "Ocultar…", "eye.slash.circle", "Tapar o desenfocar zonas privadas", .redact),
        ]
        if format.isLossy || format == .tiff || format == .png {
            result.append(option(.compress, "Comprimir", "arrow.down.right.and.arrow.up.left", "Comprimir imagen"))
        }
        if #available(macOS 14.0, *) {
            result.append(option(.removeBackground, "Quitar fondo", "person.crop.rectangle",
                                 "Quitar el fondo y dejar solo el sujeto").asSecondary)
        }
        result.append(option(.rotate, "Rotar", "rotate.right", "Rotar 90 grados a la derecha").asSecondary)
        result.append(option(.half, "Reducir 50%", "minus.magnifyingglass", "Reducir tamaño a la mitad").asSecondary)
        result.append(option(.strip, "Sin metadatos", "eye.slash", "Quitar metadatos de ubicación y cámara").asSecondary)
        return result
    }

    private func option(_ tool: Tool, _ title: String, _ symbol: String, _ label: String) -> WheelOption {
        WheelOption(id: "\(id).\(tool.rawValue)", providerID: id, title: title, symbol: symbol, accessibilityLabel: label)
    }

    /// Con dos o más fotos aparece «Collage…» (primero, para que se vea).
    func options(for files: [FileInfo]) -> [WheelOption] {
        let common = commonOptions(for: files)
        guard files.count > 1, files.allSatisfy({ ImageFormat.detect($0).map { $0 != .pdf } ?? false }) else { return common }
        var collage = option(.collage, "Collage…", "square.grid.2x2", "Hacer un collage con las fotos")
        collage.editor = .collage
        return [collage] + common
    }

    func runBatch(_ option: WheelOption, on files: [FileInfo], context: JobContext) throws -> [URL]? {
        guard Tool(rawValue: String(option.id.dropFirst(id.count + 1))) == .collage else { return nil }
        let request = ToolPayloadStore.shared.take(context.parameters["payload"], as: CollageRequest.self)
        let layout = request?.layout ?? CollageLayout()
        let urls = request?.urls ?? files.map(\.url)
        // Cada foto se lee al tamaño que necesita su celda (no más), para no gastar memoria.
        let images = try urls.enumerated().map { i, url -> CGImage in
            try context.checkCancelled()
            context.report(Double(i) / Double(urls.count) * 0.7)
            guard let image = EditorImage.load(url, maxPixels: layout.width) else { throw ConversionError.unreadable(url.lastPathComponent) }
            return image
        }
        guard let collage = layout.render(images, width: layout.width) else { throw ConversionError.writeFailed("JPG") }
        let temp = context.temporaryURL(ext: "jpg")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ImageIOHelpers.write(collage, as: .jpeg, metadata: [:], quality: max(context.policy.quality, 0.9), to: temp, context: context)
        let base = urls[0].deletingPathExtension().lastPathComponent
        return [try context.finalize(temp: temp, for: urls[0], ext: "jpg", tag: "collage", baseName: base)]
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let tool = Tool(rawValue: String(option.id.dropFirst(id.count + 1))),
              let format = ImageFormat.detect(file) else { throw ConversionError.unsupported }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              var image = ImageIOHelpers.orientedImage(from: source) else {
            throw ConversionError.unreadable(file.url.lastPathComponent)
        }
        context.report(0.4)
        try context.checkCancelled()

        // Quitar fondo: siempre PNG, porque el fondo queda transparente.
        if tool == .removeBackground {
            guard #available(macOS 14.0, *) else { throw ConversionError.message("Quitar fondo necesita macOS 14 o posterior.") }
            let cutout = try BackgroundRemover.cutout(image)
            let temp = context.temporaryURL(ext: "png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try ImageIOHelpers.write(cutout, as: .png, metadata: [:], quality: 1, to: temp, context: context)
            return [try context.finalize(temp: temp, for: file.url, ext: "png", tag: "sin-fondo")]
        }

        var metadata = ImageIOHelpers.metadata(from: source)

        // Comprimir: el resultado tiene que pesar menos que el original. Se prueba con calidades cada vez
        // más bajas (JPG, HEIC, WebP…), sin pérdida (TIFF con LZW) o con paleta de 256 colores (PNG); si no baja,
        // se avisa y no se crea nada.
        if tool == .compress {
            let original = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            let temp = context.temporaryURL(ext: format.ext)
            defer { try? FileManager.default.removeItem(at: temp) }
            let qualities = format == .tiff || format == .png ? [1.0] : [min(context.policy.quality, 0.6), 0.45, 0.3]
            for quality in qualities {
                try context.checkCancelled()
                if format == .png {
                    try PNGQuantizer.write(image, to: temp)          // 256 colores con tramado, como TinyPNG
                } else if format == .tiff {
                    try ImageIOHelpers.writeTIFFLZW(image, metadata: metadata, to: temp)
                } else {
                    try ImageIOHelpers.write(image, as: format, metadata: metadata, quality: quality, to: temp, context: context)
                }
                // Tamaño leído del disco cada vez (URL guarda en memoria el primero que leyó).
                let size = ((try? FileManager.default.attributesOfItem(atPath: temp.path))?[.size] as? Int) ?? Int.max
                if original == 0 || Double(size) < Double(original) * 0.95 {
                    return [try context.finalize(temp: temp, for: file.url, ext: format.ext, tag: "comprimida")]
                }
            }
            throw ConversionError.message("«\(file.url.lastPathComponent)» ya está muy comprimida: no puedo hacer que pese "
                                          + "menos sin que se note. No se ha creado ningún archivo.")
        }
        var quality = context.policy.quality
        let tag: String
        switch tool {
        case .removeBackground:
            throw ConversionError.unsupported
        case .crop:
            let p = context.parameters
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let rect = CGRect(x: (p["x"] ?? 0) * w, y: (p["y"] ?? 0) * h,
                              width: (p["w"] ?? 1) * w, height: (p["h"] ?? 1) * h).integral
            guard let cropped = image.cropping(to: rect) else { throw ConversionError.writeFailed(format.title) }
            image = cropped
            tag = "recorte"
        case .rotate:
            guard let rotated = ImageIOHelpers.rotatedClockwise(image) else { throw ConversionError.writeFailed(format.title) }
            image = rotated
            tag = "rotada"
        case .compress:
            throw ConversionError.unsupported   // se hace arriba
        case .half:
            guard let small = ImageIOHelpers.resized(image, scale: 0.5) else { throw ConversionError.writeFailed(format.title) }
            image = small
            tag = "50"
        case .strip:
            metadata = [:]
            tag = "sin-metadatos"
        case .edit:
            let adjustments = PhotoAdjustments(context.parameters)
            guard !adjustments.isIdentity else { throw ConversionError.message("No has cambiado ningún ajuste.") }
            let edited = adjustments.apply(to: CIImage(cgImage: image))
            guard let cg = PhotoRenderer.context.createCGImage(edited, from: edited.extent,
                                                               format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
            else { throw ConversionError.writeFailed(format.title) }
            image = cg
            quality = max(quality, 0.9)
            tag = "editada"
        case .annotate:
            guard let annotations = ToolPayloadStore.shared.take(context.parameters["payload"], as: [Annotation].self),
                  !annotations.isEmpty else { throw ConversionError.message("No has añadido ninguna anotación.") }
            guard let drawn = MarkupRenderer.annotated(image, with: annotations) else { throw ConversionError.writeFailed(format.title) }
            image = drawn
            quality = max(quality, 0.9)
            tag = "anotada"
        case .background:
            // Sin ventana (Terminal, pruebas): el fondo de serie.
            let style = ToolPayloadStore.shared.take(context.parameters["payload"], as: BackgroundStyle.self) ?? BackgroundStyle()
            guard let framed = style.render(image) else { throw ConversionError.writeFailed(format.title) }
            image = framed
            quality = max(quality, 0.9)
            tag = "con-fondo"
        case .redact:
            guard let plan = ToolPayloadStore.shared.take(context.parameters["payload"], as: RedactionPlan.self),
                  !plan.areas.isEmpty else { throw ConversionError.message("No has marcado ninguna zona para ocultar.") }
            guard let hidden = plan.apply(to: image) else { throw ConversionError.writeFailed(format.title) }
            image = hidden
            metadata = [:]   // lo que se oculta no debe quedar en la miniatura ni en los datos de la foto
            quality = max(quality, 0.9)
            tag = "oculta"
        case .collage:
            throw ConversionError.message("Para hacer un collage, arrastra dos o más fotos a la vez.")
        }

        let temp = context.temporaryURL(ext: format.ext)
        try ImageIOHelpers.write(image, as: format, metadata: metadata, quality: quality, to: temp, context: context)
        return [try context.finalize(temp: temp, for: file.url, ext: format.ext, tag: tag)]
    }
}

/// Número de páginas de un PDF (para nombrar "pagina-N" aunque solo se conviertan algunas).
enum PDFDocumentPageCount {
    static func of(_ url: URL) -> Int? { PDFDocument(url: url)?.pageCount }
}

/// Quita el fondo con el reconocimiento de imágenes de macOS (el mismo de "Copiar sujeto" en Fotos).
@available(macOS 14.0, *)
enum BackgroundRemover {
    static func cutout(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConversionError.message("No encontré un sujeto claro (persona, animal u objeto) en la imagen.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext(options: nil).createCGImage(ci, from: ci.extent) else {
            throw ConversionError.writeFailed("PNG")
        }
        return cg
    }
}
