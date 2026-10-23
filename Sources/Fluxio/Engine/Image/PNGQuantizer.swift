import Compression
import CoreGraphics
import Foundation

/// Comprime un PNG como TinyPNG: reduce la imagen a una paleta de 256 colores (con transparencia) elegidos
/// para esa imagen, la repinta con un tramado fino (Floyd–Steinberg) para que los degradados no hagan
/// escalones, y la guarda como PNG de paleta, que ocupa mucho menos.
enum PNGQuantizer {
    static func write(_ image: CGImage, to url: URL) throws {
        let width = image.width, height = image.height, count = width * height
        var pixels = [UInt8](repeating: 0, count: count * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.writeFailed("PNG") }
        // Sin premultiplicar (el PNG guarda el color "puro").
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
        }

        let palette = makePalette(pixels, count: count)
        let indices = palette.exact != nil ? palette.exact! : dither(pixels, width: width, height: height, palette: palette.colors)
        try writeIndexedPNG(indices, palette: palette.colors, width: width, height: height, to: url)
    }

    // MARK: Paleta (corte por la mediana)

    private struct Box {
        var colors: [UInt32]   // RGBA empaquetado
        var spread: (channel: Int, range: Int) {
            var low = [255, 255, 255, 255], high = [0, 0, 0, 0]
            for color in colors {
                for c in 0..<4 {
                    let v = Int((color >> UInt32(24 - c * 8)) & 0xFF)
                    low[c] = min(low[c], v); high[c] = max(high[c], v)
                }
            }
            var best = 0
            for c in 1..<4 where high[c] - low[c] > high[best] - low[best] { best = c }
            return (best, high[best] - low[best])
        }
    }

    /// 256 colores como mucho. Si la imagen ya tiene 256 colores o menos, se usan tal cual (sin tramado).
    private static func makePalette(_ pixels: [UInt8], count: Int) -> (colors: [UInt32], exact: [UInt8]?) {
        func pack(_ i: Int) -> UInt32 {
            // Los píxeles transparentes del todo comparten un solo color.
            if pixels[i * 4 + 3] == 0 { return 0 }
            return UInt32(pixels[i * 4]) << 24 | UInt32(pixels[i * 4 + 1]) << 16 | UInt32(pixels[i * 4 + 2]) << 8 | UInt32(pixels[i * 4 + 3])
        }
        // ¿Ya tiene pocos colores?
        var unique: [UInt32: UInt8] = [:]
        var exact = [UInt8](repeating: 0, count: count)
        for p in 0..<count {
            let color = pack(p)
            if let index = unique[color] { exact[p] = index; continue }
            if unique.count >= 256 { unique.removeAll(); break }
            unique[color] = UInt8(unique.count)
            exact[p] = unique[color]!
        }
        if !unique.isEmpty {
            var colors = [UInt32](repeating: 0, count: unique.count)
            for (color, index) in unique { colors[Int(index)] = color }
            return (colors, exact)
        }

        // Muestra de píxeles (como mucho ~300 000, repartidos por toda la imagen).
        let step = max(1, count / 300_000)
        var sample: [UInt32] = []
        sample.reserveCapacity(count / step + 1)
        for p in stride(from: 0, to: count, by: step) { sample.append(pack(p)) }

        var boxes = [Box(colors: sample)]
        while boxes.count < 256 {
            // Se parte la caja con más variedad (pesando cuántos colores tiene).
            var best = -1, bestScore = 0
            for (i, box) in boxes.enumerated() where box.colors.count > 1 {
                let score = box.spread.range * Int(Double(box.colors.count).squareRoot())
                if score > bestScore { best = i; bestScore = score }
            }
            guard best >= 0 else { break }
            let channel = boxes[best].spread.channel
            let shift = UInt32(24 - channel * 8)
            var colors = boxes[best].colors
            colors.sort { ($0 >> shift) & 0xFF < ($1 >> shift) & 0xFF }
            let middle = colors.count / 2
            boxes[best] = Box(colors: Array(colors[..<middle]))
            boxes.append(Box(colors: Array(colors[middle...])))
        }
        // Color de cada caja: la media de sus colores.
        let colors: [UInt32] = boxes.map { box in
            var sum = [0, 0, 0, 0]
            for color in box.colors { for c in 0..<4 { sum[c] += Int((color >> UInt32(24 - c * 8)) & 0xFF) } }
            let n = max(1, box.colors.count)
            return sum.enumerated().reduce(UInt32(0)) { $0 | UInt32((($1.element + n / 2) / n)) << UInt32(24 - $1.offset * 8) }
        }
        return (colors, nil)
    }

    // MARK: Tramado (Floyd–Steinberg)

    private static func dither(_ pixels: [UInt8], width: Int, height: Int, palette: [UInt32]) -> [UInt8] {
        let entries = palette.map { color in (0..<4).map { Int((color >> UInt32(24 - $0 * 8)) & 0xFF) } }
        // Caché del color más cercano (5 bits por canal): evita buscar entre 256 colores en cada píxel.
        var cache = [Int16](repeating: -1, count: 1 << 20)
        func nearest(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Int {
            let key = (r >> 3) << 15 | (g >> 3) << 10 | (b >> 3) << 5 | (a >> 3)
            if cache[key] >= 0 { return Int(cache[key]) }
            var best = 0, bestDistance = Int.max
            for (i, e) in entries.enumerated() {
                let dr = e[0] - r, dg = e[1] - g, db = e[2] - b, da = e[3] - a
                let distance = 2 * dr * dr + 4 * dg * dg + db * db + 3 * da * da
                if distance < bestDistance { best = i; bestDistance = distance }
            }
            cache[key] = Int16(best)
            return best
        }
        var indices = [UInt8](repeating: 0, count: width * height)
        // Errores pendientes de la fila actual y la siguiente.
        var current = [Int](repeating: 0, count: (width + 2) * 4), next = current
        for y in 0..<height {
            for i in 0..<next.count { next[i] = 0 }
            for x in 0..<width {
                let p = (y * width + x) * 4, e = (x + 1) * 4
                var value = [0, 0, 0, 0]
                for c in 0..<4 { value[c] = min(255, max(0, Int(pixels[p + c]) + current[e + c] / 16)) }
                if pixels[p + 3] == 0 { value = [0, 0, 0, 0] }
                let index = nearest(value[0], value[1], value[2], value[3])
                indices[y * width + x] = UInt8(index)
                for c in 0..<4 {
                    let error = value[c] - entries[index][c]
                    current[e + 4 + c] += error * 7
                    next[e - 4 + c] += error * 3
                    next[e + c] += error * 5
                    next[e + 4 + c] += error
                }
            }
            swap(&current, &next)
        }
        return indices
    }

    // MARK: PNG de paleta

    private static func writeIndexedPNG(_ indices: [UInt8], palette: [UInt32], width: Int, height: Int, to url: URL) throws {
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: Data) {
            var length = Data(); length.appendBig(UInt32(body.count))
            out.append(length)
            var typed = Data(type.utf8); typed.append(body)
            out.append(typed)
            var crc = Data(); crc.appendBig(crc32(typed))
            out.append(crc)
        }
        var header = Data()
        header.appendBig(UInt32(width)); header.appendBig(UInt32(height))
        header.append(contentsOf: [8, 3, 0, 0, 0])            // 8 bits, paleta, sin entrelazado
        chunk("IHDR", header)
        chunk("PLTE", Data(palette.flatMap { [UInt8($0 >> 24 & 0xFF), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF)] }))
        let alphas = palette.map { UInt8($0 & 0xFF) }
        if alphas.contains(where: { $0 < 255 }) {
            // Solo hasta el último color con transparencia (lo demás es opaco).
            let last = alphas.lastIndex { $0 < 255 }!
            chunk("tRNS", Data(alphas[...last]))
        }
        // Filas con el filtro "ninguno" (lo recomendado para PNG de paleta).
        var raw = Data(capacity: (width + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: indices[(y * width)..<((y + 1) * width)])
        }
        chunk("IDAT", try zlib(raw))
        chunk("IEND", Data())
        try out.write(to: url)
    }

    /// Flujo zlib (cabecera + DEFLATE + suma Adler-32), como lo exige PNG.
    private static func zlib(_ data: Data) throws -> Data {
        var deflated = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in if let chunk { deflated.append(chunk) } }
        try filter.write(data)
        try filter.finalize()
        var result = Data([0x78, 0x9C])
        result.append(deflated)
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { bytes in
            for byte in bytes { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        }
        result.appendBig(b << 16 | a)
        return result
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendBig(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
