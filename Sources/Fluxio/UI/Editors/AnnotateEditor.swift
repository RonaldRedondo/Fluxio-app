import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Copia de la foto para las ventanas (orientada y de tamaño razonable): así todo va fluido.
enum EditorImage {
    static func load(_ url: URL, maxPixels: Int = 1600) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// Dónde cabe la imagen dentro de `bounds`, centrada y sin deformar.
    static func fit(_ image: CGImage, in bounds: CGRect, inset: CGFloat) -> CGRect {
        let area = bounds.insetBy(dx: inset, dy: inset)
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Modelo

@MainActor
final class AnnotateModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, arrow, rectangle, ellipse, pen, highlight, text, number, magnifier, image
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .pen: return "scribble"
            case .highlight: return "highlighter"
            case .text: return "textformat"
            case .number: return "1.circle"
            case .magnifier: return "plus.magnifyingglass"
            case .image: return "photo.badge.plus"
            }
        }
        var title: String {
            switch self {
            case .select: return "Mover"
            case .arrow: return "Flecha"
            case .rectangle: return "Rectángulo"
            case .ellipse: return "Elipse"
            case .pen: return "Lápiz"
            case .highlight: return "Resaltador"
            case .text: return "Texto"
            case .number: return "Número"
            case .magnifier: return "Lupa"
            case .image: return "Imagen"
            }
        }
        var hint: String {
            switch self {
            case .select: return "Haz clic en una anotación para elegirla y arrástrala para moverla. ⌫ la borra."
            case .arrow: return "Arrastra desde la cola hasta la punta de la flecha."
            case .rectangle, .ellipse: return "Arrastra para dibujar la forma."
            case .pen: return "Dibuja a mano alzada."
            case .highlight: return "Pasa por encima para resaltar, como un rotulador."
            case .text: return "Haz clic donde quieras el texto y escríbelo abajo."
            case .number: return "Cada clic pone el número siguiente: 1, 2, 3…"
            case .magnifier: return "Haz clic en la zona a ampliar y arrastra para cambiar el tamaño de la lupa."
            case .image: return "Haz clic donde quieras poner la imagen elegida."
            }
        }
    }

    let image: CGImage
    @Published var annotations: [Annotation] = []
    @Published var selected: UUID?
    @Published var tool: Tool = .arrow { didSet { if tool == .image { chooseImage() } } }
    @Published var colorIndex = 0 { didSet { restyleSelected() } }
    @Published var size: CGFloat = 5 { didSet { restyleSelected() } }
    private var undoStack: [[Annotation]] = []
    private var pendingImage: NSImage?

    init?(url: URL) {
        guard let image = EditorImage.load(url) else { return nil }
        self.image = image
    }

    var color: NSColor { MarkupPalette.colors[colorIndex] }
    var canUndo: Bool { !undoStack.isEmpty }
    var selectedIndex: Int? { annotations.firstIndex { $0.id == selected } }

    func checkpoint() {
        undoStack.append(annotations)
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        annotations = last
        if selectedIndex == nil { selected = nil }
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        checkpoint()
        annotations.remove(at: i)
        selected = nil
    }

    func reset() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations = []
        selected = nil
    }

    func add(_ kind: Annotation.Kind) {
        checkpoint()
        let a = Annotation(kind: kind, color: color, size: size)
        annotations.append(a)
        selected = a.id
    }

    func nextNumber() -> Int {
        annotations.reduce(0) { if case .number(_, let n) = $1.kind { return max($0, n) } else { return $0 } } + 1
    }

    func placeImage(at p: CGPoint) {
        guard let img = pendingImage else { chooseImage(); return }
        add(.image(p, 0.3, img))
    }

    /// El texto de la anotación elegida (si es un texto).
    var selectedText: String? {
        guard let i = selectedIndex, case .text(_, let s) = annotations[i].kind else { return nil }
        return s
    }

    func setSelectedText(_ text: String) {
        guard let i = selectedIndex, case .text(let p, _) = annotations[i].kind else { return }
        annotations[i].kind = .text(p, text)
    }

    /// Con «Mover» y algo elegido, cambiar color o grosor se le aplica. Con las demás herramientas solo cambia
    /// lo que vas a dibujar (no lo último que dibujaste).
    private func restyleSelected() {
        guard tool == .select, let i = selectedIndex else { return }
        annotations[i].color = color
        annotations[i].size = size
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Elige la imagen que quieres poner encima"
        panel.prompt = "Elegir"
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            pendingImage = img
        } else if pendingImage == nil {
            tool = .select
        }
    }
}

