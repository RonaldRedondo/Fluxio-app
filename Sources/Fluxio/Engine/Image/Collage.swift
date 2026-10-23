import AppKit

/// Collage: varias fotos en una sola imagen (cuadrícula, fila, columna o una destacada).
struct CollageLayout {
    enum Style: String, CaseIterable, Identifiable {
        case grid = "Cuadrícula", row = "Fila", column = "Columna", featured = "Destacada"
        var id: String { rawValue }
    }
    enum Canvas: String, CaseIterable, Identifiable {
        case square = "Cuadrado · 1:1", landscape = "Horizontal · 16:9", portrait = "Vertical · 4:5", story = "Historia · 9:16"
        var id: String { rawValue }
        /// Ancho dividido por alto.
        var ratio: CGFloat {
            switch self {
            case .square: return 1
            case .landscape: return 16.0 / 9
            case .portrait: return 4.0 / 5
            case .story: return 9.0 / 16
            }
        }
    }
    enum Fit: String, CaseIterable, Identifiable {
        case fill = "Rellenar (recorta bordes)", fit = "Foto entera"
        var id: String { rawValue }
    }

    var style: Style = .grid
    var columns = 2
    var canvas: Canvas = .square
    /// Ancho final en píxeles.
    var width: Int = 2048
    var fit: Fit = .fill
    /// Espacio entre fotos y en los bordes, en % del ancho (0…8).
    var spacing: Double = 1.5
    /// Esquinas de cada foto, en % del lado menor de la celda (0…20).
    var corners: Double = 0
    /// Índice en `BackgroundStyle.solids`.
    var background = 0

    static let widths = [1080, 2048, 3000, 4096]

    /// Columnas que de verdad se usan (no más que fotos).
    func effectiveColumns(_ count: Int) -> Int { max(1, min(columns, count)) }

    /// Las celdas en coordenadas con y hacia abajo, para un lienzo de `size`.
    func cells(count: Int, size: CGSize) -> [CGRect] {
        guard count > 0 else { return [] }
        let gap = CGFloat(spacing / 100) * size.width
        let area = CGRect(origin: .zero, size: size).insetBy(dx: gap, dy: gap)
        func grid(_ rect: CGRect, cols: Int, rows: Int, count: Int) -> [CGRect] {
            let w = (rect.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
            let h = (rect.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            return (0..<count).map { i in
                let r = i / cols, c = i % cols
                // La última fila, si está incompleta, se centra.
                let inRow = r == rows - 1 ? count - r * cols : cols
                let offset = CGFloat(cols - inRow) * (w + gap) / 2
                return CGRect(x: rect.minX + offset + CGFloat(c) * (w + gap), y: rect.minY + CGFloat(r) * (h + gap), width: w, height: h)
            }
        }
        switch style {
        case .grid:
            let cols = effectiveColumns(count)
            return grid(area, cols: cols, rows: Int(ceil(Double(count) / Double(cols))), count: count)
        case .row:
            return grid(area, cols: count, rows: 1, count: count)
        case .column:
            return grid(area, cols: 1, rows: count, count: count)
        case .featured:
            guard count > 1 else { return [area] }
            // La primera foto ocupa dos tercios; las demás, en columna al lado (o debajo si el lienzo es vertical).
            if size.width >= size.height {
                let big = CGRect(x: area.minX, y: area.minY, width: (area.width - gap) * 2 / 3, height: area.height)
                let side = CGRect(x: big.maxX + gap, y: area.minY, width: area.width - big.width - gap, height: area.height)
                return [big] + grid(side, cols: 1, rows: count - 1, count: count - 1)
            } else {
                let big = CGRect(x: area.minX, y: area.minY, width: area.width, height: (area.height - gap) * 2 / 3)
                let side = CGRect(x: area.minX, y: big.maxY + gap, width: area.width, height: area.height - big.height - gap)
                return [big] + grid(side, cols: count - 1, rows: 1, count: count - 1)
            }
        }
    }

    func canvasSize(width: Int) -> CGSize {
        CGSize(width: CGFloat(width), height: (CGFloat(width) / canvas.ratio).rounded())
    }

    /// Dibuja el collage con estas fotos, de `width` píxeles de ancho.
    func render(_ images: [CGImage], width: Int) -> CGImage? {
        let size = canvasSize(width: width)
        let rects = cells(count: images.count, size: size)
        return MarkupRenderer.render(size: size, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), opaque: true) {
            BackgroundStyle.solids[min(background, BackgroundStyle.solids.count - 1)].setFill()
            CGRect(origin: .zero, size: size).fill()
            for (image, cell) in zip(images, rects) {
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let scale = fit == .fill ? max(cell.width / iw, cell.height / ih) : min(cell.width / iw, cell.height / ih)
                let w = iw * scale, h = ih * scale
                let target = CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)
                let shape = fit == .fill ? cell : target
                let radius = CGFloat(corners / 100) * min(shape.width, shape.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).addClip()
                MarkupRenderer.drawImage(image, in: target)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

/// Lo que la ventana manda al motor: el diseño y las fotos en el orden elegido.
struct CollageRequest {
    var layout: CollageLayout
    var urls: [URL]
}
