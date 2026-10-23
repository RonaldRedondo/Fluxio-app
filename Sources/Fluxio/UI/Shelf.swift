import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Estante flotante ("Float" en la rueda Ctrl)
//
// Una tarjeta pequeña que flota sobre todas las ventanas con los archivos que dejaste. Desde ella se
// arrastran (todos juntos o uno a uno) a cualquier app, se pueden soltar más encima, y si la acercas al
// borde de la pantalla se pega a él. Puede haber varios estantes a la vez.

@MainActor
final class ShelfController {
    static let shared = ShelfController()
    private var windows: [ShelfWindow] = []

    /// Abre un estante nuevo junto a `point` (coordenadas de pantalla).
    func open(_ urls: [URL], near point: NSPoint) {
        guard !urls.isEmpty else { return }
        let window = ShelfWindow(urls: urls) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        window.place(near: point)
        windows.append(window)
        window.orderFrontRegardless()
    }
}

@MainActor
final class ShelfModel: ObservableObject {
    @Published var urls: [URL]
    @Published var expanded = false
    init(urls: [URL]) { self.urls = urls }

    /// Añade archivos sin repetir los que ya están.
    func add(_ new: [URL]) {
        let fresh = new.filter { !urls.contains($0) }
        guard !fresh.isEmpty else { return }
        withAnimation(DesignTokens.Motion.toast) { urls.append(contentsOf: fresh) }
    }

    func remove(_ url: URL) {
        withAnimation(DesignTokens.Motion.toast) { urls.removeAll { $0 == url } }
    }
}

final class ShelfWindow: NSPanel {
    private let model: ShelfModel
    private let onClose: (ShelfWindow) -> Void

    @MainActor
    init(urls: [URL], onClose: @escaping (ShelfWindow) -> Void) {
        model = ShelfModel(urls: urls)
        self.onClose = onClose
        let size = DesignTokens.Shelf.windowSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "Estante de Fluxio"
        let view = ShelfView(model: model,
                             onClose: { [weak self] in self?.closeShelf() },
                             onMoved: { [weak self] in self?.snapToEdge() })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// A la derecha y un poco por encima del cursor, sin salirse de la pantalla.
    @MainActor
    func place(near point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        var origin = NSPoint(x: point.x + DesignTokens.Shelf.cursorGap, y: point.y - size.height + DesignTokens.Shelf.cardHeight / 2)
        let inset = DesignTokens.Shelf.edgeMargin - DesignTokens.Shelf.shadowMargin
        origin.x = min(max(origin.x, visible.minX + inset), visible.maxX - size.width - inset)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        setFrameOrigin(origin)
    }

    /// Si lo sueltas cerca de un borde de la pantalla, se pega a él.
    @MainActor
    func snapToEdge() {
        guard let visible = screen?.visibleFrame else { return }
        // La tarjeta está `shadowMargin` por dentro de la ventana: se mide y se pega con la tarjeta, no con la ventana.
        let margin = DesignTokens.Shelf.edgeMargin - DesignTokens.Shelf.shadowMargin
        let reach = DesignTokens.Shelf.snapDistance + DesignTokens.Shelf.shadowMargin
        var target = frame
        if frame.minX - visible.minX < reach { target.origin.x = visible.minX + margin }
        else if visible.maxX - frame.maxX < reach { target.origin.x = visible.maxX - frame.width - margin }
        else { return }
        if DesignTokens.Motion.reduceMotion { setFrame(target, display: true) }
        else { setFrame(target, display: true, animate: true) }
    }

    @MainActor
    private func closeShelf() {
        orderOut(nil)
        onClose(self)
    }
}

// MARK: - Vista

private typealias SH = DesignTokens.Shelf

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let onClose: () -> Void
    let onMoved: () -> Void
    @StateObject private var targeted = ViewState(false)

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: SH.closeIcon, weight: .bold))
                        .frame(width: SH.closeSize, height: SH.closeSize)
                        .background(Circle().fill(DesignTokens.Colors.recessed))
                        .frame(width: SH.closeTarget, height: SH.closeTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .help("Cerrar el estante")
                .accessibilityLabel("Cerrar el estante")
                Spacer()
            }

            // El montón: arrástralo para llevarte todos los archivos.
            FloatingFileStack(files: model.urls, leanAngle: nil, side: SH.pileSize, floats: false)
                // El clip va a la izquierda (a la derecha está el número de archivos).
                .overlay(alignment: .topLeading) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.accentGradient)
                        .rotationEffect(.degrees(-28))
                        .offset(x: -4, y: -8)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .overlay(FileDragSource(urls: model.urls, onDoubleClick: { open(model.urls) }))
                .help("Arrastra para llevarte los archivos a otra app")
                .accessibilityElement()
                .accessibilityLabel("\(model.urls.count) archivo(s) en el estante")

            Button {
                withAnimation(DesignTokens.Motion.toast) { model.expanded.toggle() }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.expanded ? 0 : 180))
                    Text(model.urls.count == 1 ? "1 archivo" : "\(model.urls.count) archivos")
                        .monospacedDigit()
                }
                .textStyle(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.expanded ? "Ocultar la lista" : "Ver la lista de archivos")

            if model.expanded {
                Rectangle().fill(DesignTokens.Colors.border).frame(height: DesignTokens.Stroke.hairline)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DesignTokens.Spacing.m) {
                        ForEach(model.urls, id: \.self) { url in
                            ShelfRow(url: url, onRemove: { model.remove(url) }, onOpen: { open([url]) })
                                .transition(.blurScale)
                        }
                    }
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
                .frame(maxHeight: SH.listMaxHeight)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DesignTokens.Spacing.s)
        .frame(width: SH.cardWidth)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.largeCard, style: .continuous))
                    .keySurface(radius: DesignTokens.Radius.largeCard)
                    .floatingShadow()
                // El fondo de la tarjeta sirve para moverla (y al soltarla cerca del borde se pega).
                WindowDragArea(onMoved: onMoved)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.largeCard, style: .continuous)
                .strokeBorder(DesignTokens.Colors.accentGradient, lineWidth: DesignTokens.Panel.inviteStroke)
                .opacity(targeted.value ? 1 : 0)
        )
        .scaleEffect(targeted.value && !DesignTokens.Motion.reduceMotion ? SH.targetScale : 1)
        .animation(DesignTokens.Motion.invite, value: targeted.value)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { targeted.value }, set: { targeted.value = $0 })) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.add([url]) }
                }
            }
            return true
        }
        .padding(SH.shadowMargin)
        .frame(width: SH.windowSize.width, height: SH.windowSize.height, alignment: .top)
    }

    private func open(_ urls: [URL]) {
        urls.forEach { NSWorkspace.shared.open($0) }
    }
}

