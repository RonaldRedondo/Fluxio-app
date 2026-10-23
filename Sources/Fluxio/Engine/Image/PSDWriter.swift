import CoreGraphics
import Foundation

/// Escribe archivos de Photoshop (PSD) con capas editables.
///
/// macOS solo sabe guardar PSD "aplanados" (una sola capa de fondo bloqueada). Aquí se escribe el
/// formato completo: cada imagen es una capa normal, con nombre, posición, transparencia, visibilidad y
/// modo de fusión, las capas pueden ir en carpetas (grupos) y se añade la imagen combinada que usan las
/// vistas previas. Los datos van comprimidos (PackBits, como Photoshop).
enum PSDWriter {
    /// Modos de fusión de capa (los nombres son las claves que usa Photoshop).
    enum BlendMode: String {
        case normal = "norm"
        /// «Trama»: aclara, ideal para luces y brillos.
        case screen = "scrn"
    }

    struct Layer {
        var name: String
        fileprivate let source: Source
        /// Esquina superior izquierda de la capa en el lienzo (las capas recortadas no empiezan en 0, 0).
        var x = 0, y = 0
        var visible = true
        var blendMode: BlendMode = .normal

        fileprivate enum Source {
            case image(CGImage)
            /// RGBA de 8 bits sin premultiplicar, filas de arriba abajo.
            case pixels([UInt8], width: Int, height: Int)
        }

        init(name: String, image: CGImage, visible: Bool = true) {
            self.name = name
            source = .image(image)
            self.visible = visible
        }

        /// Capa a partir de píxeles RGBA sin premultiplicar del tamaño del lienzo. Se recorta sola a la
        /// zona que tiene contenido (archivos más ligeros). `nil` si es transparente del todo.
        init?(name: String, rgba: [UInt8], width: Int, height: Int, visible: Bool = true,
              blendMode: BlendMode = .normal) {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                let row = y * width * 4
                for x in 0..<width where rgba[row + x * 4 + 3] > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
            guard maxX >= minX else { return nil }
            let w = maxX - minX + 1, h = maxY - minY + 1
            var cropped = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                let from = ((minY + y) * width + minX) * 4
                cropped.replaceSubrange(y * w * 4..<(y + 1) * w * 4, with: rgba[from..<from + w * 4])
            }
            self.name = name
            source = .pixels(cropped, width: w, height: h)
            x = minX
            y = minY
            self.visible = visible
            self.blendMode = blendMode
        }

        /// Capa ya recortada: `rgba` mide `width` × `height` y va en (`x`, `y`) del lienzo.
        init(name: String, croppedRGBA rgba: [UInt8], x: Int, y: Int, width: Int, height: Int, visible: Bool = true) {
            self.name = name
            source = .pixels(rgba, width: width, height: height)
            self.x = x
            self.y = y
            self.visible = visible
        }

        var width: Int {
            switch source {
            case .image(let image): return image.width
            case .pixels(_, let width, _): return width
            }
        }

        var height: Int {
            switch source {
            case .image(let image): return image.height
            case .pixels(_, _, let height): return height
            }
        }

