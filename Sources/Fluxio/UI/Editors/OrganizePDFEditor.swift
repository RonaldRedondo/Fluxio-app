import AppKit
import PDFKit
import SwiftUI

/// Organizar páginas de un PDF: ordenarlas arrastrando, girarlas, duplicarlas o borrarlas.
@MainActor
final class OrganizeModel: ObservableObject {
    struct Page: Identifiable, Equatable {
        /// Las páginas originales usan su número; las duplicadas, números nuevos.
        let id: Int
        let source: Int
        /// Giro acumulado en grados (puede pasar de 360 para que la animación gire siempre hacia el mismo lado).
        var turns = 0
        var rotation: Int { ((turns % 360) + 360) % 360 }
    }

    @Published var pages: [Page]
    @Published var sameWidth = false
    @Published var thumbnails: [Int: NSImage] = [:]
    /// Tamaño que se ve de cada página original (con su propio giro).
    let sizes: [CGSize]
    private let original: [Page]
    private var nextID: Int

    init?(url: URL) {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { return nil }
        sizes = (0..<doc.pageCount).map { i in
            doc.page(at: i).map { PDFOrganizer.visibleSize($0, rotation: $0.rotation) } ?? CGSize(width: 1, height: 1)
        }
        original = (0..<doc.pageCount).map { Page(id: $0, source: $0) }
        pages = original
        nextID = doc.pageCount
        loadThumbnails(url, count: doc.pageCount)
    }

    var isUnchanged: Bool { pages == original && !sameWidth }

    var plan: PDFOrganizePlan {
        PDFOrganizePlan(pages: pages.map { .init(source: $0.source, rotation: $0.rotation) }, sameWidth: sameWidth)
    }

    /// Las miniaturas se dibujan aparte para que la ventana abra al momento aunque el PDF sea largo.
    private func loadThumbnails(_ url: URL, count: Int) {
        let side = DesignTokens.PDFOrganize.thumbBox * 2
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let doc = PDFDocument(url: url) else { return }
            for i in 0..<count {
                guard let image = doc.page(at: i)?.thumbnail(of: CGSize(width: side, height: side), for: .cropBox) else { continue }
                DispatchQueue.main.async { self?.thumbnails[i] = image }
            }
        }
    }

    // MARK: Cambios

    func reset() {
        withAnimation(DesignTokens.Motion.toast) { pages = original; sameWidth = false }
    }

    /// Gira un cuarto de vuelta (90 en el sentido del reloj, −90 al revés).
    func rotate(_ id: Int, by degrees: Int) {
        guard let i = index(id) else { return }
        withAnimation(DesignTokens.Motion.toast) { pages[i].turns += degrees }
    }

    func duplicate(_ id: Int) {
        guard let i = index(id) else { return }
        var copy = Page(id: nextID, source: pages[i].source)
        copy.turns = pages[i].turns
        nextID += 1
        withAnimation(DesignTokens.Motion.toast) { pages.insert(copy, at: i + 1) }
    }

    func delete(_ id: Int) {
        guard pages.count > 1, let i = index(id) else { return }
        withAnimation(DesignTokens.Motion.toast) { _ = pages.remove(at: i) }
    }

    func move(_ id: Int, by delta: Int) {
        guard let i = index(id), pages.indices.contains(i + delta) else { return }
        withAnimation(DesignTokens.Motion.toast) { pages.swapAt(i, i + delta) }
    }

    private func index(_ id: Int) -> Int? { pages.firstIndex { $0.id == id } }

    // MARK: Arrastrar para ordenar
    //
    // La página que arrastras flota sobre la cuadrícula, pegada al ratón; en su puesto queda un hueco hacia el
    // que se apartan las demás. Así el orden puede cambiar con animación sin mover la tarjeta que llevas.

    @Published private(set) var dragging: Int?
    /// Cuánto se ha movido el ratón desde que empezaste a arrastrar.
    @Published private(set) var dragTranslation: CGSize = .zero
    /// Puesto de la página al empezar a arrastrarla.
    @Published private(set) var dragStart = 0
    /// Al soltar, la tarjeta se desliza hasta su hueco (y vuelve a su tamaño); mientras tanto no empieza otro arrastre.
    @Published private(set) var dropping = false

    private typealias PO = DesignTokens.PDFOrganize
    private var step: CGSize { CGSize(width: PO.card.width + PO.gap, height: PO.card.height + PO.gap) }

    /// La página cambia de puesto en cuanto pasa media tarjeta; las demás se apartan con animación.
    func drag(_ id: Int, translation: CGSize) {
        guard !dropping else { return }
        if dragging != id { dragging = id; dragStart = index(id) ?? 0 }
        // La tarjeta no sale de la cuadrícula: llega como mucho a la primera o última columna y fila.
        let startCol = CGFloat(dragStart % PO.columns), startRow = CGFloat(dragStart / PO.columns)
        let lastRow = CGFloat((pages.count - 1) / PO.columns)
        dragTranslation = CGSize(
            width: min(max(translation.width, -startCol * step.width), (CGFloat(PO.columns - 1) - startCol) * step.width),
            height: min(max(translation.height, -startRow * step.height), (lastRow - startRow) * step.height))
        guard let current = index(id) else { return }
        let col = min(PO.columns - 1, max(0, dragStart % PO.columns + Int((dragTranslation.width / step.width).rounded())))
        let row = max(0, dragStart / PO.columns + Int((dragTranslation.height / step.height).rounded()))
        let target = min(pages.count - 1, row * PO.columns + col)
        guard target != current else { return }
        withAnimation(DesignTokens.Motion.toast) { pages.insert(pages.remove(at: current), at: target) }
    }

    /// Dónde se dibuja la tarjeta que flota (esquina de arriba a la izquierda, dentro de la cuadrícula).
    var floatingOrigin: CGPoint {
        CGPoint(x: CGFloat(dragStart % PO.columns) * step.width + dragTranslation.width,
                y: CGFloat(dragStart / PO.columns) * step.height + dragTranslation.height)
    }

    /// Al soltar, la tarjeta se desliza hasta su hueco y vuelve a la cuadrícula.
    func endDrag() {
        guard let id = dragging, !dropping, let current = index(id) else { return }
        let slot = CGSize(width: CGFloat(current % PO.columns - dragStart % PO.columns) * step.width,
                          height: CGFloat(current / PO.columns - dragStart / PO.columns) * step.height)
        withAnimation(DesignTokens.Motion.toast) { dragTranslation = slot; dropping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.ToolWindow.dropSettle) { [weak self] in
            self?.dragging = nil
            self?.dragTranslation = .zero
            self?.dropping = false
        }
    }
}

