import Foundation
import ImageIO
import CoreGraphics
import PDFKit
import CoreImage

/// Funciones de bajo nivel para leer y escribir imágenes con los frameworks de Apple.
enum ImageIOHelpers {

    /// Lee una imagen ya girada según su orientación EXIF (las fotos del móvil a veces vienen "de lado").
    static func orientedImage(from source: CGImageSource, index: Int = 0) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxSide = max(width, height)
        guard maxSide > 0 else { return CGImageSourceCreateImageAtIndex(source, index, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// Metadatos útiles (EXIF, GPS, IPTC, TIFF) sin la orientación, porque la imagen ya viene girada.
    static func metadata(from source: CGImageSource, index: Int = 0) -> [CFString: Any] {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return [:] }
        var result: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = props[key] { result[key] = value }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        return result
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Pinta la imagen sobre fondo blanco (para formatos sin transparencia como JPG o BMP).
    static func flattened(_ image: CGImage) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Redimensiona con interpolación de alta calidad.
    static func resized(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Aplica los ajustes de Ajustes → Imágenes: tamaño, volteo y escala de grises.
    static func adjusted(_ image: CGImage, with options: ImageOptions) -> CGImage {
        var result = image
        let scale = options.scale(width: image.width, height: image.height)
        if abs(scale - 1) > 0.001, let small = resized(result, scale: scale) { result = small }
        if options.flip != .none, let flipped = flipped(result, horizontally: options.flip == .horizontal) { result = flipped }
        if options.grayscale, let gray = grayscale(result) { result = gray }
        return result
    }

    static func flipped(_ image: CGImage, horizontally: Bool) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if horizontally {
            ctx.translateBy(x: CGFloat(image.width), y: 0); ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Blanco y negro conservando la transparencia.
    static func grayscale(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: nil).createCGImage(output, from: input.extent)
    }

    /// Gira 90° en el sentido de las agujas del reloj.
    static func rotatedClockwise(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Guarda una imagen en el formato indicado (todos excepto PDF).
    static func write(_ image: CGImage, as format: ImageFormat, metadata: [CFString: Any],
                      quality: Double, to url: URL, context: JobContext) throws {
        var image = image
        if !format.supportsAlpha && hasAlpha(image), let flat = flattened(image) {
            image = flat
        }

        if format == .webp {
            try writeWebP(image, quality: quality, to: url, context: context)
            return
        }
        if format == .ico || format == .icns {
            try writeIcon(image, as: format, to: url)
            return
        }
        if format == .psd {
            // PSD con una capa normal y editable (no una capa de fondo bloqueada).
            try PSDWriter.write([PSDWriter.Layer(name: "Capa 1", image: image)], to: url)
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed(format.title)
        }
        var props = metadata
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.writeFailed(format.title) }
    }

    /// TIFF comprimido sin pérdida (LZW, como el de Photoshop).
    static func writeTIFFLZW(_ image: CGImage, metadata: [CFString: Any], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, ImageFormat.tiff.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed("TIFF")
        }
        var props = metadata
        var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFCompression] = 5     // LZW
        props[kCGImagePropertyTIFFDictionary] = tiff
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.writeFailed("TIFF") }
    }

    /// Iconos: cuadrados y en los tamaños estándar (ICO hasta 256 px; ICNS de 16 a 1024 px).
    private static func writeIcon(_ image: CGImage, as format: ImageFormat, to url: URL) throws {
        let sizes = format == .ico ? [256, 128, 64, 48, 32, 16] : [1024, 512, 256, 128, 64, 32, 16]
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString,
                                                         sizes.count, nil) else {
            throw ConversionError.writeFailed(format.title)
        }
        for size in sizes {
            if let square = squared(image, side: size) { CGImageDestinationAddImage(dest, square, nil) }
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.writeFailed(format.title) }
    }

    /// Encaja la imagen centrada en un cuadrado transparente de `side` píxeles.
    static func squared(_ image: CGImage, side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// macOS sabe leer WebP pero no guardarlo: usamos `cwebp` (de Google, incluido en Fluxio). Se le pasa la
    /// imagen como PAM (sin comprimir, con transparencia), que cwebp lee sin necesitar otras librerías.
    private static func writeWebP(_ image: CGImage, quality: Double, to url: URL, context: JobContext) throws {
        let cwebp = try ExternalTool.require("cwebp", engine: "WebP")
        let pam = context.temporaryURL(ext: "pam")
        defer { try? FileManager.default.removeItem(at: pam) }
        try writePAM(image, to: pam)
        try ExternalTool.run(cwebp, arguments: ["-quiet", "-q", String(Int(quality * 100)), pam.path, "-o", url.path],
                             context: context)
    }

    /// Guarda la imagen como PAM RGBA (colores sin premultiplicar, en sRGB).
    private static func writePAM(_ image: CGImage, to url: URL) throws {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.writeFailed("WebP") }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
        }
        var data = Data("P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".utf8)
        data.append(contentsOf: pixels)
        try data.write(to: url)
    }

    /// Crea un PDF con una página por imagen.
    static func writePDF(_ images: [CGImage], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConversionError.writeFailed("PDF")
        }
        for image in images {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Convierte cada página de un PDF en imagen (a 144 ppp, nítido en pantallas Retina).
    /// Usa el rango de páginas y la resolución (ppp) de Ajustes → PDF. Devuelve cada página con su número.
    static func renderPDFPages(_ url: URL, context: JobContext) throws -> [(number: Int, image: CGImage)] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        let scale = CGFloat(context.policy.pdf.dpi) / 72
        let wanted = try context.policy.pdf.pages(count: document.pageCount)
        var images: [(number: Int, image: CGImage)] = []
        for (n, i) in wanted.enumerated() {
            try context.checkCancelled()
            guard let page = document.page(at: i) else { continue }
            var bounds = page.bounds(for: .cropBox)
            if page.rotation % 180 != 0 { bounds.size = CGSize(width: bounds.height, height: bounds.width) }
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumb = page.thumbnail(of: size, for: .cropBox)
            if let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                images.append((i + 1, cg))
            }
            context.report(Double(n + 1) / Double(wanted.count) * 0.5)
        }
        return images
    }
}
