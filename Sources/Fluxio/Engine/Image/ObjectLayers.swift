import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Separa las personas y los animales de una foto en capas para el PSD, con el reconocimiento de
/// imágenes de macOS (Vision, sin conexión). Resultado, de arriba abajo:
///   - Carpeta «Personas»: «Persona 1», «Persona 2»… (de izquierda a derecha).
///   - Carpeta «Animales»: cada animal con su nombre («Perro», «Cebra»…).
///   - «Fondo»: el resto de la imagen, con un hueco transparente donde estaban (no se reconstruye).
/// Los objetos (muebles, coches…) se quedan en el fondo.
///   - «Original»: la imagen completa, oculta (por si la necesitas).
/// Si no encuentra nada que separar, devuelve `nil` y el PSD queda con una sola capa.
@available(macOS 14.0, *)
enum ObjectLayers {
    /// A partir de qué opacidad del objeto se quita ese píxel del fondo (bordes suaves sin halos).
    private static let holeThreshold: Float = 0.97
    /// Por debajo de esta opacidad del objeto, el píxel se considera fondo puro.
    private static let edgeThreshold: Float = 0.02
    /// Cuántos píxeles hacia dentro se puede extender el color del fondo en los bordes.
    private static let maxEdgePasses = 24
    /// Siluetas más pequeñas que esto (fracción de la imagen) se ignoran: suelen ser ruido.
    private static let minimumArea = 0.002

    private enum Kind { case person, animal }

    /// Un sujeto ya convertido en capa (recortada). La silueta a tamaño completo no se guarda: con fotos
    /// grandes cada una ocupa ~100 MB.
    private struct Region {
        let kind: Kind
        let name: String
        let layer: PSDWriter.Layer?
        let area: Double
        /// Centro horizontal (para numerar a las personas de izquierda a derecha).
        let centerX: Double
    }

    static func split(_ image: CGImage, name: String) throws -> [PSDWriter.Node]? {
        let handler = VNImageRequestHandler(cgImage: image)
        let instances = VNGenerateForegroundInstanceMaskRequest()
        let people = VNGeneratePersonInstanceMaskRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        try handler.perform([instances, people, faces, animals])
        guard let observation = instances.results?.first, !observation.allInstances.isEmpty else { return nil }

        let width = image.width, height = image.height, count = width * height
        var pixels = try rgba(image)

        // Siluetas de personas sueltas: sirven para separar a varias personas que macOS ve como un solo objeto
        // (por ejemplo, abrazadas). Solo se usan para eso: también "ven" personas en animales u objetos.
        // Se leen solo si aparece una persona (cada una ocupa tanto como la foto).
        var personMasksRead: [[Float]]?
        func personMasks() throws -> [[Float]] {
            if let personMasksRead { return personMasksRead }
            var masks: [[Float]] = []
            if let result = people.results?.first {
                for instance in result.allInstances {
                    let mask = try autoreleasepool {
                        readMask(try result.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler),
                                 width: width, height: height)
                    }
                    if area(mask) >= minimumArea { masks.append(mask) }
                }
            }
            personMasksRead = masks
            return masks
        }
        // Puntos de referencia, en píxeles (origen arriba a la izquierda).
        let faceCenters = (faces.results ?? []).map { point(in: $0.boundingBox, width: width, height: height) }
        let animalHits = (animals.results ?? []).map { (center: point(in: $0.boundingBox, width: width, height: height),
                                                        label: $0.labels.first?.identifier) }

