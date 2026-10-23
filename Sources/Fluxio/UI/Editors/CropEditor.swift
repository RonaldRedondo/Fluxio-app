import AVFoundation
import SwiftUI
import ImageIO

/// Proporciones de recorte disponibles.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9, r9x16, r4x5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Libre"
        case .original: return "Original"
        case .square: return "1:1"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        case .r4x5: return "4:5"
        }
    }

    /// Ancho ÷ alto, en píxeles (`nil` = libre).
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.width / original.height
        case .square: return 1
        case .r4x3: return 4 / 3
        case .r3x2: return 3 / 2
        case .r16x9: return 16 / 9
        case .r9x16: return 9 / 16
        case .r4x5: return 4 / 5
        }
    }
}

/// Estado de la ventana de recorte. El rectángulo va de 0 a 1 (desde arriba a la izquierda).
@MainActor
final class CropModel: ObservableObject {
    let preview: NSImage
    let pixelSize: CGSize
    @Published var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var aspect: CropAspect = .free { didSet { applyAspect() } }
    var dragStart: CGRect?

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary)
        else { return nil }
        // Orientaciones 5–8 = foto girada: ancho y alto se intercambian.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        pixelSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        preview = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
    }

    /// Recortar el encuadre de un video: se trabaja sobre un fotograma (al segundo 1 o a la mitad si es corto).
    init?(videoURL url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let duration = MediaProbe.read(url).duration
        let at = CMTime(seconds: min(1, max(0, duration / 2)), preferredTimescale: 600)
        guard let frame = try? generator.copyCGImage(at: at, actualTime: nil) else { return nil }
        let canvas = VideoCanvas.read(url)
        pixelSize = CGSize(width: canvas.width, height: canvas.height)
        preview = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }

    /// Proporción en unidades normalizadas (0…1), que dependen de la forma de la imagen.
    private var normalizedRatio: CGFloat? {
        aspect.ratio(original: pixelSize).map { $0 * pixelSize.height / pixelSize.width }
    }

    var pixelRectText: String {
        "\(Int((rect.width * pixelSize.width).rounded())) × \(Int((rect.height * pixelSize.height).rounded())) px"
    }

    func reset() {
        aspect = .free
        rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// El rectángulo más grande con la proporción elegida, centrado.
    private func applyAspect() {
        guard let r = normalizedRatio else { return }
        var w: CGFloat = 1, h = 1 / r
        if h > 1 { h = 1; w = r }
        rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Mover todo el marco.
    func move(by delta: CGSize) {
        let start = dragStart ?? rect
        dragStart = start
        let x = min(max(0, start.minX + delta.width), 1 - start.width)
        let y = min(max(0, start.minY + delta.height), 1 - start.height)
        rect.origin = CGPoint(x: x, y: y)
    }

    /// Arrastrar una esquina (0 = arriba izq., 1 = arriba der., 2 = abajo izq., 3 = abajo der.).
    func resize(corner: Int, by delta: CGSize) {
        let start = dragStart ?? rect
        dragStart = start
        let movingX = corner % 2 == 0 ? start.minX : start.maxX
        let movingY = corner < 2 ? start.minY : start.maxY
        let fixed = CGPoint(x: corner % 2 == 0 ? start.maxX : start.minX, y: corner < 2 ? start.maxY : start.minY)
        let signX: CGFloat = corner % 2 == 0 ? -1 : 1
        let signY: CGFloat = corner < 2 ? -1 : 1
        let minSize: CGFloat = 0.03

        let mx = min(max(0, movingX + delta.width), 1)
        let my = min(max(0, movingY + delta.height), 1)
        var w = max(minSize, (mx - fixed.x) * signX)
        var h = max(minSize, (my - fixed.y) * signY)

        if let r = normalizedRatio {
            h = w / r
            // Espacio disponible desde la esquina fija.
            let maxW = signX > 0 ? 1 - fixed.x : fixed.x
            let maxH = signY > 0 ? 1 - fixed.y : fixed.y
            if h > maxH { h = maxH; w = h * r }
            if w > maxW { w = maxW; h = w / r }
        } else {
            w = min(w, signX > 0 ? 1 - fixed.x : fixed.x)
            h = min(h, signY > 0 ? 1 - fixed.y : fixed.y)
        }
        rect = CGRect(x: signX > 0 ? fixed.x : fixed.x - w, y: signY > 0 ? fixed.y : fixed.y - h, width: w, height: h)
    }

    var parameters: [String: Double] {
        ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height]
    }
}

