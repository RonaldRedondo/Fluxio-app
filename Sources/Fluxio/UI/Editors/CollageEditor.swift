import Combine
import SwiftUI

/// Collage: el diseño, el orden de las fotos y una vista previa en vivo.
@MainActor
final class CollageModel: ObservableObject {
    @Published var layout = CollageLayout() { didSet { schedulePreview() } }
    @Published private(set) var preview: CGImage?
    @Published var showSpacing = true
    @Published var showOrder = false
    let order: OrderModel
    private var thumbs: [URL: CGImage] = [:]
    private var generation = 0
    private var watcher: AnyCancellable?
    private static let queue = DispatchQueue(label: "fluxio.collage-preview", qos: .userInteractive)

    init(files: [FileInfo]) {
        order = OrderModel(files: files)
        layout.columns = files.count <= 4 ? 2 : 3
        for f in files { thumbs[f.url] = EditorImage.load(f.url, maxPixels: 700) }
        // Al cambiar el orden, también cambia la vista previa.
        watcher = order.$files.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.schedulePreview() }
        }
        schedulePreview()
    }

    var request: CollageRequest { CollageRequest(layout: layout, urls: order.files.map(\.url)) }

    func resetLayout() {
        let columns = order.files.count <= 4 ? 2 : 3
        layout = CollageLayout()
        layout.columns = columns
    }

    private func schedulePreview() {
        generation += 1
        let current = generation, layout = self.layout
        let images = order.files.compactMap { thumbs[$0.url] }
        Self.queue.async { [weak self] in
            let out = layout.render(images, width: DesignTokens.Collage.previewWidth)
            DispatchQueue.main.async {
                guard let self, current == self.generation, let out else { return }
                self.preview = out
            }
        }
    }
}

struct CollageEditorView: View {
    @ObservedObject var model: CollageModel
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias CL = DesignTokens.Collage

    var body: some View {
        ToolWindowView(title: "Crear collage", onClose: onCancel) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous).fill(Color.black.opacity(0.35))
                    if let preview = model.preview {
                        Image(decorative: preview, scale: 1).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(DesignTokens.Spacing.m)
                    }
                }
                .frame(width: CL.previewSide, height: CL.previewSide)
                .accessibilityLabel("Vista previa del collage")

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                        row("Estilo") {
                            Picker("Estilo", selection: $model.layout.style) {
                                ForEach(CollageLayout.Style.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: CL.menuWidth)
                        }
                        if model.layout.style == .grid {
                            row("Columnas") {
                                Stepper(value: $model.layout.columns, in: 1...max(1, model.order.files.count)) {
                                    Text("\(model.layout.effectiveColumns(model.order.files.count))").monospacedDigit()
                                }
                            }
                        }
                        row("Lienzo") {
                            Picker("Lienzo", selection: $model.layout.canvas) {
                                ForEach(CollageLayout.Canvas.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: CL.menuWidth)
                        }
                        row("Ancho") {
                            Picker("Ancho", selection: $model.layout.width) {
                                ForEach(CollageLayout.widths, id: \.self) { Text("\($0) px").tag($0) }
                            }.labelsHidden().frame(width: CL.menuWidth)
                        }
                        row("Ajuste") {
                            Picker("Ajuste", selection: $model.layout.fit) {
                                ForEach(CollageLayout.Fit.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: CL.menuWidth)
                        }

                        Rectangle().fill(DesignTokens.Colors.border).frame(height: DesignTokens.Stroke.hairline)
                        DisclosureGroup("Espacio y fondo", isExpanded: $model.showSpacing) {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                                slider("Espacio", value: $model.layout.spacing, range: 0...8)
                                slider("Esquinas", value: $model.layout.corners, range: 0...20)
                                HStack(spacing: DesignTokens.Spacing.xs) {
                                    ForEach(BackgroundStyle.solids.indices, id: \.self) { i in colorChip(i) }
                                }
                            }
                            .padding(.top, DesignTokens.Spacing.s)
                        }
                        .textStyle(DesignTokens.Typography.label)
                        DisclosureGroup("Orden de las fotos", isExpanded: $model.showOrder) {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                                HStack {
                                    Text("Arrastra las filas o usa las flechas.")
                                        .textStyle(DesignTokens.Typography.caption)
                                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                                    Spacer()
                                    Button { model.order.resetToName() } label: { Image(systemName: "arrow.up.arrow.down") }
                                        .buttonStyle(.fluxioSecondary).disabled(model.order.isByName)
                                        .help("Ordenar por nombre").accessibilityLabel("Ordenar por nombre")
                                }
                                OrderListView(model: model.order, visibleRows: CL.orderVisibleRows)
                            }
                            .padding(.top, DesignTokens.Spacing.s)
                        }
                        .textStyle(DesignTokens.Typography.label)
                    }
                    .padding(.trailing, DesignTokens.Spacing.s)
                }
                .frame(width: CL.controlsWidth, height: CL.previewSide)
            }
        } footer: {
            Button("Restablecer diseño") { model.resetLayout() }.buttonStyle(.fluxioSecondary)
            Spacer()
            Text("\(model.order.files.count) fotos · \(Int(model.layout.canvasSize(width: model.layout.width).width)) × \(Int(model.layout.canvasSize(width: model.layout.width).height)) px")
                .textStyle(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Crear collage", action: onConfirm).keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary)
        }
    }

    private func row<V: View>(_ title: String, @ViewBuilder _ control: () -> V) -> some View {
        HStack {
            Text(title).textStyle(DesignTokens.Typography.caption)
            Spacer()
            control()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            HStack {
                Text(title).textStyle(DesignTokens.Typography.caption)
                Spacer()
                Text(String(format: "%.1f %%", value.wrappedValue))
                    .font(DesignTokens.Typography.caption.font.monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            Slider(value: value, in: range).controlSize(.small).accessibilityLabel(title)
        }
    }

    private func colorChip(_ i: Int) -> some View {
        let on = model.layout.background == i
        return Button { model.layout.background = i } label: {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.badge, style: .continuous)
                .fill(Color(nsColor: BackgroundStyle.solids[i]))
                .frame(width: CL.chip, height: CL.chip)
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.badge, style: .continuous)
                    .strokeBorder(Color.white.opacity(on ? 0.95 : 0.15), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fondo \(i + 1)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