// MARK: - Lienzo

struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var model: AnnotateModel
    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ view: CanvasView, context: Context) { view.needsDisplay = true }

    final class CanvasView: NSView {
        private let model: AnnotateModel
        /// Lo que se está dibujando ahora mismo (antes de soltar el ratón).
        private var draft: Annotation?
        private var start: CGPoint = .zero
        private var lastPoint: CGPoint = .zero
        private var moved = false

        init(model: AnnotateModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        private var imageRect: CGRect { EditorImage.fit(model.image, in: bounds, inset: DesignTokens.Spacing.m) }

        private func normalized(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil), r = imageRect
            return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = imageRect
            MarkupRenderer.drawImage(model.image, in: rect)
            var all = model.annotations
            if let draft { all.append(draft) }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            MarkupRenderer.draw(all, image: model.image, in: rect)
            NSGraphicsContext.restoreGraphicsState()
            // Recuadro discontinuo alrededor de lo elegido.
            if let i = model.selectedIndex {
                let box = MarkupRenderer.bounds(of: model.annotations[i], in: rect, image: model.image).insetBy(dx: -3, dy: -3)
                let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                path.lineWidth = 1.5
                path.setLineDash([5, 4], count: 2, phase: 0)
                NSColor(srgbRed: 0, green: 0.75, blue: 1, alpha: 1).setStroke()
                path.stroke()
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let p = normalized(event)
            start = p; lastPoint = p; moved = false
            switch model.tool {
            case .select:
                let local = convert(event.locationInWindow, from: nil)
                let hit = model.annotations.last { MarkupRenderer.bounds(of: $0, in: imageRect, image: model.image).contains(local) }
                model.selected = hit?.id
                if hit != nil { model.checkpoint() }
            case .arrow: draft = Annotation(kind: .arrow(p, p), color: model.color, size: model.size)
            case .rectangle: draft = Annotation(kind: .rectangle(p, p), color: model.color, size: model.size)
            case .ellipse: draft = Annotation(kind: .ellipse(p, p), color: model.color, size: model.size)
            case .pen: draft = Annotation(kind: .pen([p]), color: model.color, size: model.size)
            case .highlight: draft = Annotation(kind: .highlight([p]), color: model.color, size: model.size)
            case .text:
                model.add(.text(p, "Texto"))
            case .number:
                model.add(.number(p, model.nextNumber()))
            case .magnifier:
                model.add(.magnifier(p, 0.08, 2))
            case .image:
                model.placeImage(at: p)
            }
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            let p = normalized(event)
            moved = true
            switch model.tool {
            case .select:
                guard let i = model.selectedIndex else { return }
                model.annotations[i].move(by: CGVector(dx: p.x - lastPoint.x, dy: p.y - lastPoint.y))
            case .arrow: draft?.kind = .arrow(start, p)
            case .rectangle: draft?.kind = .rectangle(start, p)
            case .ellipse: draft?.kind = .ellipse(start, p)
            case .pen: if case .pen(let ps) = draft?.kind { draft?.kind = .pen(ps + [p]) }
            case .highlight: if case .highlight(let ps) = draft?.kind { draft?.kind = .highlight(ps + [p]) }
            case .magnifier:
                // Arrastrar cambia el tamaño de la lupa recién puesta.
                guard let i = model.selectedIndex, case .magnifier(let c, _, let z) = model.annotations[i].kind else { return }
                let r = CGFloat(image: model.image, distance: CGPoint(x: p.x - c.x, y: p.y - c.y))
                model.annotations[i].kind = .magnifier(c, min(0.4, max(0.03, r)), z)
            case .image:
                guard let i = model.selectedIndex else { return }
                model.annotations[i].move(by: CGVector(dx: p.x - lastPoint.x, dy: p.y - lastPoint.y))
            case .text, .number:
                guard let i = model.selectedIndex else { return }
                model.annotations[i].move(by: CGVector(dx: p.x - lastPoint.x, dy: p.y - lastPoint.y))
            }
            lastPoint = p
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            defer { draft = nil; needsDisplay = true }
            guard var finished = draft else { return }
            // Un clic sin arrastrar no crea formas vacías.
            let p = normalized(event)
            guard moved, hypot(p.x - start.x, p.y - start.y) > 0.004 || isStroke(finished) else { return }
            finished.color = model.color
            model.checkpoint()
            model.annotations.append(finished)
            model.selected = finished.id
        }

        private func isStroke(_ a: Annotation) -> Bool {
            if case .pen(let ps) = a.kind { return ps.count > 2 }
            if case .highlight(let ps) = a.kind { return ps.count > 2 }
            return false
        }

        override func keyDown(with event: NSEvent) {
            // ⌫ o Suprimir borran lo elegido; ⌘Z deshace.
            if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelected(); needsDisplay = true; return }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { model.undo(); needsDisplay = true; return }
            super.keyDown(with: event)
        }
    }
}