        var regions: [Region] = []
        // Hasta dónde cubre algún sujeto cada píxel (para el hueco del fondo).
        var covered = [Float](repeating: 0, count: count)
        func region(_ kind: Kind, _ name: String, _ mask: [Float], area size: Double) -> Region {
            for p in 0..<count where mask[p] > covered[p] { covered[p] = mask[p] }
            return Region(kind: kind, name: name, layer: layer(from: pixels, mask: mask, width: width, height: height),
                          area: size, centerX: centerX(mask, width: width))
        }
        for instance in observation.allInstances {
            let mask = try autoreleasepool {
                readMask(try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler),
                         width: width, height: height)
            }
            let size = area(mask)
            guard size >= minimumArea else { continue }
            let labels = classify(observation, instance: instance, handler: handler)
            let confidence = { (ids: Set<String>) in labels.filter { ids.contains($0.identifier) }.map(\.confidence).max() ?? 0 }
            let top = labels.first?.confidence ?? 0
            let animalScore = confidence(["animal"])
            let personScore = confidence(ObjectNames.people)
            let hasFace = faceCenters.contains { value(mask, at: $0, width: width) > 0.5 }
            let animalHit = animalHits.first { value(mask, at: $0.center, width: width) > 0.5 }

            if (hasFace && animalScore < 0.5) || (personScore >= 0.2 && personScore >= animalScore) {
                // Persona (o varias juntas: se reparten según las siluetas de personas).
                let inside = try personMasks().filter { overlap($0, mask) >= 0.5 * area($0) }
                let parts = inside.count >= 2 ? divide(mask, among: inside, width: width, height: height) : [mask]
                for part in parts where area(part) >= minimumArea {
                    regions.append(region(.person, "Persona", part, area: area(part)))
                }
            } else if animalHit != nil || (animalScore >= 0.08 && animalScore >= top * 0.6) {
                let fallback = animalHit?.label == VNAnimalIdentifier.cat.rawValue ? "Gato"
                             : animalHit?.label == VNAnimalIdentifier.dog.rawValue ? "Perro" : "Animal"
                let named = ObjectNames.name(for: labels, in: ObjectNames.animals)
                regions.append(region(.animal, named == nil || named == "Animal" ? fallback : named!, mask, area: size))
            }
        }
        guard !regions.isEmpty else { return nil }

        // Capas recortadas de cada región, agrupadas en carpetas.
        var nodes: [PSDWriter.Node] = []
        let groups: [(Kind, String, (Region, Region) -> Bool)] = [
            (.person, "Personas", { $0.centerX < $1.centerX }),
            (.animal, "Animales", { $0.area > $1.area }),
        ]
        for (kind, title, order) in groups {
            let members = regions.filter { $0.kind == kind }.sorted(by: order)
            guard !members.isEmpty else { continue }
            let names = numbered(members.map(\.name))
            var layers: [PSDWriter.Node] = []
            for (region, layerName) in zip(members, names) {
                if var layer = region.layer {
                    layer.name = layerName
                    layers.append(.layer(layer))
                }
            }
            if !layers.isEmpty { nodes.append(.group(title, layers)) }
        }
        guard !nodes.isEmpty else { return nil }

        // Fondo: la imagen sin lo separado (huecos transparentes). En el borde suave de cada región,
        // el color de la región se cambia por el del fondo de alrededor: así, al mover algo, no queda
        // su silueta dibujada en el fondo, y con todo en su sitio la foto se ve igual que antes.
        // (Se hace sobre los mismos píxeles de la foto, que ya no hacen falta: así no se copian.)
        cleanEdges(&pixels, covered: covered, width: width, height: height)
        for p in 0..<count where covered[p] >= holeThreshold { pixels[p * 4 + 3] = 0 }
        if let fondo = PSDWriter.Layer(name: "Fondo", rgba: pixels, width: width, height: height) {
            nodes.append(.layer(fondo))
        }
        nodes.append(.layer(PSDWriter.Layer(name: "Original · \(name)", image: image, visible: false)))
        return nodes
    }

    // MARK: Reconocimiento

    /// Qué es este objeto, según macOS (etiquetas en inglés, de más a menos segura). Se mira solo el objeto
    /// recortado sobre gris neutro (sobre negro, o con lo de alrededor, acierta menos).
    private static func classify(_ observation: VNInstanceMaskObservation, instance: Int,
                                 handler: VNImageRequestHandler) -> [(identifier: String, confidence: Float)] {
        guard let cutout = try? observation.generateMaskedImage(ofInstances: IndexSet(integer: instance), from: handler,
                                                                croppedToInstancesExtent: true) else { return [] }
        let object = CIImage(cvPixelBuffer: cutout)
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: object.extent)
        guard let image = CIContext().createCGImage(object.composited(over: gray), from: object.extent) else { return [] }
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { $0.confidence > 0.01 }.map { ($0.identifier, $0.confidence) }
    }

    /// "Silla", "Silla" → "Silla 1", "Silla 2". Las personas siempre van numeradas si hay más de una.
    private static func numbered(_ names: [String]) -> [String] {
        var total: [String: Int] = [:]
        names.forEach { total[$0, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return names.map { name in
            guard total[name, default: 0] > 1 else { return name }
            seen[name, default: 0] += 1
            return "\(name) \(seen[name]!)"
        }
    }

    // MARK: Máscaras

    private static func area(_ mask: [Float]) -> Double { Double(mask.reduce(0, +)) / Double(mask.count) }

    /// Parte de `a` que también está en `b` (en la misma escala que `area`).
    private static func overlap(_ a: [Float], _ b: [Float]) -> Double {
        var sum: Float = 0
        for p in 0..<a.count { sum += min(a[p], b[p]) }
        return Double(sum) / Double(a.count)
    }

    private static func centerX(_ mask: [Float], width: Int) -> Double {
        var sum = 0.0, weighted = 0.0
        for p in 0..<mask.count where mask[p] > 0 {
            sum += Double(mask[p])
            weighted += Double(mask[p]) * Double(p % width)
        }
        return sum > 0 ? weighted / sum : 0
    }

    private static func point(in box: CGRect, width: Int, height: Int) -> (x: Int, y: Int) {
        (Int(box.midX * CGFloat(width)), Int((1 - box.midY) * CGFloat(height)))
    }

    private static func value(_ mask: [Float], at point: (x: Int, y: Int), width: Int) -> Float {
        let height = mask.count / width
        guard point.x >= 0, point.y >= 0, point.x < width, point.y < height else { return 0 }
        return mask[point.y * width + point.x]
    }

    /// Reparte un objeto entre varias personas: cada píxel va a la persona cuya silueta es más fuerte ahí.
    /// Los píxeles que no toca ninguna silueta (pelo suelto, ropa…) van a la persona más cercana.
    private static func divide(_ mask: [Float], among parts: [[Float]], width: Int, height: Int) -> [[Float]] {
        let count = mask.count
        var owner = [Int](repeating: -1, count: count)
        var frontier: [Int] = []
        for p in 0..<count where mask[p] > 0 {
            var best = -1, bestValue: Float = 0.1
            for (index, part) in parts.enumerated() where part[p] > bestValue { best = index; bestValue = part[p] }
            owner[p] = best
            if best >= 0 { frontier.append(p) }
        }
        // Extender cada persona hacia los píxeles sin dueño, de vecino en vecino.
        while !frontier.isEmpty {
            var next: [Int] = []
            for p in frontier {
                let x = p % width, y = p / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let q = ny * width + nx
                    if mask[q] > 0, owner[q] == -1 { owner[q] = owner[p]; next.append(q) }
                }
            }
            frontier = next
        }
        // Trozos sueltos (una mano que macOS dio a la persona de al lado) pasan a la persona que los rodea.
        var component = [Int](repeating: -1, count: count)
        var islands: [(owner: Int, pixels: [Int])] = []
        for start in 0..<count where owner[start] >= 0 && component[start] == -1 {
            var pixels = [start], stack = [start]
            component[start] = islands.count
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let q = ny * width + nx
                    if owner[q] == owner[p], component[q] == -1 {
                        component[q] = islands.count
                        pixels.append(q)
                        stack.append(q)
                    }
                }
            }
            islands.append((owner[start], pixels))
        }
        var largest: [Int: Int] = [:]
        islands.forEach { largest[$0.owner] = max(largest[$0.owner] ?? 0, $0.pixels.count) }
        for island in islands where island.pixels.count * 10 < largest[island.owner, default: 0] {
            var votes: [Int: Int] = [:]
            for p in island.pixels {
                let x = p % width, y = p / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let other = owner[ny * width + nx]
                    if other >= 0, other != island.owner { votes[other, default: 0] += 1 }
                }
            }
            if let neighbor = votes.max(by: { $0.value < $1.value })?.key {
                island.pixels.forEach { owner[$0] = neighbor }
            }
        }
        return parts.indices.map { index in
            (0..<count).map { owner[$0] == index ? mask[$0] : 0 }
        }
    }

    /// Rellena el borde suave de los objetos con el color del fondo cercano (se extiende hacia dentro, píxel a píxel).
    private static func cleanEdges(_ pixels: inout [UInt8], covered: [Float], width: Int, height: Int) {
        let count = width * height
        var known = covered.map { $0 <= edgeThreshold }
        var pending = (0..<count).filter { !known[$0] && covered[$0] < holeThreshold }
        var pass = 0
        while !pending.isEmpty && pass < maxEdgePasses {
            var filled: [(Int, (Int, Int, Int))] = []
            var next: [Int] = []
            for p in pending {
                let x = p % width, y = p / width
                var r = 0, g = 0, b = 0, n = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let q = ny * width + nx
                    guard known[q] else { continue }
                    r += Int(pixels[q * 4]); g += Int(pixels[q * 4 + 1]); b += Int(pixels[q * 4 + 2]); n += 1
                }
                if n > 0 { filled.append((p, (r / n, g / n, b / n))) } else { next.append(p) }
            }
            for (p, color) in filled {
                pixels[p * 4] = UInt8(color.0); pixels[p * 4 + 1] = UInt8(color.1); pixels[p * 4 + 2] = UInt8(color.2)
                known[p] = true
            }
            pending = next
            pass += 1
        }
    }

    // MARK: Píxeles

    /// Capa de un sujeto: la foto con la silueta como transparencia, recortada a la zona visible (sin copiar
    /// antes la foto entera). `nil` si queda transparente del todo.
    private static func layer(from pixels: [UInt8], mask: [Float], width: Int, height: Int) -> PSDWriter.Layer? {
        func alpha(_ p: Int) -> UInt8 { UInt8((Float(pixels[p * 4 + 3]) * mask[p]).rounded()) }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] > 0 && alpha(y * width + x) > 0 {
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
            for x in 0..<w {
                let p = (minY + y) * width + minX + x, q = (y * w + x) * 4
                cropped[q] = pixels[p * 4]; cropped[q + 1] = pixels[p * 4 + 1]; cropped[q + 2] = pixels[p * 4 + 2]
                cropped[q + 3] = alpha(p)
            }
        }
        return PSDWriter.Layer(name: "", croppedRGBA: cropped, x: minX, y: minY, width: w, height: h)
    }

    /// RGBA sin premultiplicar (para poder cambiar la transparencia sin alterar el color).
    private static func rgba(_ image: CGImage) throws -> [UInt8] {
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
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Int(data[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { data[i + c] = UInt8(min(255, (Int(data[i + c]) * 255 + a / 2) / a)) }
        }
        return data
    }

    /// Lee la máscara de Vision (un número de 0 a 1 por píxel) y la lleva al tamaño de la imagen.
    private static func readMask(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let mw = CVPixelBufferGetWidth(buffer), mh = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [Float](repeating: 0, count: width * height) }
        let isFloat = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        var mask = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let my = min(mh - 1, y * mh / height)
            let row = base.advanced(by: my * rowBytes)
            for x in 0..<width {
                let mx = min(mw - 1, x * mw / width)
                let value: Float = isFloat ? row.load(fromByteOffset: mx * 4, as: Float.self)
                                           : Float(row.load(fromByteOffset: mx, as: UInt8.self)) / 255
                mask[y * width + x] = min(1, max(0, value))
            }
        }
        return mask
    }
}
