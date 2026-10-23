import AVFoundation
import SwiftUI

// MARK: - Común: onda, reproductor y vista previa con el efecto

@MainActor
final class AudioToolModel: ObservableObject {
    let url: URL
    let player: VideoPreviewModel
    let sourceChannels: Int
    @Published private(set) var peaks: [[Float]] = []
    /// Reproductor de la vista previa con el efecto aplicado (los primeros segundos).
    @Published private(set) var rendering = false
    @Published private(set) var playingPreview: String?
    private var previewPlayer: AVPlayer?
    private var previewFile: URL?

    init(url: URL, channels: Int) {
        self.url = url
        player = VideoPreviewModel(url: url)
        sourceChannels = AudioAnalysis.channelCount(url)
        let wanted = min(channels, max(1, sourceChannels))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = AudioAnalysis.peaks(url, channels: wanted, bins: DesignTokens.AudioTools.bins)
            DispatchQueue.main.async { self?.peaks = p }
        }
    }

    /// Escucha el resultado con `filter` (se prepara en segundo plano; otro clic lo para).
    func playPreview(_ key: String, filter: String, seconds: Double = 30) {
        player.player.pause()
        if playingPreview == key { stopPreview(); return }
        stopPreview()
        rendering = true
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = try? AudioAnalysis.preview(url, filter: filter, seconds: seconds)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                guard let out else { return }
                self.previewFile = out
                let p = AVPlayer(url: out)
                self.previewPlayer = p
                self.playingPreview = key
                p.play()
            }
        }
    }

    func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        playingPreview = nil
        if let f = previewFile { try? FileManager.default.removeItem(at: f) }
        previewFile = nil
    }

    func stop() { stopPreview(); player.stop() }
}

/// La onda en barras con el degradado de Fluxio; la línea blanca marca dónde va la reproducción.
struct WaveformView: View {
    let peaks: [Float]
    var progress: Double? = nil
    var dimmed = false
    /// Tramos marcados (de 0 a 1), por ejemplo los pitidos.
    var highlights: [(Double, Double)] = []

    var body: some View {
        Canvas { ctx, size in
            for (a, b) in highlights {
                ctx.fill(Path(CGRect(x: size.width * a, y: 0, width: max(2, size.width * (b - a)), height: size.height)),
                         with: .color(DesignTokens.Colors.accent.opacity(0.18)))
            }
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            let bar = max(1, step * 0.6)
            var path = Path()
            for (i, p) in peaks.enumerated() {
                let h = max(1.5, CGFloat(p) * size.height * 0.92)
                path.addRoundedRect(in: CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: bar, height: h),
                                    cornerSize: CGSize(width: bar / 2, height: bar / 2))
            }
            ctx.fill(path, with: .linearGradient(Gradient(colors: [DesignTokens.Colors.accent, DesignTokens.Colors.accentEnd]),
                                                 startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            if let progress {
                let x = size.width * CGFloat(min(1, max(0, progress)))
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .overlay { if peaks.isEmpty { ProgressView().controlSize(.small) } }
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous).fill(DesignTokens.Colors.recessed))
        .accessibilityHidden(true)
    }
}

/// Reproducir el original, con la posición y el tiempo.
struct AudioPlayBar: View {
    @ObservedObject var player: VideoPreviewModel
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                .buttonStyle(.fluxioSecondary).accessibilityLabel(player.isPlaying ? "Pausa" : "Reproducir el original")
            Spacer()
            Text("\(VideoPreviewModel.format(player.current)) / \(VideoPreviewModel.format(player.duration))")
                .font(DesignTokens.Typography.caption.font.monospacedDigit())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }
}

private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.xxs) {
        HStack {
            Text(title).textStyle(DesignTokens.Typography.label)
            Spacer()
            Text(text).font(DesignTokens.Typography.label.font.monospacedDigit()).foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        Slider(value: value, in: range, step: step).controlSize(.small).accessibilityLabel(title).accessibilityValue(text)
    }
}

private func previewButton(_ title: String, active: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if busy { ProgressView().controlSize(.small) } else { Image(systemName: active ? "stop.fill" : "play.fill") }
            Text(title)
        }
    }
    .buttonStyle(.fluxioSecondary)
}

// MARK: - Normalizar

