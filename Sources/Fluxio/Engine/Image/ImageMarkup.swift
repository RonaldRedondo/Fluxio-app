import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Anotar, añadir fondo y ocultar zonas
//
// Todo se guarda en coordenadas de la imagen de 0 a 1 (arriba a la izquierda = 0,0), así lo mismo vale para la
// vista previa (pequeña) y para la copia final (a tamaño completo). Se dibuja con AppKit en un contexto girado
// (y hacia abajo), igual en pantalla que al guardar.

/// Lo elegido en las ventanas viaja al motor con un número (los parámetros de las herramientas solo admiten números).
final class ToolPayloadStore: @unchecked Sendable {
    static let shared = ToolPayloadStore()
    private var pending: [Int: Any] = [:]
    private var next = 1
    private let lock = NSLock()

    func put(_ payload: Any) -> Double {
        lock.lock(); defer { lock.unlock() }
        let token = next; next += 1
        pending[token] = payload
        return Double(token)
    }

    func take<T>(_ token: Double?, as type: T.Type) -> T? {
        guard let token else { return nil }
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: Int(token)) as? T
    }
}

/// Colores para anotar y para tapar.
enum MarkupPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),   // rojo
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),   // naranja
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),   // amarillo
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),   // verde
        NSColor(srgbRed: 0.00, green: 0.75, blue: 1.00, alpha: 1),   // cian de Fluxio
        NSColor(srgbRed: 0.48, green: 0.36, blue: 1.00, alpha: 1),   // violeta de Fluxio
        NSColor.white,
        NSColor.black,
    ]
}

// MARK: Anotaciones

struct Annotation: Identifiable {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case rectangle(CGPoint, CGPoint)
        case ellipse(CGPoint, CGPoint)
        case pen([CGPoint])
        case highlight([CGPoint])
        case text(CGPoint, String)
        case number(CGPoint, Int)
        /// Lupa: centro, radio (fracción del lado mayor) y aumento.
        case magnifier(CGPoint, CGFloat, CGFloat)
        /// Imagen pegada: centro y ancho (fracción del ancho).
        case image(CGPoint, CGFloat, NSImage)
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    /// Grosor (milésimas del lado mayor de la imagen); el texto y los números se escalan con él.
    var size: CGFloat = 5

    /// Mueve toda la anotación.
    mutating func move(by d: CGVector) {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        switch kind {
        case .arrow(let a, let b): kind = .arrow(m(a), m(b))
        case .rectangle(let a, let b): kind = .rectangle(m(a), m(b))
        case .ellipse(let a, let b): kind = .ellipse(m(a), m(b))
        case .pen(let ps): kind = .pen(ps.map(m))
        case .highlight(let ps): kind = .highlight(ps.map(m))
        case .text(let p, let s): kind = .text(m(p), s)
        case .number(let p, let n): kind = .number(m(p), n)
        case .magnifier(let p, let r, let z): kind = .magnifier(m(p), r, z)
        case .image(let p, let w, let i): kind = .image(m(p), w, i)
        }
    }
}

/// Dibuja sobre una imagen ya colocada en `rect` (coordenadas con y hacia abajo).
enum MarkupRenderer {
    /// Unidad de grosor: una milésima del lado mayor de la imagen en pantalla.
    static func unit(_ rect: CGRect) -> CGFloat { max(rect.width, rect.height) / 1000 }

    static func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    static func box(_ a: CGPoint, _ b: CGPoint, in rect: CGRect) -> CGRect {
        let p = point(a, in: rect), q = point(b, in: rect)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }

