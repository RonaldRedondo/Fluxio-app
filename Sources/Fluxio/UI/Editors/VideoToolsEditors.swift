import AVKit
import SwiftUI

// MARK: - Vista previa de video común (velocidad, fotogramas, dividir)

@MainActor
final class VideoPreviewModel: ObservableObject {
    let player: AVPlayer
    let duration: Double
    @Published var current: Double = 0
    @Published var isPlaying = false
    private var observer: Any?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        // Al cambiar la velocidad, la voz no se vuelve aguda ni grave.
        item.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: item)
        let probed = MediaProbe.read(url).duration
        duration = probed > 0 ? probed : 0
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.04, preferredTimescale: 600),
                                                  queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    func seek(_ seconds: Double) {
        player.pause()
        current = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: current, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Avanza o retrocede un fotograma exacto.
    func step(_ frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }

    func togglePlay(rate: Float = 1) {
        if player.rate != 0 { player.pause(); return }
        if current >= duration - 0.05 { player.seek(to: .zero) }
        player.playImmediately(atRate: rate)
    }

    static func format(_ seconds: Double, decimals: Bool = true) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        return decimals ? String(format: "%d:%05.2f", m, s - Double(m * 60)) : String(format: "%d:%02d", m, Int(s) % 60)
    }
}