@MainActor
final class NormalizeModel: ObservableObject {
    let audio: AudioToolModel
    @Published var loudness: Double = -16
    @Published var range: Double = 11
    @Published var peak: Double = -1.5
    @Published private(set) var measured: Double?

    init(url: URL) {
        audio = AudioToolModel(url: url, channels: 1)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let m = AudioAnalysis.loudness(url)
            DispatchQueue.main.async { self?.measured = m }
        }
    }

    var filter: String { AudioFilters.normalize(loudness: loudness, range: range, peak: peak) }
    var parameters: [String: Double] { ["loudness": loudness, "range": range, "peak": peak] }
}

struct NormalizeEditorView: View {
    @ObservedObject var model: NormalizeModel
    @ObservedObject var audio: AudioToolModel
    @ObservedObject var player: VideoPreviewModel
    var title = "Normalizar volumen"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    init(model: NormalizeModel, title: String, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.model = model; audio = model.audio; player = model.audio.player
        self.title = title; self.onCancel = onCancel; self.onConfirm = onConfirm
    }

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                HStack {
                    Text(audio.url.lastPathComponent).textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Text(VideoPreviewModel.format(player.duration)).font(DesignTokens.Typography.caption.font.monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                WaveformView(peaks: audio.peaks.first ?? [], progress: player.duration > 0 ? player.current / player.duration : nil)
                    .frame(height: DesignTokens.AudioTools.waveHeight)
                AudioPlayBar(player: player)
                sliderRow("Volumen objetivo", value: $model.loudness, range: -24...(-9), step: 0.5, text: String(format: "%.1f LUFS", model.loudness))
                sliderRow("Margen dinámico", value: $model.range, range: 1...20, step: 1, text: String(format: "%.0f LU", model.range))
                sliderRow("Pico máximo", value: $model.peak, range: -9...0, step: 0.5, text: String(format: "%.1f dBTP", model.peak))
                HStack {
                    Text(model.measured.map { String(format: "Ahora: %.1f LUFS  →  saldrá a %.1f LUFS", $0, model.loudness) } ?? "Midiendo el volumen actual…")
                        .font(DesignTokens.Typography.caption.font.monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.accent)
                    Spacer()
                    previewButton("Escuchar resultado", active: audio.playingPreview == "out", busy: audio.rendering) {
                        audio.playPreview("out", filter: model.filter)
                    }
                }
                Text("−16 LUFS va bien para voz y música. El pico máximo evita que suene saturado al guardar.")
                    .textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .frame(width: DesignTokens.AudioTools.width)
        } footer: {
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Normalizar audio", action: onConfirm).keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary)
        }
    }
}

// MARK: - Canales

@MainActor
final class ChannelsModel: ObservableObject {
    let audio: AudioToolModel
    @Published var mono = false
    @Published var left: Double = 1
    @Published var right: Double = 1

    init(url: URL) { audio = AudioToolModel(url: url, channels: 2) }

    var filter: String { AudioFilters.channels(mono: mono, left: left, right: right, sourceChannels: audio.sourceChannels) }
    var parameters: [String: Double] { ["mono": mono ? 1 : 0, "left": left, "right": right] }
}

struct ChannelsEditorView: View {
    @ObservedObject var model: ChannelsModel
    @ObservedObject var audio: AudioToolModel
    var title = "Canales de audio"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    init(model: ChannelsModel, title: String, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.model = model; audio = model.audio
        self.title = title; self.onCancel = onCancel; self.onConfirm = onConfirm
    }

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                Text(audio.sourceChannels < 2 ? "El original es mono: los dos lados salen del mismo canal." : "Canales del original")
                    .textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                ForEach(0..<2, id: \.self) { c in
                    HStack(spacing: DesignTokens.Spacing.m) {
                        Text(c == 0 ? "I" : "D")
                            .textStyle(DesignTokens.Typography.label)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(DesignTokens.Colors.recessed))
                            .help(c == 0 ? "Izquierdo" : "Derecho")
                        WaveformView(peaks: audio.peaks.count > c ? audio.peaks[c] : (audio.peaks.first ?? []),
                                     dimmed: (c == 0 ? model.left : model.right) == 0)
                            .frame(height: DesignTokens.AudioTools.channelHeight)
                        previewButton("", active: audio.playingPreview == "solo\(c)", busy: false) {
                            audio.playPreview("solo\(c)", filter: AudioFilters.solo(left: c == 0, sourceChannels: audio.sourceChannels))
                        }
                        .help(c == 0 ? "Escuchar solo el izquierdo" : "Escuchar solo el derecho")
                    }
                }
                Rectangle().fill(DesignTokens.Colors.border).frame(height: DesignTokens.Stroke.hairline)
                HStack {
                    Text("Salida").textStyle(DesignTokens.Typography.label)
                    Spacer()
                    SlidingTabs(tabs: [.init(id: true, title: "Mono", symbol: "speaker.wave.1"),
                                       .init(id: false, title: "Estéreo", symbol: "speaker.wave.2")], selection: $model.mono)
                        .fixedSize()
                }
                sliderRow("Volumen izquierdo", value: $model.left, range: 0...2, step: 0.05, text: String(format: "%.0f %%", model.left * 100))
                sliderRow("Volumen derecho", value: $model.right, range: 0...2, step: 0.05, text: String(format: "%.0f %%", model.right * 100))
                HStack {
                    Spacer()
                    previewButton("Escuchar resultado", active: audio.playingPreview == "out", busy: audio.rendering) {
                        audio.playPreview("out", filter: model.filter)
                    }
                }
            }
            .frame(width: DesignTokens.AudioTools.width)
        } footer: {
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Aplicar", action: onConfirm).keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary)
        }
    }
}