        fileprivate func straightRGBA() throws -> [UInt8] {
            switch source {
            case .pixels(let data, _, _): return data
            case .image(let image): return try PSDWriter.straightRGBA(image)
            }
        }
    }

    /// Una capa o una carpeta de capas (en Photoshop: grupo).
    indirect enum Node {
        case layer(Layer)
        case group(String, [Node], visible: Bool = true)
    }

    /// Guarda las capas en `url`. La primera de la lista queda arriba del todo (como en el panel Capas).
    /// El lienzo mide lo mismo que la primera capa.
    static func write(_ layers: [Layer], to url: URL) throws {
        guard let first = layers.first else { throw ConversionError.writeFailed("PSD") }
        try write(layers.map { .layer($0) }, width: first.width, height: first.height, to: url)
    }

    /// Guarda capas y carpetas en un lienzo de `width` × `height`. La primera de la lista queda arriba.
    static func write(_ nodes: [Node], width: Int, height: Int, to url: URL) throws {
        guard width > 0, height > 0, width <= 30_000, height <= 30_000 else {
            throw ConversionError.message("Photoshop no admite imágenes de más de 30 000 píxeles por lado.")
        }
        // En el archivo, las capas van de abajo arriba. Una carpeta se escribe como: marca de cierre,
        // sus capas y, encima, la cabecera con su nombre.
        let records = fileOrder(nodes)
        guard !records.isEmpty else { throw ConversionError.writeFailed("PSD") }

        // El archivo se escribe por partes, directamente al disco: así los datos de las capas no se copian
        // varias veces en memoria (con fotos grandes eran cientos de MB).
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else { throw ConversionError.writeFailed("PSD") }
        defer { try? file.close() }

        var head = Data()
        // 1) Cabecera: firma, versión 1, 4 canales (RGBA), alto, ancho, 8 bits, modo RGB.
        head.append(ascii: "8BPS")
        head.append(u16: 1)
        head.append(Data(count: 6))
        head.append(u16: 4)
        head.append(u32: UInt32(height))
        head.append(u32: UInt32(width))
        head.append(u16: 8)
        head.append(u16: 3)

        // 2) Datos de modo de color: ninguno en RGB.
        head.append(u32: 0)

        // 3) Recursos: perfil de color sRGB, para que los colores se vean igual en Photoshop.
        var resources = Data()
        if let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? {
            resources.append(ascii: "8BIM")
            resources.append(u16: 1039)        // perfil ICC
            resources.append(Data(count: 2))   // nombre vacío (ya par)
            resources.append(u32: UInt32(icc.count))
            resources.append(icc)
            if icc.count % 2 == 1 { resources.append(0) }
        }
        head.append(u32: UInt32(resources.count))
        head.append(resources)

        // Una sola capa visible que ocupa todo el lienzo (foto sin sujetos): sus píxeles sirven también
        // para la imagen combinada, sin volver a dibujar la imagen.
        let single: Layer? = {
            guard records.count == 1, case .pixels(let layer) = records[0], layer.visible, layer.blendMode == .normal,
                  layer.x == 0, layer.y == 0, layer.width == width, layer.height == height else { return nil }
            return layer
        }()
        var singleRGBA: [UInt8]?

        // 4) Capas.
        var info = Data()
        var channelData = Data()
        for record in records {
            switch record {
            case .pixels(let layer):
                let rgba = try layer.straightRGBA()
                if single != nil { singleRGBA = rgba }
                // Canales: -1 = transparencia, 0 = rojo, 1 = verde, 2 = azul.
                let planes: [(id: Int16, offset: Int)] = [(-1, 3), (0, 0), (1, 1), (2, 2)]
                info.append(i32: Int32(layer.y))                    // arriba
                info.append(i32: Int32(layer.x))                    // izquierda
                info.append(i32: Int32(layer.y + layer.height))     // abajo
                info.append(i32: Int32(layer.x + layer.width))      // derecha
                info.append(u16: UInt16(planes.count))
                for plane in planes {
                    let data = encodeChannel(rgba, width: layer.width, height: layer.height, offset: plane.offset)
                    info.append(i16: plane.id)
                    info.append(u32: UInt32(data.count))
                    channelData.append(data)
                }
                info.append(ascii: "8BIM")
                info.append(ascii: layer.blendMode.rawValue)
                info.append(255)                                    // opacidad 100 %
                info.append(0)                                      // sin máscara de recorte
                info.append(layer.visible ? 0x08 : 0x0A)            // bit 1 = oculta
                info.append(0)
                info.append(extraData(name: layer.name, section: nil))

            case .groupStart(let name, let visible), .groupEnd(let name, let visible):
                // Cabecera y cierre de carpeta: capas vacías con una marca de sección («lsct»).
                let isStart: Bool = { if case .groupStart = record { return true } else { return false } }()
                info.append(Data(count: 16))                        // sin tamaño
                info.append(u16: 4)
                for id: Int16 in [-1, 0, 1, 2] {
                    info.append(i16: id)
                    info.append(u32: 2)                             // solo el tipo de compresión
                    channelData.append(u16: 0)
                }
                info.append(ascii: "8BIM")
                info.append(ascii: isStart ? "pass" : "norm")       // la carpeta deja pasar los modos de fusión
                info.append(255)
                info.append(0)
                info.append(visible ? 0x18 : 0x1A)                  // bit 4 = capa sin píxeles propios
                info.append(0)
                info.append(extraData(name: isStart ? name : "</Layer group>", section: isStart ? 1 : 3))
            }
        }
        // Número de capas en negativo: la imagen combinada guarda también la transparencia.
        let layerInfoCount = 2 + info.count + channelData.count
        let pad = layerInfoCount % 2 == 1 ? 1 : 0
        head.append(u32: UInt32(4 + layerInfoCount + pad + 4))
        head.append(u32: UInt32(layerInfoCount + pad))
        head.append(i16: -Int16(records.count))
        try file.write(contentsOf: head)
        try file.write(contentsOf: info)
        info = Data()
        try file.write(contentsOf: channelData)
        channelData = Data()
        var tail = Data()
        if pad == 1 { tail.append(0) }
        tail.append(u32: 0)                          // sin máscara global

        // 5) Imagen combinada: lo que se ve con las capas visibles (para vistas previas y otras apps).
        let composite: [UInt8]
        if var rgba = singleRGBA {
            // Lo mismo que `flatten` con una sola capa: donde es transparente del todo, el color queda en 0.
            for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] == 0 { rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0 }
            singleRGBA = nil
            composite = rgba
        } else {
            composite = try flatten(visibleLayers(nodes).reversed(), width: width, height: height)
        }
        tail.append(u16: 1)                          // comprimida con PackBits
        let channels = [0, 1, 2, 3].map { packedRows(composite, width: width, height: height, offset: $0) }  // R, G, B, transparencia
        for channel in channels { for row in channel { tail.append(u16: UInt16(row.count)) } }
        try file.write(contentsOf: tail)
        var chunk = Data()
        for channel in channels {
            for row in channel {
                chunk.append(row)
                if chunk.count >= 4 << 20 { try file.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            }
        }
        try file.write(contentsOf: chunk)
    }

    // MARK: Orden de las capas

    private enum Record {
        case pixels(Layer)
        case groupStart(String, visible: Bool)
        case groupEnd(String, visible: Bool)
    }

    /// Capas y carpetas en el orden del archivo (de abajo arriba).
    private static func fileOrder(_ nodes: [Node]) -> [Record] {
        nodes.reversed().flatMap { node -> [Record] in
            switch node {
            case .layer(let layer): return [.pixels(layer)]
            case .group(let name, let children, let visible):
                return [.groupEnd(name, visible: visible)] + fileOrder(children) + [.groupStart(name, visible: visible)]
            }
        }
    }

    /// Capas que se ven (visibles y dentro de carpetas visibles), de arriba abajo.
    private static func visibleLayers(_ nodes: [Node]) -> [Layer] {
        nodes.flatMap { node -> [Layer] in
            switch node {
            case .layer(let layer): return layer.visible ? [layer] : []
            case .group(_, let children, let visible): return visible ? visibleLayers(children) : []
            }
        }
    }

    // MARK: Datos extra de cada capa

    /// Máscara (ninguna), rangos de fusión (ninguno), nombre y, en carpetas, la marca de sección
    /// (1 = carpeta abierta, 3 = cierre de carpeta).
    private static func extraData(name: String, section: UInt32?) -> Data {
        var extra = Data()
        extra.append(u32: 0)                     // sin máscara de capa
        extra.append(u32: 0)                     // sin rangos de fusión
        extra.append(pascalName(name))
        extra.append(unicodeName(name))          // nombre con acentos ("Fotograma", "Capa"…)
        if let section {
            extra.append(ascii: "8BIM")
            extra.append(ascii: "lsct")
            if section == 1 {
                extra.append(u32: 12)
                extra.append(u32: section)
                extra.append(ascii: "8BIM")
                extra.append(ascii: "pass")
            } else {
                extra.append(u32: 4)
                extra.append(u32: section)
            }
        }
        var data = Data()
        data.append(u32: UInt32(extra.count))
        data.append(extra)
        return data
    }

    // MARK: Píxeles

    /// RGBA de 8 bits sin premultiplicar, filas de arriba abajo.
    private static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.writeFailed("PSD") }
        // Quitar la premultiplicación: el color se guarda "puro" y la transparencia aparte.
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Int(data[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { data[i + c] = UInt8(min(255, (Int(data[i + c]) * 255 + a / 2) / a)) }
        }
        return data
    }

    /// Superpone las capas visibles (de abajo arriba), cada una en su posición y con su modo de fusión.
    private static func flatten(_ layers: ReversedCollection<[Layer]>, width: Int, height: Int) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for layer in layers {
            let rgba = try layer.straightRGBA()
            for ly in 0..<layer.height {
                let y = layer.y + ly
                guard y >= 0, y < height else { continue }
                for lx in 0..<layer.width {
                    let x = layer.x + lx
                    guard x >= 0, x < width else { continue }
                    let s = (ly * layer.width + lx) * 4, d = (y * width + x) * 4
                    let sa = Double(rgba[s + 3]) / 255
                    guard sa > 0 else { continue }
                    let da = Double(result[d + 3]) / 255
                    let oa = sa + da * (1 - sa)
                    for c in 0..<3 {
                        let cs = Double(rgba[s + c]) / 255, cb = Double(result[d + c]) / 255
                        // Color de la capa ya mezclado con lo de abajo según su modo (donde hay algo debajo).
                        let mixed: Double
                        switch layer.blendMode {
                        case .normal: mixed = cs
                        case .screen: mixed = 1 - (1 - cb) * (1 - cs)
                        }
                        let blended = (1 - da) * cs + da * mixed
                        let value = (blended * sa + cb * da * (1 - sa)) / oa
                        result[d + c] = UInt8(min(255, max(0, (value * 255).rounded())))
                    }
                    result[d + 3] = UInt8((oa * 255).rounded())
                }
            }
        }
        return result
    }

    // MARK: Compresión (PackBits)

    /// Un canal de una capa: tipo de compresión, cuántos bytes ocupa cada fila y las filas comprimidas.
    private static func encodeChannel(_ rgba: [UInt8], width: Int, height: Int, offset: Int) -> Data {
        let rows = packedRows(rgba, width: width, height: height, offset: offset)
        var data = Data()
        data.append(u16: 1)
        rows.forEach { data.append(u16: UInt16($0.count)) }
        rows.forEach { data.append($0) }
        return data
    }

    private static func packedRows(_ rgba: [UInt8], width: Int, height: Int, offset: Int) -> [Data] {
        var row = [UInt8](repeating: 0, count: width)
        return (0..<height).map { y in
            let base = y * width * 4 + offset
            for x in 0..<width { row[x] = rgba[base + x * 4] }
            return packBits(row)
        }
    }

    /// PackBits: las repeticiones se guardan como "n veces este byte" y el resto tal cual.
    static func packBits(_ bytes: [UInt8]) -> Data {
        var out = Data()
        var i = 0
        let n = bytes.count
        while i < n {
            // ¿Cuántas veces seguidas se repite este byte? (como mucho 128)
            var run = 1
            while i + run < n, run < 128, bytes[i + run] == bytes[i] { run += 1 }
            if run >= 3 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(bytes[i])
                i += run
                continue
            }
            // Tramo literal hasta la próxima repetición de 3 o más (como mucho 128 bytes).
            var end = i
            while end < n, end - i < 128 {
                if end + 2 < n, bytes[end] == bytes[end + 1], bytes[end] == bytes[end + 2] { break }
                end += 1
            }
            out.append(UInt8(end - i - 1))
            out.append(contentsOf: bytes[i..<end])
            i = end
        }
        return out
    }

    // MARK: Nombres de capa

    /// Nombre corto (sin acentos), rellenado hasta múltiplo de 4 bytes.
    private static func pascalName(_ name: String) -> Data {
        let ascii = name.applyingTransform(.stripDiacritics, reverse: false)?
            .unicodeScalars.filter { $0.isASCII }.map { UInt8($0.value) } ?? []
        let bytes = Array(ascii.prefix(255))
        var data = Data([UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    /// Nombre completo en Unicode (bloque "luni"), que es el que muestra Photoshop.
    private static func unicodeName(_ name: String) -> Data {
        let units = Array(name.utf16)
        var body = Data()
        body.append(u32: UInt32(units.count))
        units.forEach { body.append(u16: $0) }
        if body.count % 4 != 0 { body.append(Data(count: 4 - body.count % 4)) }
        var data = Data()
        data.append(ascii: "8BIM")
        data.append(ascii: "luni")
        data.append(u32: UInt32(body.count))
        data.append(body)
        return data
    }
}

// MARK: - Escritura en orden "big-endian" (el que usa PSD)

private extension Data {
    mutating func append(ascii text: String) { append(contentsOf: Array(text.utf8)) }
    mutating func append(u16 value: UInt16) { append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
    mutating func append(i16 value: Int16) { append(u16: UInt16(bitPattern: value)) }
    mutating func append(u32 value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    mutating func append(i32 value: Int32) { append(u32: UInt32(bitPattern: value)) }
}
