import SwiftUI

/// Elegir el orden de varios archivos antes de unirlos (PDF o videos).
@MainActor
final class OrderModel: ObservableObject {
    @Published var files: [FileInfo]
    private let byName: [FileInfo]

    /// Empieza ordenado por nombre, como en Finder ("1.pdf", "2.pdf", "10.pdf").
    init(files: [FileInfo]) {
        byName = files.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        self.files = byName
    }

    var isByName: Bool { files == byName }

    func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard files.indices.contains(index), files.indices.contains(target) else { return }
        withAnimation(DesignTokens.Motion.toast) { files.swapAt(index, target) }
    }

    func resetToName() {
        withAnimation(DesignTokens.Motion.toast) { files = byName }
    }

    // MARK: Arrastrar para ordenar
    //
    // La fila que arrastras flota sobre la lista, pegada al ratón; en su puesto queda un hueco hacia el que se
    // apartan las demás. Así el orden puede cambiar con animación sin mover la fila que llevas.

    @Published private(set) var dragging: URL?
    /// Cuánto se ha movido el ratón (en vertical) desde que empezaste a arrastrar.
    @Published private(set) var dragTranslation: CGFloat = 0
    /// Puesto de la fila al empezar a arrastrarla.
    @Published private(set) var dragStart = 0
    /// Al soltar, la fila se desliza hasta su hueco (y vuelve a su tamaño); mientras tanto no empieza otro arrastre.
    @Published private(set) var dropping = false
    private var step: CGFloat = 1

    /// La fila cambia de puesto en cuanto pasa media fila; las demás se apartan con animación.
    func drag(_ url: URL, translation: CGFloat, step: CGFloat) {
        guard !dropping else { return }
        if dragging != url { dragging = url; dragStart = files.firstIndex { $0.url == url } ?? 0 }
        self.step = step
        // La fila no sale de la lista: llega como mucho a la primera o a la última posición.
        dragTranslation = min(max(translation, -CGFloat(dragStart) * step), CGFloat(files.count - 1 - dragStart) * step)
        guard let current = files.firstIndex(where: { $0.url == url }) else { return }
        let target = min(files.count - 1, max(0, dragStart + Int((dragTranslation / step).rounded())))
        guard target != current else { return }
        withAnimation(DesignTokens.Motion.toast) { files.insert(files.remove(at: current), at: target) }
    }

    /// Dónde se dibuja la fila que flota (borde de arriba, dentro de la lista).
    var floatingY: CGFloat { CGFloat(dragStart) * step + dragTranslation }

    /// Al soltar, la fila se desliza hasta su hueco y vuelve a la lista.
    func endDrag() {
        guard let url = dragging, !dropping, let current = files.firstIndex(where: { $0.url == url }) else { return }
        let slot = CGFloat(current - dragStart) * step
        withAnimation(DesignTokens.Motion.toast) { dragTranslation = slot; dropping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.ToolWindow.dropSettle) { [weak self] in
            self?.dragging = nil
            self?.dragTranslation = 0
            self?.dropping = false
        }
    }
}

struct OrderEditorView: View {
    @ObservedObject var model: OrderModel
    let title: String
    /// "Orden de los documentos", "Orden de reproducción".
    let caption: String
    let actionTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias TW = DesignTokens.ToolWindow

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                HStack {
                    Text(caption)
                        .textStyle(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Button { model.resetToName() } label: {
                        Label("Ordenar por nombre", systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.fluxioSecondary)
                    .disabled(model.isByName)
                    .help("Volver al orden por nombre, como en Finder")
                }
                Text("Arrastra las filas o usa las flechas para cambiar el orden.")
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                OrderListView(model: model, visibleRows: TW.orderVisibleRows)
            }
        } footer: {
            Spacer()
            Button("Cancelar", action: onCancel)
                .buttonStyle(.fluxioSecondary)
            Button(actionTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.fluxioPrimary)
        }
        .frame(width: TW.orderWidth)
    }
}

/// La lista numerada para ordenar (flechas o arrastrar). La usan Unir y Collage.
struct OrderListView: View {
    @ObservedObject var model: OrderModel
    let visibleRows: Int

    private typealias TW = DesignTokens.ToolWindow

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: DesignTokens.Spacing.s) {
                ForEach(Array(model.files.enumerated()), id: \.element.url) { index, file in
                    row(file, index: index)
                }
            }
            .overlay(alignment: .topLeading) { floatingRow }
        }
        .frame(height: listHeight)
    }

    /// La lista crece con los archivos hasta un máximo; a partir de ahí se desplaza.
    private var listHeight: CGFloat {
        let rows = CGFloat(min(model.files.count, visibleRows))
        return rows * TW.orderRowHeight + (rows - 1) * DesignTokens.Spacing.s
    }

    /// La fila que arrastras, por encima de las demás y pegada al ratón.
    @ViewBuilder
    private var floatingRow: some View {
        if let url = model.dragging, let index = model.files.firstIndex(where: { $0.url == url }) {
            row(model.files[index], index: index, floating: true)
                .offset(y: model.floatingY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func row(_ file: FileInfo, index: Int, floating: Bool = false) -> some View {
        // En la lista, la fila que arrastras deja un hueco punteado (sigue ahí para no perder el gesto).
        let isHole = model.dragging == file.url && !floating
        let lifted = floating && !model.dropping
        return HStack(spacing: DesignTokens.Spacing.m) {
            // Asa para arrastrar.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .accessibilityHidden(true)
            Text("\(index + 1)")
                .textStyle(DesignTokens.Typography.label)
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: TW.orderNumberWidth)
            FileThumbnailView(url: file.url, side: TW.orderThumbSize)
            Text(file.url.lastPathComponent)
                .textStyle(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DesignTokens.Spacing.s)
            VStack(spacing: DesignTokens.Spacing.xxs) {
                arrow("chevron.up", enabled: index > 0, label: "Subir \(file.url.lastPathComponent)") {
                    model.move(index, by: -1)
                }
                arrow("chevron.down", enabled: index < model.files.count - 1,
                      label: "Bajar \(file.url.lastPathComponent)") { model.move(index, by: 1) }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .frame(height: TW.orderRowHeight)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
            .fill(DesignTokens.Colors.recessed))
        // La fila que flota se eleva un poco; al soltarla vuelve a su tamaño.
        .scaleEffect(lifted && !DesignTokens.Motion.reduceMotion ? TW.orderDragScale : 1)
        .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 10, y: 4)
        .opacity(isHole ? 0.001 : 1)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                .strokeBorder(DesignTokens.Colors.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .opacity(isHole ? 1 : 0)
        )
        .contentShape(Rectangle())
        .gesture(
            // En coordenadas de la ventana: la fila cambia de sitio mientras la arrastras.
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    model.drag(file.url, translation: value.translation.height,
                               step: TW.orderRowHeight + DesignTokens.Spacing.s)
                }
                .onEnded { _ in model.endDrag() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1). \(file.url.lastPathComponent)")
    }

    private func arrow(_ symbol: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: TW.orderArrowSize.width, height: TW.orderArrowSize.height)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.badge, style: .continuous)
                    .fill(DesignTokens.Colors.border.opacity(enabled ? 1 : 0.4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