/// Reproductor sin controles (los ponemos nosotros) con la barra de posición debajo.
struct VideoPreviewPane: View {
    @ObservedObject var video: VideoPreviewModel
    var rate: Float = 1
    /// Marcas sobre la barra (cortes, fotogramas elegidos).
    var marks: [Double] = []

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            BarePlayerView(player: video.player)
                .frame(width: DesignTokens.VideoTools.previewSize.width, height: DesignTokens.VideoTools.previewSize.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            ZStack(alignment: .leading) {
                Slider(value: Binding(get: { video.current }, set: { video.seek($0) }), in: 0...max(0.01, video.duration))
                    .controlSize(.small)
                    .accessibilityLabel("Posición")
                GeometryReader { geo in
                    ForEach(marks.indices, id: \.self) { i in
                        Capsule().fill(DesignTokens.Colors.accentGradient)
                            .frame(width: 3, height: 14)
                            .position(x: geo.size.width * CGFloat(marks[i] / max(0.01, video.duration)), y: geo.size.height / 2)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(height: 20)
            HStack(spacing: DesignTokens.Spacing.s) {
                Button { video.step(-1) } label: { Image(systemName: "backward.frame") }
                    .buttonStyle(.fluxioSecondary).help("Fotograma anterior").accessibilityLabel("Fotograma anterior")
                Button { video.togglePlay(rate: rate) } label: { Image(systemName: video.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(.fluxioSecondary).keyboardShortcut(.space, modifiers: [])
                    .accessibilityLabel(video.isPlaying ? "Pausa" : "Reproducir")
                Button { video.step(1) } label: { Image(systemName: "forward.frame") }
                    .buttonStyle(.fluxioSecondary).help("Fotograma siguiente").accessibilityLabel("Fotograma siguiente")
                Spacer()
                Text("\(VideoPreviewModel.format(video.current)) / \(VideoPreviewModel.format(video.duration))")
                    .font(DesignTokens.Typography.caption.font.monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
    }
}

struct BarePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

// MARK: - Velocidad

@MainActor
final class SpeedModel: ObservableObject {
    let video: VideoPreviewModel
    @Published var speed: Double = 1 {
        didSet { if video.player.rate != 0 { video.player.rate = Float(speed) } }
    }
    static let stops: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    init(url: URL) { video = VideoPreviewModel(url: url) }

    /// El control va por posiciones (cada una, una velocidad de la lista).
    var stopIndex: Double {
        get { Double(Self.stops.firstIndex(of: speed) ?? 3) }
        set { speed = Self.stops[min(Self.stops.count - 1, max(0, Int(newValue.rounded())))] }
    }

    static func label(_ s: Double) -> String {
        s == s.rounded() ? String(format: "%.0f×", s) : String(format: "%g×", s)
    }
}

struct SpeedEditorView: View {
    @ObservedObject var model: SpeedModel
    var title = "Cambiar velocidad"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                VideoPreviewPane(video: model.video, rate: Float(model.speed))
                HStack {
                    Text("Velocidad").textStyle(DesignTokens.Typography.label)
                    Spacer()
                    Text(SpeedModel.label(model.speed))
                        .textStyle(DesignTokens.Typography.headline)
                        .foregroundStyle(DesignTokens.Colors.accentGradient)
                        .contentTransition(.numericText())
                        .animation(DesignTokens.Motion.digits, value: model.speed)
                }
                Slider(value: Binding(get: { model.stopIndex }, set: { model.stopIndex = $0 }),
                       in: 0...Double(SpeedModel.stops.count - 1), step: 1)
                    .accessibilityLabel("Velocidad").accessibilityValue(SpeedModel.label(model.speed))
                HStack {
                    ForEach(SpeedModel.stops, id: \.self) { s in
                        Button(SpeedModel.label(s)) { model.speed = s }
                            .buttonStyle(.plain)
                            .textStyle(DesignTokens.Typography.caption)
                            .foregroundStyle(s == model.speed ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary)
                        if s != SpeedModel.stops.last { Spacer() }
                    }
                }
                Text(model.speed == 1 ? "Elige una velocidad distinta de 1×. La voz conserva su tono."
                     : "Duración final: \(VideoPreviewModel.format(model.video.duration / model.speed, decimals: false)). La voz conserva su tono.")
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .frame(width: DesignTokens.VideoTools.previewSize.width)
        } footer: {
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Aplicar", action: onConfirm).keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary)
                .disabled(model.speed == 1)
        }
    }
}

// MARK: - Fotogramas

@MainActor
final class FramesModel: ObservableObject {
    struct Frame: Identifiable, Equatable { let id = UUID(); let time: Double; let image: NSImage? }
    let video: VideoPreviewModel
    @Published var frames: [Frame] = []
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        video = VideoPreviewModel(url: url)
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    func addCurrent() {
        let t = video.current
        guard !frames.contains(where: { abs($0.time - t) < 0.01 }) else { return }
        let image = (try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil))
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        withAnimation(DesignTokens.Motion.toast) {
            frames.append(Frame(time: t, image: image))
            frames.sort { $0.time < $1.time }
        }
    }

    func remove(_ f: Frame) { withAnimation(DesignTokens.Motion.toast) { frames.removeAll { $0 == f } } }

    var parameters: [String: Double] {
        var p: [String: Double] = ["count": Double(frames.count)]
        for (i, f) in frames.enumerated() { p["t\(i)"] = f.time }
        return p
    }
}

struct FramesEditorView: View {
    @ObservedObject var model: FramesModel
    var title = "Guardar fotogramas"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias VT = DesignTokens.VideoTools

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                VideoPreviewPane(video: model.video, marks: model.frames.map(\.time))
                HStack {
                    Text(model.frames.isEmpty ? "Ningún fotograma elegido" : "\(model.frames.count) elegido(s)")
                        .textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Button { model.addCurrent() } label: { Label("Añadir fotograma", systemImage: "plus") }
                        .buttonStyle(.fluxioSecondary)
                        .keyboardShortcut("a", modifiers: [])
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.Spacing.s) {
                        ForEach(model.frames) { f in chip(f).transition(.blurScale) }
                    }
                }
                .frame(height: VT.frameChip.height)
            }
            .frame(width: VT.previewSize.width)
        } footer: {
            Text("Se guardan en PNG a tamaño completo.")
                .textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button(model.frames.count == 1 ? "Guardar 1 fotograma" : "Guardar \(model.frames.count) fotogramas", action: onConfirm)
                .keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary).disabled(model.frames.isEmpty)
        }
    }

    private func chip(_ f: FramesModel.Frame) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = f.image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { Color.black }
            }
            .frame(width: VT.frameChip.width, height: VT.frameChip.height)
            .clipped()
            Text(VideoPreviewModel.format(f.time))
                .font(DesignTokens.Typography.caption.font.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button { model.remove(f) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain).padding(3)
            .accessibilityLabel("Quitar el fotograma de \(VideoPreviewModel.format(f.time))")
        }
        .onTapGesture { model.video.seek(f.time) }
    }
}