    /// Zona que ocupa una anotación en pantalla (para seleccionarla).
    static func bounds(of a: Annotation, in rect: CGRect, image: CGImage) -> CGRect {
        let u = unit(rect)
        switch a.kind {
        case .arrow(let s, let e), .rectangle(let s, let e), .ellipse(let s, let e):
            return box(s, e, in: rect).insetBy(dx: -a.size * u * 2, dy: -a.size * u * 2)
        case .pen(let ps), .highlight(let ps):
            let pts = ps.map { point($0, in: rect) }
            guard let first = pts.first else { return .null }
            return pts.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -a.size * u * 3, dy: -a.size * u * 3)
        case .text(let p, let s):
            let size = textAttributes(a, unit: u).map { NSAttributedString(string: s.isEmpty ? " " : s, attributes: $0).size() } ?? .zero
            return CGRect(origin: point(p, in: rect), size: size).insetBy(dx: -4, dy: -4)
        case .number(let p, _):
            let r = numberRadius(a, unit: u)
            let c = point(p, in: rect)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .magnifier(let p, let radius, _):
            let r = radius * max(rect.width, rect.height)
            let c = point(p, in: rect)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .image(let p, let w, let img):
            let width = w * rect.width
            let height = img.size.width > 0 ? width * img.size.height / img.size.width : width
            let c = point(p, in: rect)
            return CGRect(x: c.x - width / 2, y: c.y - height / 2, width: width, height: height)
        }
    }

    private static func textAttributes(_ a: Annotation, unit u: CGFloat) -> [NSAttributedString.Key: Any]? {
        let font = NSFont.systemFont(ofSize: max(8, a.size * u * 7), weight: .bold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = max(1, a.size * u * 0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -max(0.5, a.size * u * 0.2))
        return [.font: font, .foregroundColor: a.color, .shadow: shadow]
    }

    private static func numberRadius(_ a: Annotation, unit u: CGFloat) -> CGFloat { max(8, a.size * u * 4) }

    /// Dibuja todas las anotaciones. `image` hace falta para la lupa.
    static func draw(_ annotations: [Annotation], image: CGImage, in rect: CGRect) {
        let u = unit(rect)
        for a in annotations {
            let width = a.size * u
            a.color.setStroke(); a.color.setFill()
            switch a.kind {
            case .arrow(let s, let e):
                let p = point(s, in: rect), q = point(e, in: rect)
                let angle = atan2(q.y - p.y, q.x - p.x)
                let head = max(10, width * 4.5)
                let back = CGPoint(x: q.x - cos(angle) * head * 0.8, y: q.y - sin(angle) * head * 0.8)
                let line = NSBezierPath(); line.move(to: p); line.line(to: back)
                line.lineWidth = width; line.lineCapStyle = .round; line.stroke()
                let tip = NSBezierPath()
                tip.move(to: q)
                tip.line(to: CGPoint(x: q.x - cos(angle - 0.45) * head, y: q.y - sin(angle - 0.45) * head))
                tip.line(to: CGPoint(x: q.x - cos(angle + 0.45) * head, y: q.y - sin(angle + 0.45) * head))
                tip.close(); tip.fill()
            case .rectangle(let s, let e):
                let path = NSBezierPath(roundedRect: box(s, e, in: rect), xRadius: width, yRadius: width)
                path.lineWidth = width; path.stroke()
            case .ellipse(let s, let e):
                let path = NSBezierPath(ovalIn: box(s, e, in: rect))
                path.lineWidth = width; path.stroke()
            case .pen(let ps):
                stroke(ps, in: rect, width: width, color: a.color)
            case .highlight(let ps):
                stroke(ps, in: rect, width: width * 4, color: a.color.withAlphaComponent(0.4))
            case .text(let p, let s):
                guard let attrs = textAttributes(a, unit: u) else { continue }
                NSAttributedString(string: s, attributes: attrs).draw(at: point(p, in: rect))
            case .number(let p, let n):
                let r = numberRadius(a, unit: u)
                let c = point(p, in: rect)
                let circle = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                circle.fill()
                NSColor.white.withAlphaComponent(0.9).setStroke(); circle.lineWidth = max(1, r * 0.12); circle.stroke()
                let text = NSAttributedString(string: "\(n)", attributes: [
                    .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                    .foregroundColor: isLight(a.color) ? NSColor.black : NSColor.white])
                let size = text.size()
                text.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
            case .magnifier(let p, let radius, let zoom):
                let r = radius * max(rect.width, rect.height)
                let c = point(p, in: rect)
                let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: circle).addClip()
                // La imagen ampliada alrededor del centro de la lupa.
                let big = CGRect(x: c.x - (c.x - rect.minX) * zoom, y: c.y - (c.y - rect.minY) * zoom,
                                 width: rect.width * zoom, height: rect.height * zoom)
                drawImage(image, in: big)
                NSGraphicsContext.restoreGraphicsState()
                let ring = NSBezierPath(ovalIn: circle)
                ring.lineWidth = max(2, width); a.color.setStroke(); ring.stroke()
            case .image(_, _, let img):
                img.draw(in: bounds(of: a, in: rect, image: image), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            }
        }
    }

    private static func stroke(_ ps: [CGPoint], in rect: CGRect, width: CGFloat, color: NSColor) {
        guard let first = ps.first else { return }
        let path = NSBezierPath()
        path.move(to: point(first, in: rect))
        for p in ps.dropFirst() { path.line(to: point(p, in: rect)) }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
    }

    static func isLight(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.7
    }

    /// Dibuja una CGImage derecha en un contexto girado (y hacia abajo).
    static func drawImage(_ image: CGImage, in rect: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    /// Crea una imagen nueva de `size` píxeles dibujando con `body` (coordenadas con y hacia abajo).
    static func render(size: CGSize, colorSpace: CGColorSpace?, opaque: Bool = false,
                       _ body: () -> Void) -> CGImage? {
        let space = colorSpace?.supportsOutput == true ? colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// La copia anotada, a tamaño completo.
    static func annotated(_ image: CGImage, with annotations: [Annotation]) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        return render(size: size, colorSpace: image.colorSpace) {
            drawImage(image, in: CGRect(origin: .zero, size: size))
            draw(annotations, image: image, in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: Añadir fondo

struct BackgroundStyle {
    enum Fill {
        case gradient(Int)   // índice en `BackgroundStyle.gradients`
        case solid(Int)      // índice en `BackgroundStyle.solids`
        case image(CGImage)
    }
    enum Ratio: String, CaseIterable, Identifiable {
        case auto = "Auto", square = "1:1", wide = "16:9", portrait = "4:5", story = "9:16"
        var id: String { rawValue }
        var value: CGFloat? {
            switch self {
            case .auto: return nil
            case .square: return 1
            case .wide: return 16.0 / 9
            case .portrait: return 4.0 / 5
            case .story: return 9.0 / 16
            }
        }
    }

    var fill: Fill = .gradient(0)
    /// Margen alrededor de la foto, en % del lado mayor (0…30).
    var padding: Double = 10
    /// Esquinas de la foto, en % del lado menor (0…20).
    var corners: Double = 3
    /// Sombra (0…100).
    var shadow: Double = 40
    /// Desenfoque del fondo cuando es una imagen (0…100).
    var blur: Double = 30
    var ratio: Ratio = .auto

    static let gradients: [[NSColor]] = [
        [NSColor(srgbRed: 0.00, green: 0.75, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.48, green: 0.36, blue: 1.00, alpha: 1)],  // Fluxio
        [NSColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1), NSColor(srgbRed: 1.00, green: 0.80, blue: 0.35, alpha: 1)],  // atardecer
        [NSColor(srgbRed: 0.06, green: 0.36, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.33, green: 0.88, blue: 0.86, alpha: 1)],  // océano
        [NSColor(srgbRed: 0.98, green: 0.72, blue: 0.78, alpha: 1), NSColor(srgbRed: 0.78, green: 0.70, blue: 0.98, alpha: 1)],  // melocotón
        [NSColor(srgbRed: 0.26, green: 0.82, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.83, green: 0.96, blue: 0.53, alpha: 1)],  // menta
        [NSColor(srgbRed: 0.05, green: 0.06, blue: 0.16, alpha: 1), NSColor(srgbRed: 0.27, green: 0.15, blue: 0.45, alpha: 1)],  // noche
        [NSColor(srgbRed: 0.98, green: 0.36, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1)],  // aurora
        [NSColor(srgbRed: 0.85, green: 0.86, blue: 0.89, alpha: 1), NSColor(srgbRed: 0.55, green: 0.57, blue: 0.62, alpha: 1)],  // gris
    ]
    static let solids: [NSColor] = [
        .white, NSColor(srgbRed: 0.027, green: 0.031, blue: 0.039, alpha: 1), NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.84, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.55, green: 0.80, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.33, green: 0.62, blue: 0.56, alpha: 1), NSColor(srgbRed: 0.50, green: 0.80, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.28, green: 0.40, blue: 0.90, alpha: 1), NSColor(srgbRed: 0.44, green: 0.30, blue: 0.80, alpha: 1),
    ]

    /// Tamaño del lienzo final para una foto de `size`.
    func canvasSize(for size: CGSize) -> CGSize {
        let pad = CGFloat(padding / 100) * max(size.width, size.height)
        var canvas = CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        if let r = ratio.value {
            if canvas.width / canvas.height < r { canvas.width = canvas.height * r } else { canvas.height = canvas.width / r }
        }
        return CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
    }

    /// La foto sobre el fondo, del tamaño que haga falta.
    func render(_ image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let canvas = canvasSize(for: size)
        return MarkupRenderer.render(size: canvas, colorSpace: image.colorSpace, opaque: true) {
            let full = CGRect(origin: .zero, size: canvas)
            switch fill {
            case .gradient(let i):
                let colors = Self.gradients[min(i, Self.gradients.count - 1)]
                NSGradient(colors: colors)?.draw(in: full, angle: -45)
            case .solid(let i):
                Self.solids[min(i, Self.solids.count - 1)].setFill(); full.fill()
            case .image(let bg):
                MarkupRenderer.drawImage(Self.blurred(bg, amount: blur, toFill: canvas), in: full)
            }
            let photo = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                               width: size.width, height: size.height)
            let radius = CGFloat(corners / 100) * min(size.width, size.height)
            let clip = NSBezierPath(roundedRect: photo, xRadius: radius, yRadius: radius)
            if shadow > 0 {
                NSGraphicsContext.saveGraphicsState()
                let s = NSShadow()
                s.shadowColor = NSColor.black.withAlphaComponent(0.15 + CGFloat(shadow / 100) * 0.35)
                s.shadowBlurRadius = CGFloat(shadow / 100) * max(size.width, size.height) * 0.05
                s.shadowOffset = NSSize(width: 0, height: -s.shadowBlurRadius * 0.35)
                s.set()
                NSColor.black.setFill(); clip.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            MarkupRenderer.drawImage(image, in: photo)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Imagen de fondo: rellena el lienzo (recortando lo que sobre) y se desenfoca.
    static func blurred(_ image: CGImage, amount: Double, toFill canvas: CGSize) -> CGImage {
        let scale = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        var ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        let crop = CGRect(x: (w - canvas.width) / 2, y: (h - canvas.height) / 2, width: canvas.width, height: canvas.height)
        if amount > 0 {
            ci = ci.clampedToExtent().applyingGaussianBlur(sigma: amount / 100 * Double(max(canvas.width, canvas.height)) * 0.03)
        }
        ci = ci.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        return PhotoRenderer.context.createCGImage(ci, from: CGRect(origin: .zero, size: canvas)) ?? image
    }
}

// MARK: Ocultar zonas

struct RedactionPlan {
    enum Style: String, CaseIterable, Identifiable {
        case solid = "Color sólido", blur = "Desenfoque"
        var id: String { rawValue }
    }
    /// Zonas en coordenadas de 0 a 1 (arriba a la izquierda = 0,0).
    var areas: [CGRect] = []
    var style: Style = .solid
    var color: NSColor = .black

    /// Desenfoque muy fuerte (para que no se pueda leer), proporcional al tamaño de la imagen.
    static func blurredCopy(of image: CGImage) -> CGImage {
        let ci = CIImage(cgImage: image)
        let sigma = Double(max(image.width, image.height)) * 0.02
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ci.extent)
        return PhotoRenderer.context.createCGImage(out, from: ci.extent) ?? image
    }

    /// Dibuja las zonas sobre una imagen colocada en `rect`. `blurred` es la misma imagen ya desenfocada.
    func draw(over rect: CGRect, blurred: CGImage?) {
        for area in areas {
            let box = CGRect(x: rect.minX + area.minX * rect.width, y: rect.minY + area.minY * rect.height,
                             width: area.width * rect.width, height: area.height * rect.height)
            switch style {
            case .solid:
                color.setFill(); box.fill()
            case .blur:
                guard let blurred else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: box).addClip()
                MarkupRenderer.drawImage(blurred, in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    func apply(to image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let blurred = style == .blur ? Self.blurredCopy(of: image) : nil
        return MarkupRenderer.render(size: size, colorSpace: image.colorSpace) {
            let full = CGRect(origin: .zero, size: size)
            MarkupRenderer.drawImage(image, in: full)
            draw(over: full, blurred: blurred)
        }
    }

    /// Caras o textos encontrados por macOS, sin internet. Devuelve zonas de 0 a 1 (arriba a la izquierda).
    static func detect(faces: Bool, in image: CGImage) -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var boxes: [CGRect] = []
        if faces {
            let request = VNDetectFaceRectanglesRequest()
            try? handler.perform([request])
            boxes = (request.results ?? []).map(\.boundingBox)
        } else {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            try? handler.perform([request])
            boxes = (request.results ?? []).map(\.boundingBox)
        }
        // Vision mide desde abajo a la izquierda; aquí se usa arriba a la izquierda. Un poco de margen alrededor.
        return boxes.map { b in
            let pad = faces ? 0.15 : 0.06
            let dx = b.width * pad, dy = b.height * pad
            return CGRect(x: b.minX - dx, y: 1 - b.maxY - dy, width: b.width + 2 * dx, height: b.height + 2 * dy)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
