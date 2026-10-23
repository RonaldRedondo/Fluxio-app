import AppKit
import SwiftUI

/// Ocultar zonas: tapar con un color o desenfocar caras, matrículas, textos… Las zonas se mueven y se cambian de
/// tamaño por las esquinas; «Caras» y «Texto» las encuentran solas (sin internet).
@MainActor
final class RedactModel: ObservableObject {
    @Published var plan = RedactionPlan()
    @Published var selected: Int?
    @Published var colorIndex = 7 { didSet { plan.color = MarkupPalette.colors[colorIndex] } }
    @Published private(set) var blurred: CGImage?
    @Published private(set) var detecting = false
    @Published var notice: String?
    let image: CGImage

    init?(url: URL) {
        guard let image = EditorImage.load(url) else { return nil }
        self.image = image
        plan.color = MarkupPalette.colors[colorIndex]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let b = RedactionPlan.blurredCopy(of: image)
            DispatchQueue.main.async { self?.blurred = b }
        }
    }

    func deleteSelected() {
        guard let i = selected, plan.areas.indices.contains(i) else { return }
        plan.areas.remove(at: i)
        selected = nil
    }

    func reset() { plan.areas = []; selected = nil; notice = nil }

    /// Busca caras o textos y añade una zona por cada uno (sin repetir las que ya están).
    func detect(faces: Bool) {
        detecting = true
        notice = nil
        let image = self.image
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = RedactionPlan.detect(faces: faces, in: image)
            DispatchQueue.main.async {
                guard let self else { return }
                self.detecting = false
                let fresh = found.filter { box in !self.plan.areas.contains { $0.intersection(box).area > box.area * 0.6 } }
                withAnimation(DesignTokens.Motion.toast) { self.plan.areas += fresh }
                if found.isEmpty { self.notice = faces ? "No encontré caras." : "No encontré texto." }
                else { self.notice = faces ? "\(found.count) cara(s) encontradas." : "\(found.count) texto(s) encontrados." }
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

struct RedactCanvas: NSViewRepresentable {
    @ObservedObject var model: RedactModel
    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ view: CanvasView, context: Context) { view.needsDisplay = true }

    final class CanvasView: NSView {
        private enum Drag { case none, create(CGPoint), move(Int, CGPoint), resize(Int, corner: Int) }
        private let model: RedactModel
        private var drag = Drag.none

        init(model: RedactModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        private var imageRect: CGRect { EditorImage.fit(model.image, in: bounds, inset: DesignTokens.Spacing.m) }
        private let handle: CGFloat = 9

        private func normalized(_ p: CGPoint) -> CGPoint {
            let r = imageRect
            return CGPoint(x: min(1, max(0, (p.x - r.minX) / r.width)), y: min(1, max(0, (p.y - r.minY) / r.height)))
        }

        private func screen(_ a: CGRect) -> CGRect {
            let r = imageRect
            return CGRect(x: r.minX + a.minX * r.width, y: r.minY + a.minY * r.height, width: a.width * r.width, height: a.height * r.height)
        }

        private func corners(_ box: CGRect) -> [CGPoint] {
            [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
             CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = imageRect
            MarkupRenderer.drawImage(model.image, in: rect)
            model.plan.draw(over: rect, blurred: model.blurred)
            let accent = NSColor(srgbRed: 0, green: 0.75, blue: 1, alpha: 1)
            for (i, area) in model.plan.areas.enumerated() {
                let box = screen(area)
                let border = NSBezierPath(rect: box)
                border.lineWidth = i == model.selected ? 2 : 1
                (i == model.selected ? accent : NSColor.white.withAlphaComponent(0.5)).setStroke()
                border.stroke()
                guard i == model.selected else { continue }
                for c in corners(box) {
                    let h = NSBezierPath(roundedRect: CGRect(x: c.x - handle / 2, y: c.y - handle / 2, width: handle, height: handle),
                                         xRadius: 2, yRadius: 2)
                    accent.setFill(); h.fill()
                    NSColor.white.setStroke(); h.lineWidth = 1; h.stroke()
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let local = convert(event.locationInWindow, from: nil)
            // ¿Una esquina de la zona elegida?
            if let i = model.selected, model.plan.areas.indices.contains(i) {
                for (k, c) in corners(screen(model.plan.areas[i])).enumerated() where hypot(c.x - local.x, c.y - local.y) < handle * 1.4 {
                    drag = .resize(i, corner: k); return
                }
            }
            if let i = model.plan.areas.indices.last(where: { screen(model.plan.areas[$0]).contains(local) }) {
                model.selected = i
                drag = .move(i, normalized(local))
            } else {
                model.selected = nil
                drag = .create(normalized(local))
            }
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            let p = normalized(convert(event.locationInWindow, from: nil))
            switch drag {
            case .none: return
            case .create(let start):
                let box = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                guard box.width > 0.005 || box.height > 0.005 else { return }
                model.plan.areas.append(box)
                let i = model.plan.areas.count - 1
                model.selected = i
                drag = .resize(i, corner: p.x >= start.x ? (p.y >= start.y ? 3 : 1) : (p.y >= start.y ? 2 : 0))
            case .move(let i, let last):
                var a = model.plan.areas[i]
                a.origin.x = min(1 - a.width, max(0, a.origin.x + p.x - last.x))
                a.origin.y = min(1 - a.height, max(0, a.origin.y + p.y - last.y))
                model.plan.areas[i] = a
                drag = .move(i, p)
            case .resize(let i, let corner):
                let a = model.plan.areas[i]
                // La esquina contraria queda fija.
                let fixed = CGPoint(x: corner % 2 == 0 ? a.maxX : a.minX, y: corner < 2 ? a.maxY : a.minY)
                model.plan.areas[i] = CGRect(x: min(fixed.x, p.x), y: min(fixed.y, p.y),
                                             width: max(0.01, abs(p.x - fixed.x)), height: max(0.01, abs(p.y - fixed.y)))
                // Si cruzas la esquina contraria, el asa que arrastras cambia.
                let k = (p.x >= fixed.x ? 1 : 0) + (p.y >= fixed.y ? 2 : 0)
                drag = .resize(i, corner: k)
            }
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) { drag = .none }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelected(); needsDisplay = true; return }
            super.keyDown(with: event)
        }
    }
}

struct RedactEditorView: View {
    @ObservedObject var model: RedactModel
    var title = "Ocultar zonas"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private typealias MK = DesignTokens.Markup

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                RedactCanvas(model: model)
                    .frame(width: MK.canvasSize.width, height: MK.canvasSize.height)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous).fill(Color.black.opacity(0.35)))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))

                HStack(spacing: DesignTokens.Spacing.m) {
                    Picker("Estilo", selection: $model.plan.style) {
                        ForEach(RedactionPlan.Style.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: MK.stylePickerWidth)
                    if model.plan.style == .solid { ColorDots(selection: $model.colorIndex) }
                    Spacer()
                }
                HStack(spacing: DesignTokens.Spacing.s) {
                    Text("Encontrar solas:").textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                    Button { model.detect(faces: true) } label: { Label("Caras", systemImage: "face.smiling") }
                        .buttonStyle(.fluxioSecondary).disabled(model.detecting)
                    Button { model.detect(faces: false) } label: { Label("Texto", systemImage: "text.viewfinder") }
                        .buttonStyle(.fluxioSecondary).disabled(model.detecting)
                    Spacer()
                    Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(.fluxioSecondary).disabled(model.selected == nil)
                        .help("Borrar la zona elegida (⌫)").accessibilityLabel("Borrar la zona elegida")
                }

                Text(model.notice ?? "Arrastra sobre la foto para tapar una zona. Muévela o cambia su tamaño por las esquinas.")
                    .textStyle(DesignTokens.Typography.caption)
                    .foregroundStyle(model.notice == nil ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.accent)
                    .frame(height: 18, alignment: .leading)
            }
        } footer: {
            Button("Restablecer") { model.reset() }.buttonStyle(.fluxioSecondary).disabled(model.plan.areas.isEmpty)
            Spacer()
            Button("Cancelar", action: onCancel).buttonStyle(.fluxioSecondary)
            Button("Guardar copia oculta", action: onConfirm)
                .keyboardShortcut(.defaultAction).buttonStyle(.fluxioPrimary).disabled(model.plan.areas.isEmpty)
        }
    }
}
