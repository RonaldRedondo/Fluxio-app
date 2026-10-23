import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Imágenes ↔ vectores:
/// - Imagen (PNG, JPG…) → **SVG** trazado con potrace, en color (Ajustes → Imágenes → Colores al vectorizar).
/// - **SVG** → PNG, JPG o PDF (macOS lee SVG por sí solo).
struct VectorConverter: Converter {
    let id = "vector.convert"
    let mode = WheelMode.convert

    func options(for file: FileInfo) -> [WheelOption] {
        if Self.isSVG(file) {
            return [("png", "PNG", "photo.on.rectangle"), ("jpg", "JPG", "photo"), ("pdf", "PDF", "doc.richtext")]
                .map { WheelOption(id: "\(id).\($0.0)", providerID: id, title: $0.1, symbol: $0.2,
                                   accessibilityLabel: "Convertir a \($0.1)") }
        }
        guard let format = ImageFormat.detect(file), format != .pdf else {
            return file.conforms(to: .image) ? [traceOption] : []
        }
        return [traceOption]
    }

    private var traceOption: WheelOption {
        WheelOption(id: "\(id).svg", providerID: id, title: "SVG", symbol: "scribble.variable",
                    accessibilityLabel: "Convertir en vector SVG")
    }

    static func isSVG(_ file: FileInfo) -> Bool {
        file.url.pathExtension.lowercased() == "svg" || file.conforms(to: .svg)
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let target = action(of: option)
        if Self.isSVG(file) { return try fromSVG(file, to: target, context: context) }
        guard target == "svg" else { throw ConversionError.unsupported }
        return [try Tracer.trace(file, context: context)]
    }

    // MARK: SVG → imagen o PDF

    private func fromSVG(_ file: FileInfo, to target: String, context: JobContext) throws -> [URL] {
        guard let svg = NSImage(contentsOf: file.url), svg.size.width > 0 else {
            throw ConversionError.unreadable(file.url.lastPathComponent)
        }
        let temp = context.temporaryURL(ext: target)
        defer { try? FileManager.default.removeItem(at: temp) }

        if target == "pdf" {
            // Se dibuja en un PDF: sigue siendo vectorial (se puede ampliar sin perder nitidez).
            var box = CGRect(origin: .zero, size: svg.size)
            guard let ctx = CGContext(temp as CFURL, mediaBox: &box, nil) else { throw ConversionError.writeFailed("PDF") }
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            svg.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            ctx.closePDF()
            return [try context.finalize(temp: temp, for: file.url, ext: "pdf")]
        }

        // A imagen: al doble de su tamaño para que se vea nítida en pantallas Retina.
        var rect = CGRect(x: 0, y: 0, width: svg.size.width * 2, height: svg.size.height * 2)
        guard let cg = svg.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw ConversionError.unreadable(file.url.lastPathComponent)
        }
        let format: ImageFormat = target == "jpg" ? .jpeg : .png
        try ImageIOHelpers.write(ImageIOHelpers.adjusted(cg, with: context.policy.image), as: format, metadata: [:],
                                 quality: context.policy.quality, to: temp, context: context)
        return [try context.finalize(temp: temp, for: file.url, ext: format.ext)]
    }
}

// MARK: - Trazado a color con potrace

/// 1) reduce la imagen a pocos colores, 2) traza cada color con potrace,
/// 3) apila las capas de mayor a menor (cada capa cubre también a las siguientes, así no quedan huecos).
enum Tracer {
    /// Lado máximo con el que se traza (más grande = más lento y casi sin mejora visible).
    static let maxSide = 1600