// MARK: - Pitido

@MainActor
final class BleepModel: ObservableObject {
    struct Range: Identifiable, Equatable { let id = UUID(); var start: Double; var end: Double }
    let audio: AudioToolModel
    @Published var ranges: [Range] = []
    @Published var selected: UUID?

    init(url: URL) { audio = AudioToolModel(url: url, channels: 1) }

    var duration: Double { max(0.01, audio.player.duration) }
    var filter: String { AudioFilters.bleep(ranges.map { ($0.start, $0.end) }) }

    var parameters: [String: Double] {
        var p: [String: Double] = ["count": Double(ranges.count)]
        for (i, r) in ranges.sorted(by: { $0.start < $1.start }).enumerated() { p["s\(i)"] = r.start; p["e\(i)"] = r.end }
        return p
    }

    func deleteSelected() {
        withAnimation(DesignTokens.Motion.toast) { ranges.removeAll { $0.id == selected } }
        selected = nil
    }

    /// Hasta dónde hace falta preparar la vista previa: el final del último pitido y un poco más.
    var previewSeconds: Double { min(duration, max(10, (ranges.map(\.end).max() ?? 0) + 2)) }
}

struct BleepEditorView: View {
    @ObservedObject var model: BleepModel
    @ObservedObject var audio: AudioToolModel
    @ObservedObject var player: VideoPreviewModel
    var title = "Pitido"
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @StateObject private var draft = ViewState<(Double, Double)?>(nil)

    private typealias AT = DesignTokens.AudioTools

