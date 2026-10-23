import SwiftUI
import AVKit

/// Estado de la ventana para cortar audio o video.
@MainActor
final class TrimModel: ObservableObject {
    let player: AVPlayer
    let isVideo: Bool
    let duration: Double
    @Published var start: Double = 0 {
        didSet {
            if start > end - 0.1 { start = max(0, end - 0.1) }
            seek(to: start)
        }
    }
    @Published var end: Double {
        didSet {
            if end < start + 0.1 { end = min(duration, start + 0.1) }
            seek(to: end)
        }
    }
    @Published var current: Double = 0
    /// Miniaturas de fotogramas para la línea de tiempo (solo video).
    @Published var thumbnails: [NSImage] = []
    private var observer: Any?
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var previewing = false

    init(url: URL, isVideo: Bool) {
        player = AVPlayer(url: url)
        self.isVideo = isVideo
        // ffprobe entiende más formatos que AVFoundation (MKV, WebM, OGG…).
        let probed = MediaProbe.read(url).duration
        duration = probed > 0 ? probed : 0
        end = duration
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                  queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds
                // "Probar corte": parar al llegar al final de la selección.
                if self.previewing && time.seconds >= self.end {
                    self.player.pause()
                    self.previewing = false
                }
            }
        }
        if isVideo { loadThumbnails(url: url) }
    }

    /// Saca ~12 fotogramas repartidos por el video (AVFoundation; MKV/WebM se quedan sin miniaturas).
    private func loadThumbnails(url: URL, count: Int = 12) {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        thumbnailGenerator = generator
        let times = (0..<count).map {
            NSValue(time: CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600))
        }
        let moments = times.map(\.timeValue)   // CMTime se puede usar desde otro hilo; NSValue no
        var images = [NSImage?](repeating: nil, count: count)
        var received = 0
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, _, _ in
            let index = moments.firstIndex(of: requested) ?? 0
            let nsImage = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            DispatchQueue.main.async {
                images[index] = nsImage
                received += 1
                if received == count { self?.thumbnails = images.compactMap { $0 } }
            }
        }
    }

    func stop() {
        thumbnailGenerator?.cancelAllCGImageGeneration()
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    private func seek(to seconds: Double) {
        guard !previewing else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func previewSelection() {
        previewing = false
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor in
                self?.previewing = true
                self?.player.play()
            }
        }
    }

    /// Clic o arrastre sobre la línea de tiempo: mueve la posición de reproducción.
    func scrub(to seconds: Double) {
        player.pause()
        previewing = false
        current = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: current, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStartToCurrent() { player.pause(); previewing = false; start = min(current, end - 0.1) }
    func setEndToCurrent() { player.pause(); previewing = false; end = max(current, start + 0.1) }

    var parameters: [String: Double] { ["start": start, "end": end] }

    static func format(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        let rest = s - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

/// Ventana para cortar audio o video.
struct TrimEditorView: View {
    @ObservedObject var model: TrimModel
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            PlayerView(player: model.player)
                .frame(minHeight: model.isVideo ? DesignTokens.Editor.videoMinHeight : DesignTokens.Editor.audioHeight,
                       maxHeight: model.isVideo ? .infinity : DesignTokens.Editor.audioHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.button))
                .accessibilityLabel("Vista previa")

            if model.duration <= 0 {
                Text("No pude leer la duración de este archivo.")
                    .foregroundStyle(DesignTokens.Colors.error)
            } else {
                TrimTimeline(model: model)

                // Tiempos bajo la línea: inicio a la izquierda, duración en el centro, fin a la derecha.
                HStack {
                    timeLabel("Inicio", model.start)
                    Spacer()
                    Text("Duración del corte: \(TrimModel.format(model.end - model.start))")
                        .font(DesignTokens.Typography.caption.font.monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    timeLabel("Fin", model.end)
                }

                HStack {
                    Button("Marcar inicio aquí", action: model.setStartToCurrent)
                        .buttonStyle(.fluxioSecondary)
                        .help("Lleva el asa de inicio a la posición actual del reproductor")
                    Spacer()
                    Button {
                        model.previewSelection()
                    } label: {
                        Label("Probar corte", systemImage: "play.fill")
                    }
                    .buttonStyle(.fluxioSecondary)
                    Spacer()
                    Button("Marcar fin aquí", action: model.setEndToCurrent)
                        .buttonStyle(.fluxioSecondary)
                        .help("Lleva el asa de fin a la posición actual del reproductor")
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(.fluxioSecondary)
                Button("Cortar", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.fluxioPrimary)
                    .disabled(model.duration <= 0)
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(minWidth: DesignTokens.Timeline.editorMinWidth)
        .fluxioTheme()
    }

    private func timeLabel(_ title: String, _ value: Double) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title).foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(TrimModel.format(value))
                .foregroundStyle(title == "Inicio" ? DesignTokens.Colors.accent : DesignTokens.Colors.accentEnd)
                .fontWeight(.semibold)
        }
        .font(DesignTokens.Typography.body.font.monospacedDigit())
    }
}