/// Ventana de recorte.
struct CropEditorView: View {
    @ObservedObject var model: CropModel
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            GeometryReader { geo in
                let fit = fittedSize(in: geo.size)
                canvas(size: fit)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .frame(minWidth: DesignTokens.Editor.cropCanvasMin.width, minHeight: DesignTokens.Editor.cropCanvasMin.height)

            HStack {
                Picker("Proporción", selection: $model.aspect) {
                    ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: DesignTokens.Editor.aspectPickerMaxWidth)
                Spacer()
                Text(model.pixelRectText)
                    .font(DesignTokens.Typography.caption.font.monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            HStack {
                Button("Restablecer") { model.reset() }
                    .buttonStyle(.fluxioGhost)
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(.fluxioSecondary)
                Button("Recortar", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.fluxioPrimary)
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(minWidth: DesignTokens.Editor.cropWindowMin.width, minHeight: DesignTokens.Editor.cropWindowMin.height)
        .fluxioTheme()
    }

    private func fittedSize(in space: CGSize) -> CGSize {
        let size = model.pixelSize
        let scale = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func canvas(size: CGSize) -> some View {
        let r = model.rect
        let crop = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                          width: r.width * size.width, height: r.height * size.height)
        let toNormalized = { (t: CGSize) in CGSize(width: t.width / size.width, height: t.height / size.height) }

        return ZStack(alignment: .topLeading) {
            Image(nsImage: model.preview)
                .resizable()
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)

            // Oscurece lo que queda fuera del recorte.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(crop)
            }
            .fill(DesignTokens.Colors.scrimStrong, style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Guías de tercios.
            Path { p in
                for i in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(i) / 3
                    let y = crop.minY + crop.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: crop.minY)); p.addLine(to: CGPoint(x: x, y: crop.maxY))
                    p.move(to: CGPoint(x: crop.minX, y: y)); p.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(DesignTokens.Colors.guide, lineWidth: DesignTokens.Editor.guideWidth)
            .allowsHitTesting(false)

            // Marco (se arrastra para mover).
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(DesignTokens.Colors.accentGradient, lineWidth: DesignTokens.Editor.frameWidth))
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { model.move(by: toNormalized($0.translation)) }
                    .onEnded { _ in model.dragStart = nil })
                .accessibilityElement()
                .accessibilityLabel("Zona de recorte, \(model.pixelRectText)")
                .accessibilityHint("Elige una proporción y pulsa Recortar")

            // Esquinas.
            ForEach(0..<4, id: \.self) { corner in
                let x = corner % 2 == 0 ? crop.minX : crop.maxX
                let y = corner < 2 ? crop.minY : crop.maxY
                Circle()
                    .fill(DesignTokens.Colors.playhead)
                    .overlay(Circle().stroke(DesignTokens.Colors.accent, lineWidth: DesignTokens.Editor.frameWidth))
                    .frame(width: DesignTokens.Editor.cornerHandle, height: DesignTokens.Editor.cornerHandle)
                    .frame(width: DesignTokens.Editor.cornerHitArea, height: DesignTokens.Editor.cornerHitArea)
                    .contentShape(Rectangle())
                    .position(x: x, y: y)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { model.resize(corner: corner, by: toNormalized($0.translation)) }
                        .onEnded { _ in model.dragStart = nil })
                    .accessibilityHidden(true)
            }
        }
    }
}
