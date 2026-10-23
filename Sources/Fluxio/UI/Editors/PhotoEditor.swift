import AppKit
import CoreImage
import ImageIO
import SwiftUI

/// Editar foto: los ajustes y su vista previa en vivo (sobre una copia pequeña, para que vaya fluido).
@MainActor
final class PhotoEditModel: ObservableObject {
    @Published var values: [String: Double] = [:] { didSet { schedulePreview() } }
    @Published private(set) var preview: CGImage?
    /// Mientras mantienes pulsado «Ver original».
    @Published var showingOriginal = false
    let original: CGImage

    private let source: CIImage
    private let scale: Double
    private var generation = 0
    private static let queue = DispatchQueue(label: "fluxio.photo-preview", qos: .userInteractive)

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: DesignTokens.PhotoEditor.previewMaxPixels,
              ] as CFDictionary)
        else { return nil }
        let width = Double(props[kCGImagePropertyPixelWidth] as? Int ?? thumb.width)
        let height = Double(props[kCGImagePropertyPixelHeight] as? Int ?? thumb.height)
        original = thumb
        source = CIImage(cgImage: thumb)
        scale = Double(max(thumb.width, thumb.height)) / max(1, max(width, height))
        preview = thumb
    }

    var parameters: [String: Double] { values.filter { $0.value != 0 } }
    var hasChanges: Bool { !parameters.isEmpty }

    func value(_ id: String) -> Double { values[id] ?? 0 }

    func binding(_ id: String) -> Binding<Double> {
        Binding(get: { [weak self] in self?.values[id] ?? 0 }, set: { [weak self] in self?.values[id] = $0 })
    }

    func reset(_ ids: [String]) { ids.forEach { values[$0] = 0 } }
    func resetAll() { values = [:] }

    /// Se dibuja en segundo plano; si mientras tanto mueves otro control, solo cuenta el último.
    private func schedulePreview() {
        generation += 1
        let current = generation
        let adjustments = PhotoAdjustments(values)
        let source = self.source, scale = self.scale, original = self.original
        Self.queue.async { [weak self] in
            let output = adjustments.isIdentity ? original
                : adjustments.apply(to: source, scale: scale).flatMapCG(colorSpace: original.colorSpace)
            DispatchQueue.main.async {
                guard let self, current == self.generation, let output else { return }
                self.preview = output
            }
        }
    }
}

private extension CIImage {
    func flatMapCG(colorSpace: CGColorSpace?) -> CGImage? {
        PhotoRenderer.context.createCGImage(self, from: extent, format: .RGBA8,
                                            colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

struct PhotoEditorView: View {
    @ObservedObject var model: PhotoEditModel
    var title = "Editar foto"
    let fileName: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias PE = DesignTokens.PhotoEditor

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.l) {
                previewPane
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                        ForEach(PhotoAdjustments.groups) { group in groupView(group) }
                    }
                    .padding(.trailing, DesignTokens.Spacing.s)
                }
                .frame(width: PE.controlsWidth)
            }
            .frame(height: PE.contentHeight)
        } footer: {
            Button("Restablecer todo") { model.resetAll() }
                .buttonStyle(.fluxioSecondary)
                .disabled(!model.hasChanges)
            Spacer()
            Button("Cancelar", action: onCancel)
                .buttonStyle(.fluxioSecondary)
            Button("Guardar copia editada", action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.fluxioPrimary)
                .disabled(!model.hasChanges)
        }
    }

    private var previewPane: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                if let image = model.showingOriginal ? model.original : model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous))
                        .padding(DesignTokens.Spacing.m)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(model.showingOriginal ? "Foto original" : "Vista previa con los ajustes")
            HStack {
                Text(fileName)
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                // Mantén pulsado para comparar con la foto sin ajustes.
                Label("Mantén para ver el original", systemImage: "eye")
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(model.showingOriginal ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary)
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                    .background(Capsule().fill(DesignTokens.Colors.recessed))
                    .contentShape(Capsule())
                    // Mientras mantienes pulsado se ve el original; al soltar, la vista previa.
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !model.showingOriginal { model.showingOriginal = true } }
                        .onEnded { _ in model.showingOriginal = false })
                    .opacity(model.hasChanges ? 1 : 0.5)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(minWidth: PE.previewMinWidth, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupView(_ group: PhotoAdjustments.Group) -> some View {
        let changed = group.controls.contains { model.value($0.id) != 0 }
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack {
                Text(group.title)
                    .textStyle(DesignTokens.Typography.eyebrow)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if changed {
                    Button { model.reset(group.controls.map(\.id)) } label: {
                        Label("Restablecer", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.fluxioSecondary)
                    .controlSize(.small)
                    .help("Restablecer \(group.title.lowercased())")
                    .transition(.opacity)
                }
            }
            ForEach(group.controls) { control in controlRow(control) }
        }
        .animation(DesignTokens.Motion.control, value: changed)
    }

    private func controlRow(_ control: PhotoAdjustments.Control) -> some View {
        let value = model.value(control.id)
        return VStack(spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(control.title)
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                Text(control.format(value))
                    .font(DesignTokens.Typography.caption.font.monospacedDigit())
                    .foregroundStyle(value == 0 ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.accent)
                Button { model.reset([control.id]) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .opacity(value == 0 ? 0 : 1)
                .disabled(value == 0)
                .help("Restablecer \(control.title.lowercased())")
                .accessibilityLabel("Restablecer \(control.title)")
            }
            Slider(value: model.binding(control.id), in: control.range)
                .controlSize(.small)
                .accessibilityLabel(control.title)
                .accessibilityValue(control.format(value))
        }
    }
}