// MARK: - Dividir

@MainActor
final class SplitModel: ObservableObject {
    let video: VideoPreviewModel
    @Published var cuts: [Double] = []
    @Published var equalParts = 2

    init(url: URL) { video = VideoPreviewModel(url: url) }

    func addCut() {
        let t = video.current
        guard t > 0.2, t < video.duration - 0.2, !cuts.contains(where: { abs($0 - t) < 0.2 }) else { return }
        withAnimation(DesignTokens.Motion.toast) { cuts.append(t); cuts.sort() }
    }

    func remove(_ t: Double) { withAnimation(DesignTokens.Motion.toast) { cuts.removeAll { $0 == t } } }

    func applyEqualParts() {
        let n = max(2, equalParts)
        withAnimation(DesignTokens.Motion.toast) { cuts = (1..<n).map { video.duration * Double($0) / Double(n) } }
    }

    /// Las partes resultantes (inicio, fin).
    var parts: [(Double, Double)] {
        let edges = [0] + cuts + [video.duration]
        return zip(edges, edges.dropFirst()).map { ($0, $1) }
    }

    var parameters: [String: Double] {
        var p: [String: Double] = ["count": Double(cuts.count)]
        for (i, c) in cuts.enumerated() { p["c\(i)"] = c }
        return p
    }
}

struct SplitEditorView: View {
    @ObservedObject var model: SplitModel
    var title = "Dividir video"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                VideoPreviewPane(video: model.video, marks: model.cuts)
                HStack(spacing: DesignTokens.Spacing.s) {
                    Button { model.addCut() } label: { Label("Cortar aquí", systemImage: "scissors") }
                        .buttonStyle(.fluxioSecondary)
                    Spacer()
                    Text("Partes iguales").textStyle(DesignTokens.Typography.caption)
                    Stepper(value: $model.equalParts, in: 2...20) { Text("\(model.equalParts)").monospacedDigit() }
                    Button("Repartir") { model.applyEqualParts() }.buttonStyle(.fluxioSecondary)
                }
                // Las partes que saldrán.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.Spacing.s) {
                        ForEach(Array(model.parts.enumerated()), id: \.offset) { i, part in
                            HStack(spacing: DesignTokens.Spacing.xs) {
                                Text("Parte \(i + 1)").textStyle(DesignTokens.Typography.label)
                                Text("\(VideoPreviewModel.format(part.0, decimals: false))–\(VideoPreviewModel.format(part.1, decimals: false))")
                                    .font(DesignTokens.Typography.caption.font.monospacedDigit())
                                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                                if i > 0 {
                                    Button { model.remove(model.cuts[i - 1]) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(DesignTokens.Colors.textSecondary)
                                        .help("Quitar el corte de antes de esta parte")
                                        .accessibilityLabel("Unir la parte \(i + 1) con la anterior")
                                }
                            }
                            .padding(.horizontal, DesignTokens.Spacing.s).padding(.vertical, DesignTokens.Spacing.xs)
                            .background(Capsule().fill(DesignTokens.Colors.recessed))
                        }
                    }
                }
                .frame(height: 30)
            }
            .frame(width: DesignTokens.VideoTools.previewSize.width)
        } footer: {
            Text("Ve al punto exacto y pulsa «Cortar aquí», o reparte en partes iguales.")
                .textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Dividir en \(model.parts.count) partes", action: onConfirm)
                .keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary).disabled(model.cuts.isEmpty)
        }
    }
}
