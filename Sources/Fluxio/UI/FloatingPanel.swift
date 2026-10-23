import AppKit
import SwiftUI

/// Ventana flotante, sin bordes y siempre visible, donde se sueltan los archivos.
final class FloatingPanel: NSPanel {
    init(coordinator: DropCoordinator) {
        let side = DesignTokens.Wheel.windowSide
        let height = side + DesignTokens.Wheel.categoryBand
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "Fluxio"
        setAccessibilityLabel("Fluxio: suelta archivos aquí")

        let dropView = DropView(coordinator: coordinator)
        dropView.frame = NSRect(x: 0, y: 0, width: side, height: height)
        contentView = dropView

        if !setFrameUsingName("FluxioPanel") { placeBottomRight() }
        // Un tamaño guardado de antes (sin la franja de la categoría): se crece hacia arriba, la rueda no se mueve.
        if frame.size != NSSize(width: side, height: height) {
            setFrame(NSRect(origin: frame.origin, size: NSSize(width: side, height: height)), display: false)
        }
        setFrameAutosaveName("FluxioPanel")
    }

    override var canBecomeKey: Bool { true }

    private func placeBottomRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.minY + 24))
    }
}

/// Vista que recibe el arrastre de archivos y contiene la interfaz SwiftUI.
final class DropView: NSView {
    private let coordinator: DropCoordinator
    private var keyMonitor: Any?

    init(coordinator: DropCoordinator, compact: Bool = false) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])

        let hosting = FirstMouseHostingView(rootView: PanelRootView(coordinator: coordinator, compact: compact))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override var isFlipped: Bool { true }

    /// Centro de la rueda: el cuadrado de abajo (encima queda la franja de la categoría).
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.height - bounds.width / 2) }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    /// Pedimos "copiar" para que Finder nunca mueva ni borre el original.
    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        for op in [NSDragOperation.copy, .generic, .link, .move] where mask.contains(op) { return op }
        return .copy
    }

    // MARK: Arrastre

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Punto de entrada (0…1 dentro de la ventana): la rueda nace de ahí.
        let point = convert(sender.draggingLocation, from: nil)
        let band = bounds.height - bounds.width
        let anchor = UnitPoint(x: bounds.width > 0 ? point.x / bounds.width : 0.5,
                               y: bounds.width > 0 ? min(1, max(0, (point.y - band) / bounds.width)) : 0.5)
        guard coordinator.dragEntered(urls: fileURLs(from: sender), modifiers: NSEvent.modifierFlags, at: anchor) else { return [] }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard coordinator.isWheelVisible else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        coordinator.dragUpdated(location: point, center: center, modifiers: NSEvent.modifierFlags)
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator.dragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard coordinator.isWheelVisible else { return false }
        // Se ejecuta un instante después para que Finder termine el arrastre limpiamente.
        DispatchQueue.main.async { [coordinator] in coordinator.dropped() }
        return true
    }

    // MARK: Teclado

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            if coordinator.phase == .idle { return false }
            if coordinator.isInSubmenu { coordinator.leaveSubmenu(); return true }   // de "Más…" a la rueda principal
            coordinator.cancel()
            if case .done = coordinator.phase { coordinator.dismissResult() }
            if case .failed = coordinator.phase { coordinator.dismissResult() }
            return true
        default:
            break
        }
        guard coordinator.isPinned else { return false }
        switch event.keyCode {
        case 123, 126: coordinator.moveHighlight(by: -1)   // ← ↑
        case 124, 125: coordinator.moveHighlight(by: 1)    // → ↓
        case 36, 76: coordinator.confirmHighlighted()       // Enter
        case 48: coordinator.nextMode()                     // Tab: cambiar de rueda
        default: return false
        }
        return true
    }
}

/// Permite pulsar botones aunque la ventana no esté activa.
/// Tampoco acepta arrastres: así llegan siempre a `DropView`.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        unregisterDraggedTypes()
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}