    static func trace(_ file: FileInfo, context: JobContext) throws -> URL {
        let potrace = try ExternalTool.require("potrace", engine: "Potrace")
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let original = ImageIOHelpers.orientedImage(from: source) else {
            throw ConversionError.unreadable(file.url.lastPathComponent)
        }
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(original.width, original.height)))
        let image = scale < 1 ? (ImageIOHelpers.resized(original, scale: scale) ?? original) : original
        let width = image.width, height = image.height
        let pixels = try rgba(image)
        context.report(0.1)

        // 1) Paleta reducida (k-means) y a qué color pertenece cada píxel (-1 = transparente).
        let colorCount = max(2, min(16, context.policy.image.traceColors))
        let palette = kMeans(pixels, k: colorCount)
        var labels = [Int](repeating: -1, count: width * height)
        var area = [Int](repeating: 0, count: palette.count)
        for i in 0..<(width * height) where pixels[i * 4 + 3] >= 128 {
            let c = nearest(pixels, i * 4, palette)
            labels[i] = c
            area[c] += 1
        }
        try context.checkCancelled()
        context.report(0.25)

        // 2) y 3) Capas apiladas: de la más extensa a la más pequeña.
        let order = area.indices.filter { area[$0] > 0 }.sorted { area[$0] > area[$1] }
        let work = context.temporaryURL(ext: "trazado")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var groups: [String] = []
        var header: String?
        for (step, colorIndex) in order.enumerated() {
            try context.checkCancelled()
            // La capa incluye su color y todos los que van encima.
            let covered = Set(order[step...])
            let pbm = work.appendingPathComponent("capa\(step).pbm")
            try writePBM(width: width, height: height, to: pbm) { covered.contains(labels[$0]) }
            let svg = work.appendingPathComponent("capa\(step).svg")
            try ExternalTool.run(potrace, arguments: ["--svg", "--flat", "-t", "4", "-O", "0.4", "-o", svg.path, pbm.path],
                                 context: context)
            let text = try String(contentsOf: svg, encoding: .utf8)
            if header == nil { header = svgOpening(text) }
            if let group = svgGroup(text, color: hex(palette[colorIndex])) { groups.append(group) }
            context.report(0.25 + 0.7 * Double(step + 1) / Double(order.count))
        }
        guard let opening = header, !groups.isEmpty else {
            throw ConversionError.message("No encontré formas que trazar en “\(file.url.lastPathComponent)”.")
        }

        // El SVG final mide lo mismo que la imagen original (aunque se haya trazado más pequeña).
        let sized = opening
            .replacingOccurrences(of: #"width="[^"]*""#, with: "width=\"\(original.width)\"", options: .regularExpression)
            .replacingOccurrences(of: #"height="[^"]*""#, with: "height=\"\(original.height)\"", options: .regularExpression)
        let result = sized + "\n" + groups.joined(separator: "\n") + "\n</svg>\n"
        let temp = context.temporaryURL(ext: "svg")
        defer { try? FileManager.default.removeItem(at: temp) }
        try result.write(to: temp, atomically: true, encoding: .utf8)
        return try context.finalize(temp: temp, for: file.url, ext: "svg")
    }

    // MARK: Píxeles

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ConversionError.writeFailed("SVG") }
        return data   // filas de arriba a abajo
    }

    private static func distance(_ p: [UInt8], _ i: Int, _ c: SIMD3<Double>) -> Double {
        let r = Double(p[i]) - c.x, g = Double(p[i + 1]) - c.y, b = Double(p[i + 2]) - c.z
        return r * r * 0.3 + g * g * 0.59 + b * b * 0.11   // el ojo nota más el verde
    }

    private static func nearest(_ p: [UInt8], _ i: Int, _ palette: [SIMD3<Double>]) -> Int {
        var best = 0, bestD = Double.greatestFiniteMagnitude
        for (k, c) in palette.enumerated() {
            let d = distance(p, i, c)
            if d < bestD { bestD = d; best = k }
        }
        return best
    }

    /// Agrupa los colores parecidos en `k` colores (con una muestra de píxeles, rápido).
    private static func kMeans(_ pixels: [UInt8], k: Int) -> [SIMD3<Double>] {
        let count = pixels.count / 4
        let step = max(1, count / 40_000)
        var samples: [Int] = []
        for i in stride(from: 0, to: count, by: step) where pixels[i * 4 + 3] >= 128 { samples.append(i * 4) }
        guard !samples.isEmpty else { return [SIMD3(0, 0, 0)] }

        // Inicio "k-means++": cada centro nuevo, lejos de los anteriores.
        var centers = [SIMD3(Double(pixels[samples[0]]), Double(pixels[samples[0] + 1]), Double(pixels[samples[0] + 2]))]
        while centers.count < k {
            var farthest = samples[0], farthestD = -1.0
            for s in samples {
                let d = centers.map { distance(pixels, s, $0) }.min()!
                if d > farthestD { farthestD = d; farthest = s }
            }
            if farthestD < 1 { break }   // la imagen tiene menos colores que k
            centers.append(SIMD3(Double(pixels[farthest]), Double(pixels[farthest + 1]), Double(pixels[farthest + 2])))
        }
        for _ in 0..<8 {
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count)
            var counts = [Int](repeating: 0, count: centers.count)
            for s in samples {
                let c = nearest(pixels, s, centers)
                sums[c] += SIMD3(Double(pixels[s]), Double(pixels[s + 1]), Double(pixels[s + 2]))
                counts[c] += 1
            }
            for c in centers.indices where counts[c] > 0 { centers[c] = sums[c] / Double(counts[c]) }
        }
        return centers
    }

    private static func hex(_ c: SIMD3<Double>) -> String {
        func h(_ v: Double) -> String { String(format: "%02X", Int(max(0, min(255, v.rounded())))) }
        return "#" + h(c.x) + h(c.y) + h(c.z)
    }

    // MARK: Archivos para potrace

    /// Imagen en blanco y negro (formato PBM): 1 = forma que hay que trazar.
    private static func writePBM(width: Int, height: Int, to url: URL, inside: (Int) -> Bool) throws {
        var data = Data("P4\n\(width) \(height)\n".utf8)
        let rowBytes = (width + 7) / 8
        var row = [UInt8](repeating: 0, count: rowBytes)
        for y in 0..<height {
            for i in 0..<rowBytes { row[i] = 0 }
            for x in 0..<width where inside(y * width + x) {
                row[x >> 3] |= 0x80 >> UInt8(x & 7)
            }
            data.append(contentsOf: row)
        }
        try data.write(to: url)
    }

    /// `<svg …>` de la salida de potrace.
    private static func svgOpening(_ text: String) -> String? {
        guard let start = text.range(of: "<svg"), let end = text.range(of: ">", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// El grupo `<g …>…</g>` con las formas, pintado del color de la capa.
    private static func svgGroup(_ text: String, color: String) -> String? {
        guard let start = text.range(of: "<g"), let end = text.range(of: "</g>", options: .backwards) else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: ##"fill="#[0-9a-fA-F]{6}""##, with: "fill=\"\(color)\"", options: .regularExpression)
    }
}
