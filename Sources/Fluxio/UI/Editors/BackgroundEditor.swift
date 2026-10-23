import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Añadir fondo: la foto sobre un degradado, un color o una imagen, con margen, esquinas, sombra y proporción.
@MainActor
final class BackgroundModel: ObservableObject {
    @Published var style = BackgroundStyle() { didSet { schedulePreview() } }
    @Published private(set) var preview: CGImage?
    /// Imagen de fondo elegida (en pequeño para la vista previa; la copia final usa una más grande).
    @Published private(set) var backgroundThumb: CGImage?
    private var backgroundURL: URL?
    let image: CGImage
    private var generation = 0
    private static let queue = DispatchQueue(label: "fluxio.background-preview", qos: .userInteractive)

    init?(url: URL) {
        guard let image = EditorImage.load(url, maxPixels: 1000) else { return nil }
        self.image = image
        schedulePreview()
    }

    static let `default` = BackgroundStyle()
    var isDefault: Bool {
        let d = Self.default
        if case .gradient(0) = style.fill {} else { return false }
        return style.padding == d.padding && style.corners == d.corners && style.shadow == d.shadow && style.ratio == d.ratio
    }

    func reset() { style = BackgroundStyle() }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Elige la imagen de fondo"
        panel.prompt = "Elegir"
        guard panel.runModal() == .OK, let url = panel.url, let thumb = EditorImage.load(url, maxPixels: 1000) else { return }
        backgroundURL = url
        backgroundThumb = thumb
        style.fill = .image(thumb)
    }

    /// Para guardar: si el fondo es una imagen, una versión más grande que la de la vista previa.
    var finalStyle: BackgroundStyle {
        var s = style
        if case .image = s.fill, let url = backgroundURL, let big = EditorImage.load(url, maxPixels: 4096) { s.fill = .image(big) }
        return s
    }

    private func schedulePreview() {
        generation += 1
        let current = generation, style = self.style, image = self.image
        Self.queue.async { [weak self] in
            let out = style.render(image)
            DispatchQueue.main.async {
                guard let self, current == self.generation, let out else { return }
                self.preview = out
            }
        }
    }
}

struct BackgroundEditorView: View {
    @ObservedObject var model: BackgroundModel
    var title = "Añadir fondo"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias MK = DesignTokens.Markup

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous).fill(Color.black.opacity(0.35))
                    if let preview = model.preview {
                        Image(decorative: preview, scale: 1).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(DesignTokens.Spacing.m)
                    }
                }
                .frame(width: MK.backgroundPreview, height: MK.backgroundPreview)
                .accessibilityLabel("Vista previa con el fondo")

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                    Text("FONDO").textStyle(DesignTokens.Typography.eyebrow).foregroundStyle(DesignTokens.Colors.textSecondary)
                    swatches
                    Rectangle().fill(DesignTokens.Colors.border).frame(height: DesignTokens.Stroke.hairline)
                    slider("Margen", value: $model.style.padding, range: 0...30, unit: "%")
                    slider("Esquinas", value: $model.style.corners, range: 0...20, unit: "%")
                    slider("Sombra", value: $model.style.shadow, range: 0...100, unit: "")
                    if case .image = model.style.fill {
                        slider("Desenfoque", value: $model.style.blur, range: 0...100, unit: "")
                    }
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("Proporción").textStyle(DesignTokens.Typography.caption)
                        Picker("Proporción", selection: $model.style.ratio) {
                            ForEach(BackgroundStyle.Ratio.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: MK.backgroundControls)
            }
        } footer: {
            Button("Restablecer") { model.reset() }.buttonStyle(.fluxioSecondary).disabled(model.isDefault)
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Guardar con fondo", action: onConfirm).keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary)
        }
    }

    private var swatches: some View {
        let columns = Array(repeating: GridItem(.fixed(MK.swatch), spacing: DesignTokens.Spacing.xs), count: 5)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // Identificadores distintos para degradados y colores (si se repiten, SwiftUI pierde algunos).
            ForEach(BackgroundStyle.gradients.indices.map { "g\($0)" }, id: \.self) { key in
                let i = Int(key.dropFirst())!
                swatch(selected: isGradient(i), label: "Degradado \(i + 1)") {
                    LinearGradient(colors: BackgroundStyle.gradients[i].map { Color(nsColor: $0) },
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } action: { model.style.fill = .gradient(i) }
            }
            ForEach(BackgroundStyle.solids.indices.map { "s\($0)" }, id: \.self) { key in
                let i = Int(key.dropFirst())!
                swatch(selected: isSolid(i), label: "Color \(i + 1)") {
                    Color(nsColor: BackgroundStyle.solids[i])
                } action: { model.style.fill = .solid(i) }
            }
            // Usar otra imagen como fondo.
            swatch(selected: isImage, label: "Imagen de fondo") {
                ZStack {
                    DesignTokens.Colors.recessed
                    if let thumb = model.backgroundThumb {
                        Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo.badge.plus").foregroundStyle(DesignTokens.Colors.textPrimary)
                    }
                }
            } action: { model.chooseBackgroundImage() }
        }
    }

    private func swatch<V: View>(selected: Bool, label: String, @ViewBuilder _ fill: () -> V, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            fill()
                .frame(width: MK.swatch, height: MK.swatch)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.12), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            HStack {
                Text(title).textStyle(DesignTokens.Typography.caption)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(unit)")
                    .font(DesignTokens.Typography.caption.font.monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            Slider(value: value, in: range).controlSize(.small).accessibilityLabel(title)
        }
    }

    private func isGradient(_ i: Int) -> Bool { if case .gradient(let g) = model.style.fill { return g == i }; return false }
    private func isSolid(_ i: Int) -> Bool { if case .solid(let s) = model.style.fill { return s == i }; return false }
    private var isImage: Bool { if case .image = model.style.fill { return true }; return false }
}