/// Un archivo de la lista: miniatura y nombre. Se arrastra solo; al pasar el ratón aparece la ✕ para quitarlo.
private struct ShelfRow: View {
    let url: URL
    let onRemove: () -> Void
    let onOpen: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            FloatingFileStack(files: [url], leanAngle: nil, side: SH.rowThumbSize, floats: false)
                .overlay(FileDragSource(urls: [url], onDoubleClick: onOpen))
                .overlay(alignment: .topTrailing) {
                    if hover.isOn {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(DesignTokens.Colors.textPrimary, DesignTokens.Colors.recessed)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .help("Quitar del estante (no borra el archivo)")
                        .accessibilityLabel("Quitar \(url.lastPathComponent) del estante")
                    }
                }
            Text(url.lastPathComponent)
                .textStyle(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .onHover { hover.isOn = $0 }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Arrastrar archivos hacia fuera

/// Zona invisible que, al arrastrarla, se lleva estos archivos a otra app (como arrastrarlos desde Finder).
/// Doble clic los abre.
private struct FileDragSource: NSViewRepresentable {
    let urls: [URL]
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ view: DragSourceView, context: Context) {
        view.urls = urls
        view.onDoubleClick = onDoubleClick
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var urls: [URL] = []
        var onDoubleClick: () -> Void = {}
        private var downPoint: NSPoint?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick(); return }
            downPoint = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = downPoint, !urls.isEmpty else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            downPoint = nil
            let items: [NSDraggingItem] = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let side = DesignTokens.Shelf.dragIconSize
                let local = convert(event.locationInWindow, from: nil)
                item.setDraggingFrame(NSRect(x: local.x - side / 2 + CGFloat(index) * 4, y: local.y - side / 2 - CGFloat(index) * 4,
                                             width: side, height: side), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) { downPoint = nil }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Hacia otra app: se copian (o se enlazan, según la app). Nunca se borran del estante.
            context == .outsideApplication ? [.copy, .generic, .link] : [.copy, .generic]
        }
    }
}

/// Fondo que mueve la ventana al arrastrarlo; al soltar avisa (para pegarla al borde si hace falta).
struct WindowDragArea: NSViewRepresentable {
    var onMoved: () -> Void = {}
    func makeNSView(context: Context) -> MoveView { MoveView() }
    func updateNSView(_ view: MoveView, context: Context) { view.onMoved = onMoved }

    final class MoveView: NSView {
        var onMoved: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)   // vuelve cuando sueltas el ratón
            onMoved()
        }
    }
}
