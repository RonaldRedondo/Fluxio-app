import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Miniaturas reales de los archivos (como en Finder), pedidas a macOS y guardadas para no repetirlas.
@MainActor
final class FileThumbnails: ObservableObject {
    @Published private(set) var images: [NSImage] = []
    private var urls: [URL] = []
    private static let cache = NSCache<NSURL, NSImage>()

    /// Pide las miniaturas de los primeros archivos; mientras llegan se ve el icono del archivo.
    func load(_ files: [URL], side: CGFloat) {
        let wanted = Array(files.prefix(DesignTokens.Wheel.thumbStackMax))
        guard wanted != urls else { return }
        urls = wanted
        images = wanted.map { Self.cache.object(forKey: $0 as NSURL) ?? NSWorkspace.shared.icon(forFile: $0.path) }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for (index, url) in wanted.enumerated() where Self.cache.object(forKey: url as NSURL) == nil {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                guard let image = rep?.nsImage else { return }
                DispatchQueue.main.async {
                    Self.cache.setObject(image, forKey: url as NSURL)
                    guard let self, self.urls.indices.contains(index), self.urls[index] == url else { return }
                    self.images[index] = image
                }
            }
        }
    }
}

/// El archivo que arrastras, flotando en el centro de la rueda: sube y baja despacio, se balancea un poco
/// y se inclina hacia la opción resaltada. Con varios archivos se ve un montoncito con el número.
struct FloatingFileStack: View {
    let files: [URL]
    /// Ángulo (en grados) de la opción resaltada, si hay una.
    let leanAngle: Double?
    let side: CGFloat
    /// En el estante flotante se queda quieto (así no gasta nada mientras está abierto).
    var floats = true

    @StateObject private var thumbs = FileThumbnails()
    private typealias W = DesignTokens.Wheel
    private typealias M = DesignTokens.Motion

    var body: some View {
        Group {
            if M.reduceMotion || !floats {
                stack(rise: 0, sway: 0)
            } else {
                // Solo se anima mientras la rueda está en pantalla.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = t / M.floatCycle * 2 * .pi
                    stack(rise: sin(phase), sway: sin(phase * 0.5 + 0.8))
                }
            }
        }
        .offset(lean)
        .animation(M.floatLean, value: leanAngle)
        .onAppear { thumbs.load(files, side: side) }
        .onChange(of: files) { thumbs.load($0, side: side) }
        .accessibilityHidden(true)
    }

    /// Se desplaza un poco hacia la opción resaltada.
    private var lean: CGSize {
        guard let angle = leanAngle, !M.reduceMotion else { return .zero }
        let rad = angle * .pi / 180
        return CGSize(width: cos(rad) * M.floatLeanDistance, height: sin(rad) * M.floatLeanDistance)
    }

    /// Tamaño con el que se ve la miniatura de delante (una foto apaisada es más baja que ancha).
    private var frontSize: CGSize {
        guard let size = thumbs.images.first?.size, size.width > 0, size.height > 0 else { return CGSize(width: side, height: side) }
        let k = min(side / size.width, side / size.height)
        return CGSize(width: size.width * k, height: size.height * k)
    }

    /// `rise` y `sway` van de -1 a 1.
    private func stack(rise: Double, sway: Double) -> some View {
        let lift = CGFloat(rise) * M.floatRise
        let front = frontSize
        return ZStack {
            // Sombra en el "suelo": más pequeña y suave cuanto más sube el archivo.
            Ellipse()
                .fill(Color.black.opacity(0.28 - 0.08 * rise))
                .frame(width: front.width * (0.8 - 0.08 * CGFloat(rise)), height: side * 0.12)
                .blur(radius: 3 + 1.5 * CGFloat(rise))
                .offset(y: front.height / 2 + 4)

            ZStack {
                ForEach(Array(thumbs.images.enumerated().reversed()), id: \.offset) { index, image in
                    thumbnail(image)
                        .rotationEffect(.degrees(W.thumbStackAngles[index]))
                        .offset(x: CGFloat(index) * 4, y: CGFloat(index) * -2)
                }
            }
            .rotationEffect(.degrees(sway * M.floatTilt + leanTilt))
            .offset(y: -lift)
            .overlay(alignment: .topTrailing) {
                if files.count > 1 {
                    Text("\(files.count)")
                        .textStyle(DesignTokens.Typography.wheelHint)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.onAccent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(DesignTokens.Colors.accentGradient))
                        // En la esquina de la miniatura de delante.
                        .offset(x: 9 - (side - front.width) / 2, y: -9 + (side - front.height) / 2 - lift)
                }
            }
        }
        .frame(width: side, height: side)
    }

    /// Se ladea hacia el lado de la opción resaltada.
    private var leanTilt: Double {
        guard let angle = leanAngle, !M.reduceMotion else { return 0 }
        return cos(angle * .pi / 180) * M.floatLeanTilt
    }

    private func thumbnail(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            // Se redondea la foto en sí (no el cuadro donde cabe), para que una foto apaisada también tenga esquinas redondas.
            .clipShape(RoundedRectangle(cornerRadius: W.thumbCorner, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .frame(maxWidth: side, maxHeight: side)
    }
}