/// Una sola línea de tiempo con dos asas (inicio y fin), como en Fotos o QuickTime.
/// - Arrastra un asa para mover el inicio o el fin.
/// - Haz clic o arrastra en la línea para mover la posición de reproducción (línea blanca).
struct TrimTimeline: View {
    @ObservedObject var model: TrimModel

    private let height = DesignTokens.Timeline.height
    private let handleWidth = DesignTokens.Timeline.handleWidth

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - handleWidth * 2)
            // Segundos → posición horizontal (las asas quedan por fuera de la zona elegida).
            let x = { (t: Double) -> CGFloat in handleWidth + CGFloat(t / model.duration) * usable }
            let time = { (px: CGFloat) -> Double in Double((px - handleWidth) / usable) * model.duration }
            let startX = x(model.start), endX = x(model.end)

            ZStack(alignment: .topLeading) {
                // Pista: miniaturas del video o barra lisa para audio.
                track
                    .frame(width: usable, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail))
                    .position(x: handleWidth + usable / 2, y: height / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { model.scrub(to: time($0.location.x)) })
                    .accessibilityHidden(true)

                // Fuera de la selección: oscurecido.
                Rectangle().fill(DesignTokens.Colors.scrim)
                    .frame(width: max(0, startX - handleWidth), height: height)
                    .position(x: (handleWidth + startX) / 2, y: height / 2)
                    .allowsHitTesting(false)
                Rectangle().fill(DesignTokens.Colors.scrim)
                    .frame(width: max(0, handleWidth + usable - endX), height: height)
                    .position(x: (endX + handleWidth + usable) / 2, y: height / 2)
                    .allowsHitTesting(false)

                // Marco de la selección (bordes arriba y abajo).
                Rectangle()
                    .strokeBorder(DesignTokens.Colors.accentGradientHorizontal, lineWidth: DesignTokens.Timeline.borderWidth)
                    .frame(width: endX - startX + handleWidth * 2, height: height)
                    .position(x: (startX + endX) / 2, y: height / 2)
                    .allowsHitTesting(false)

                // Posición de reproducción.
                Capsule()
                    .fill(DesignTokens.Colors.playhead)
                    .shadow(color: DesignTokens.Colors.scrimStrong, radius: DesignTokens.Stroke.hairline)
                    .frame(width: DesignTokens.Timeline.playheadWidth,
                           height: height + DesignTokens.Timeline.playheadOverhang)
                    .position(x: x(model.current), y: height / 2)
                    .allowsHitTesting(false)

                handle(isStart: true, at: startX - handleWidth / 2, time: time)
                handle(isStart: false, at: endX + handleWidth / 2, time: time)
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: height)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private var track: some View {
        if model.thumbnails.isEmpty {
            Rectangle().fill(DesignTokens.Colors.timelineTrack)
                .overlay(Image(systemName: "waveform").font(.system(size: DesignTokens.IconSize.medium)).foregroundStyle(.secondary))
        } else {
            HStack(spacing: 0) {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
    }

    private func handle(isStart: Bool, at centerX: CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        ZStack {
            // Inicio en cian y fin en violeta: los dos extremos del degradado.
            UnevenRoundedHandle(isStart: isStart)
                .fill(isStart ? DesignTokens.Colors.accent : DesignTokens.Colors.accentEnd)
            Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: DesignTokens.IconSize.small, weight: .bold))
                .foregroundStyle(DesignTokens.Colors.onAccent)
        }
        .frame(width: handleWidth, height: height)
        .contentShape(Rectangle().inset(by: -DesignTokens.Editor.handleHitInset))
        .position(x: centerX, y: height / 2)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                // El asa se arrastra por su borde interior (el que toca la selección).
                let edge = value.location.x + (isStart ? handleWidth / 2 : -handleWidth / 2)
                let t = min(max(0, time(edge)), model.duration)
                if isStart { model.start = t } else { model.end = t }
                model.current = t
            })
        .accessibilityElement()
        .accessibilityLabel(isStart ? "Inicio del corte" : "Fin del corte")
        .accessibilityValue(TrimModel.format(isStart ? model.start : model.end))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.5 : -0.5
            if isStart { model.start = max(0, model.start + step) } else { model.end = min(model.duration, model.end + step) }
        }
    }
}

/// Asa con las esquinas exteriores redondeadas (izquierda para el inicio, derecha para el fin).
struct UnevenRoundedHandle: Shape {
    let isStart: Bool

    func path(in rect: CGRect) -> Path {
        let r = DesignTokens.Timeline.handleRadius
        var p = Path()
        if isStart {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY + r), radius: r)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + r, y: rect.maxY), radius: r)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// Reproductor nativo de macOS.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