struct OrganizePDFEditorView: View {
    @ObservedObject var model: OrganizeModel
    let title: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias PO = DesignTokens.PDFOrganize

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                HStack {
                    Text(model.pages.count == 1 ? "1 página" : "\(model.pages.count) páginas")
                        .textStyle(DesignTokens.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Button { model.reset() } label: {
                        Label("Restablecer", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.fluxioSecondary)
                    .disabled(model.isUnchanged)
                    .help("Volver a las páginas originales")
                }
                Text("Arrastra las páginas para ordenarlas. Pasa el ratón por una para duplicarla o borrarla.")
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(PO.card.width), spacing: PO.gap), count: PO.columns),
                              alignment: .leading, spacing: PO.gap) {
                        ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                            PageCard(model: model, page: page, number: index + 1)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .topLeading) { floatingCard }
                    .padding(PO.gap / 2)
                }
                .frame(width: gridWidth, height: gridHeight)

                Rectangle().fill(DesignTokens.Colors.border).frame(height: DesignTokens.Stroke.hairline)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                Toggle("Mismo ancho en todas las páginas", isOn: $model.sameWidth)
                    .toggleStyle(.checkbox)
                    .textStyle(DesignTokens.Typography.label)
                Text("Las páginas se escalan para igualar a la más estrecha; su alto puede variar.")
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        } footer: {
            Spacer()
            Button("Cancelar", action: onCancel)
                .buttonStyle(.fluxioSecondary)
            Button("Guardar PDF", action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.fluxioPrimary)
        }
    }

    /// La página que arrastras, por encima de las demás y pegada al ratón.
    @ViewBuilder
    private var floatingCard: some View {
        if let id = model.dragging, let index = model.pages.firstIndex(where: { $0.id == id }) {
            PageCard(model: model, page: model.pages[index], number: index + 1, floating: true)
                .offset(x: model.floatingOrigin.x, y: model.floatingOrigin.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var gridWidth: CGFloat {
        CGFloat(PO.columns) * PO.card.width + CGFloat(PO.columns - 1) * PO.gap + PO.gap
    }

    /// La cuadrícula crece con las páginas hasta unas filas; a partir de ahí se desplaza.
    private var gridHeight: CGFloat {
        let rows = (Double(model.pages.count) / Double(PO.columns)).rounded(.up)
        let shown = CGFloat(min(rows, PO.visibleRows))
        return shown * PO.card.height + (shown.rounded(.up) - 1) * PO.gap + PO.gap
    }
}

/// Una página: número, miniatura y botones para girar, duplicar y borrar.
private struct PageCard: View {
    @ObservedObject var model: OrganizeModel
    let page: OrganizeModel.Page
    let number: Int
    /// La copia que flota mientras la arrastras (la de la cuadrícula queda como hueco).
    var floating = false
    @StateObject private var hover = HoverState()

    private typealias PO = DesignTokens.PDFOrganize

    var body: some View {
        let isDragged = model.dragging == page.id
        // En la cuadrícula, la página que arrastras deja un hueco punteado (sigue ahí para no perder el gesto).
        let isHole = isDragged && !floating
        let lifted = hover.isOn && model.dragging == nil
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                .fill(DesignTokens.Colors.recessed)
            VStack(spacing: 0) {
                Spacer().frame(height: PO.cardHeader)
                thumbnail.frame(width: PO.thumbBox, height: PO.thumbBox)
                Spacer(minLength: 0)
            }
        }
        .frame(width: PO.card.width, height: PO.card.height)
        .overlay(alignment: .topLeading) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: PO.badge, minHeight: PO.badge)
                .background(Capsule().fill(DesignTokens.Colors.accent))
                .padding(DesignTokens.Spacing.xs + DesignTokens.Spacing.xxs)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topTrailing) {
            cardButton("rotate.right", label: "Girar a la derecha") { model.rotate(page.id, by: 90) }
                .padding(DesignTokens.Spacing.xs + DesignTokens.Spacing.xxs)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                cardButton("plus.square.on.square", label: "Duplicar") { model.duplicate(page.id) }
                cardButton("trash", label: "Borrar", enabled: model.pages.count > 1) { model.delete(page.id) }
            }
            .padding(DesignTokens.Spacing.s)
            .opacity(hover.isOn && model.dragging == nil && !floating ? 1 : 0)
        }
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
            .strokeBorder(DesignTokens.Colors.accent.opacity(lifted ? 0.6 : 0), lineWidth: DesignTokens.Stroke.hairline * 2))
        // Al pasar el ratón la tarjeta sube un poco; la que flota crece y lleva sombra.
        .scaleEffect(floating && !model.dropping && !DesignTokens.Motion.reduceMotion ? PO.dragScale : 1)
        .offset(y: lifted && !DesignTokens.Motion.reduceMotion ? -PO.hoverLift : 0)
        .shadow(color: .black.opacity(floating && !model.dropping ? 0.35 : lifted ? 0.18 : 0), radius: floating ? 12 : 6, y: 4)
        .opacity(isHole ? 0.001 : 1)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                .strokeBorder(DesignTokens.Colors.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .opacity(isHole ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(DesignTokens.Motion.hover) { hover.isOn = inside } }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { model.drag(page.id, translation: $0.translation) }
                .onEnded { _ in model.endDrag() }
        )
        .contextMenu {
            Button("Girar a la derecha") { model.rotate(page.id, by: 90) }
            Button("Girar a la izquierda") { model.rotate(page.id, by: -90) }
            Button("Duplicar") { model.duplicate(page.id) }
            Divider()
            Button("Borrar") { model.delete(page.id) }.disabled(model.pages.count < 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page.source + 1 == number ? "Página \(number)" : "Página \(number), original \(page.source + 1)")
        .accessibilityAction(named: "Mover antes") { model.move(page.id, by: -1) }
        .accessibilityAction(named: "Mover después") { model.move(page.id, by: 1) }
        .accessibilityAction(named: "Girar a la izquierda") { model.rotate(page.id, by: -90) }
    }

    /// Miniatura girada; se ajusta para que quepa entera también de lado.
    private var thumbnail: some View {
        let base = model.sizes[page.source]
        let sideways = (page.turns / 90) % 2 != 0
        let box = PO.thumbBox
        let k = sideways ? min(box / base.height, box / base.width) : min(box / base.width, box / base.height)
        return Group {
            if let image = model.thumbnails[page.source] {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Color.white
            }
        }
        .frame(width: base.width * k, height: base.height * k)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .rotationEffect(.degrees(Double(page.turns)))
        .accessibilityHidden(true)
    }

    private func cardButton(_ symbol: String, label: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: PO.button, height: PO.button)
                .background(Circle().fill(Color.black.opacity(0.65)))
                .contentShape(Circle())
        }
        .buttonStyle(NavPressStyle())
        .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