private extension CGFloat {
    /// Distancia en coordenadas 0…1 convertida a fracción del lado mayor (como el radio de la lupa).
    init(image: CGImage, distance d: CGPoint) {
        let w = CGFloat(image.width), h = CGFloat(image.height), m = Swift.max(w, h)
        self = hypot(d.x * w, d.y * h) / m
    }
}

// MARK: - Ventana

struct AnnotateEditorView: View {
    @ObservedObject var model: AnnotateModel
    var title = "Anotar foto"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias MK = DesignTokens.Markup

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                AnnotationCanvas(model: model)
                    .frame(width: MK.canvasSize.width, height: MK.canvasSize.height)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                        .fill(Color.black.opacity(0.35)))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))

                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(AnnotateModel.Tool.allCases) { tool in toolButton(tool) }
                }

                HStack(spacing: DesignTokens.Spacing.m) {
                    ColorDots(selection: $model.colorIndex)
                    Divider().frame(height: 18)
                    Text("Grosor").textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                    Slider(value: $model.size, in: 2...14).controlSize(.small).frame(width: MK.sizeSliderWidth)
                        .accessibilityLabel("Grosor")
                    Spacer()
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.fluxioSecondary).disabled(!model.canUndo)
                        .help("Deshacer (⌘Z)").accessibilityLabel("Deshacer")
                    Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(.fluxioSecondary).disabled(model.selected == nil)
                        .help("Borrar lo elegido (⌫)").accessibilityLabel("Borrar la anotación elegida")
                }

                if let text = model.selectedText {
                    HStack(spacing: DesignTokens.Spacing.s) {
                        Text("Texto").textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                        TextField("Escribe el texto", text: Binding(get: { text }, set: { model.setSelectedText($0) }))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, DesignTokens.Spacing.s)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                                .fill(DesignTokens.Colors.recessed))
                    }
                } else {
                    Text(model.tool.hint)
                        .textStyle(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(height: 26, alignment: .leading)
                }
            }
        } footer: {
            Button("Restablecer") { model.reset() }
                .buttonStyle(.fluxioSecondary).disabled(model.annotations.isEmpty)
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Guardar copia anotada", action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.fluxioPrimary)
                .disabled(model.annotations.isEmpty)
        }
    }

    private func toolButton(_ tool: AnnotateModel.Tool) -> some View {
        let on = model.tool == tool
        return Button { model.tool = tool } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: MK.toolSize.width, height: MK.toolSize.height)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                    .fill(on ? AnyShapeStyle(DesignTokens.Colors.accentGradient) : AnyShapeStyle(DesignTokens.Colors.recessed)))
                .foregroundStyle(on ? DesignTokens.Colors.onAccent : DesignTokens.Colors.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Fila de colores para elegir (anotar y tapar).
struct ColorDots: View {
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(MarkupPalette.colors.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Circle().fill(Color(nsColor: MarkupPalette.colors[i]))
                        .frame(width: DesignTokens.Markup.colorDot, height: DesignTokens.Markup.colorDot)
                        .overlay(Circle().strokeBorder(Color.white.opacity(selection == i ? 0.95 : 0.15),
                                                       lineWidth: selection == i ? 2 : 1))
                        .padding(2)
                        .overlay(Circle().strokeBorder(DesignTokens.Colors.accent.opacity(selection == i ? 1 : 0), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(i + 1)")
                .accessibilityAddTraits(selection == i ? .isSelected : [])
            }
        }
    }
}