    init(model: BleepModel, title: String, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.model = model; audio = model.audio; player = model.audio.player
        self.title = title; self.onCancel = onCancel; self.onConfirm = onConfirm
    }

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                HStack {
                    Text("Pitidos").textStyle(DesignTokens.Typography.label)
                    Text("\(model.ranges.count)").textStyle(DesignTokens.Typography.label).foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(.fluxioSecondary).disabled(model.selected == nil)
                        .help("Quitar el pitido elegido (⌫)").accessibilityLabel("Quitar el pitido elegido")
                        .keyboardShortcut(.delete, modifiers: [])
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .topLeading) {
                        // Capa de pitidos: arrastra para crear uno.
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                            .fill(DesignTokens.Colors.recessed)
                            .frame(height: AT.bleepLane)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("pitido"))
                                .onChanged { v in
                                    let a = time(v.startLocation.x, w), b = time(v.location.x, w)
                                    draft.value = (min(a, b), max(a, b))
                                }
                                .onEnded { _ in
                                    if let d = draft.value, d.1 - d.0 > 0.05 {
                                        let r = BleepModel.Range(start: d.0, end: d.1)
                                        withAnimation(DesignTokens.Motion.toast) { model.ranges.append(r) }
                                        model.selected = r.id
                                    }
                                    draft.value = nil
                                })
                        if let d = draft.value { chip(BleepModel.Range(start: d.0, end: d.1), width: w, live: true) }
                        ForEach($model.ranges) { $r in chip(r, width: w, binding: $r) }
                        // Los tramos tapados se ven también sobre la onda.
                        WaveformView(peaks: audio.peaks.first ?? [], progress: player.duration > 0 ? player.current / player.duration : nil,
                                     highlights: model.ranges.map { ($0.start / model.duration, $0.end / model.duration) })
                            .frame(width: w, height: AT.waveHeight)
                            .offset(y: AT.bleepLane + DesignTokens.Spacing.s)
                            .allowsHitTesting(false)
                    }
                    .coordinateSpace(name: "pitido")
                }
                .frame(height: AT.bleepLane + DesignTokens.Spacing.s + AT.waveHeight)
                HStack {
                    Text("0:00.00").font(DesignTokens.Typography.caption.font.monospacedDigit())
                    Spacer()
                    Text(VideoPreviewModel.format(player.duration)).font(DesignTokens.Typography.caption.font.monospacedDigit())
                }
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text("Arrastra sobre la capa de arriba para añadir un pitido; arrastra el pitido para moverlo o sus bordes para ajustarlo.")
                    .textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                HStack(spacing: DesignTokens.Spacing.s) {
                    Text("Escuchar").textStyle(DesignTokens.Typography.label)
                    Spacer()
                    Button { audio.stopPreview(); player.togglePlay() } label: {
                        Label("Original", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }.buttonStyle(.fluxioSecondary)
                    previewButton("Con pitidos", active: audio.playingPreview == "out", busy: audio.rendering) {
                        audio.playPreview("out", filter: model.filter, seconds: model.previewSeconds)
                    }
                    .disabled(model.ranges.isEmpty)
                }
            }
            .frame(width: AT.width)
        } footer: {
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Guardar copia con pitidos", action: onConfirm).keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary)
                .disabled(model.ranges.isEmpty)
        }
    }

    private func time(_ x: CGFloat, _ w: CGFloat) -> Double { min(model.duration, max(0, Double(x / max(1, w)) * model.duration)) }

    /// Un pitido en la capa (dibujo). `edges` añade las asas de los bordes.
    private func chipBody(_ r: BleepModel.Range, width w: CGFloat, live: Bool) -> some View {
        let on = model.selected == r.id
        return ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                .fill(DesignTokens.Colors.accentGradient)
                .opacity(live ? 0.6 : 1)
            Text("Pitido").textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.onAccent).lineLimit(1)
        }
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
            .strokeBorder(Color.white.opacity(on ? 0.9 : 0), lineWidth: 1.5))
        .frame(width: max(AT.edge * 2 + 4, w * (r.end - r.start) / model.duration), height: AT.bleepLane)
    }

    private func chip(_ r: BleepModel.Range, width w: CGFloat, live: Bool) -> some View {
        chipBody(r, width: w, live: live).offset(x: w * r.start / model.duration).allowsHitTesting(false)
    }

    /// Un pitido que se mueve arrastrándolo y se ajusta por los bordes.
    private func chip(_ r: BleepModel.Range, width w: CGFloat, binding b: Binding<BleepModel.Range>) -> some View {
        chipBody(r, width: w, live: false)
            .overlay {
                HStack {
                    edge(b, left: true, width: w)
                    Spacer()
                    edge(b, left: false, width: w)
                }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("pitido"))
                .onChanged { v in
                    model.selected = b.wrappedValue.id
                    let len = b.wrappedValue.end - b.wrappedValue.start
                    let start = min(model.duration - len, max(0, time(v.location.x, w) - len / 2))
                    b.wrappedValue.start = start; b.wrappedValue.end = start + len
                })
            .onTapGesture { model.selected = r.id }
            .offset(x: w * r.start / model.duration)
            .accessibilityElement()
            .accessibilityLabel("Pitido de \(VideoPreviewModel.format(r.start)) a \(VideoPreviewModel.format(r.end))")
    }

    private func edge(_ b: Binding<BleepModel.Range>, left: Bool, width w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.9))
            .frame(width: 3, height: AT.bleepLane * 0.5)
            .padding(.horizontal, 4)
            .frame(width: AT.edge, height: AT.bleepLane)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pitido"))
                .onChanged { v in
                    model.selected = b.wrappedValue.id
                    let t = time(v.location.x, w)
                    if left { b.wrappedValue.start = min(t, b.wrappedValue.end - 0.05) }
                    else { b.wrappedValue.end = max(t, b.wrappedValue.start + 0.05) }
                })
    }
}
