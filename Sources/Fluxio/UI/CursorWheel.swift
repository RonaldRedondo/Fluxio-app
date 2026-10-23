import AppKit
import Combine

/// Rueda que aparece junto al cursor, en cualquier parte de la pantalla:
/// - al arrastrar archivos manteniendo la tecla de activación (⌥ por defecto),
/// - desde el clic derecho de Finder ("Convertir con Fluxio") o el atajo ⌃⌥F.
@MainActor
final class CursorWheelController {
    let coordinator = DropCoordinator()
    private let panel: CursorWheelPanel
    private let settings = AppSettings.shared
    private var monitors: [Any] = []
    private var phaseObserver: AnyCancellable?

    // Estado del arrastre en curso (en otra app, normalmente Finder).
    private var dragChangeCount = 0
    private var mouseIsDown = false
    private var shownForThisDrag = false
    private var pollTimer: Timer?

    init() {
        panel = CursorWheelPanel(coordinator: coordinator)
        coordinator.keepWheelOnExit = true
        coordinator.onNeedsKeyFocus = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.panel.makeKeyAndOrderFront(nil)
        }
        // Cuando todo termina (resultado cerrado o arrastre cancelado), la ventana se oculta.
        phaseObserver = coordinator.$phase.sink { [weak self] phase in
            guard phase == .idle else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let self, self.coordinator.phase == .idle else { return }
                self.panel.orderOut(nil)
            }
        }
        startMonitoring()
    }

    // MARK: Abrir la rueda

    /// Muestra la rueda centrada en el cursor, lista para elegir con ratón o teclado.
    func present(urls: [URL]) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        placeAtCursor()
        panel.orderFrontRegardless()
        coordinator.present(urls: urls)
    }

    private func showDuringDrag(urls: [URL]) {
        placeAtCursor()
        // La rueda se dibuja antes de que el cursor "entre", para que la ventana reciba el arrastre.
        guard coordinator.dragEntered(urls: urls, modifiers: NSEvent.modifierFlags) else { return }
        panel.orderFrontRegardless()
    }

    private func placeAtCursor() {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        // El centro de la rueda (el cuadrado de abajo de la ventana) queda bajo el cursor.
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.width / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: Detectar arrastres de archivos en todo el sistema

    /// Solo se observa el ratón (no el teclado), así que no hace falta ningún permiso especial.
    private func startMonitoring() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDrag() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        monitors = [down, dragged, up].compactMap { $0 }
    }

    private func mouseDown() {
        mouseIsDown = true
        shownForThisDrag = false
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        // Si sueltas el ratón quieto y pulsas la tecla, no llegan eventos: revisamos cada décima de segundo.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDrag() }
        }
    }

    private func checkDrag() {
        guard mouseIsDown, !shownForThisDrag, settings.cursorWheelEnabled else { return }
        guard NSEvent.modifierFlags.contains(settings.cursorTrigger.flag) else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragChangeCount else { return }   // no es un arrastre nuevo
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return }
        shownForThisDrag = true
        showDuringDrag(urls: urls)
    }

    private func mouseUp() {
        mouseIsDown = false
        pollTimer?.invalidate()
        pollTimer = nil
        // Soltado fuera de la rueda: se cierra. (Si se soltó encima, la rueda ya habrá cambiado de estado.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.coordinator.phase == .choosing(pinned: false) else { return }
            self.coordinator.keepWheelOnExit = false
            self.coordinator.dragExited()
            self.coordinator.keepWheelOnExit = true
        }
    }
}

/// Ventana transparente para la rueda junto al cursor. No roba el foco a la app en la que estás.
final class CursorWheelPanel: NSPanel {
    init(coordinator: DropCoordinator) {
        let side = DesignTokens.Wheel.windowSide
        let height = side + DesignTokens.Wheel.categoryBand
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        title = "Fluxio"
        setAccessibilityLabel("Rueda de Fluxio")

        let view = DropView(coordinator: coordinator, compact: true)
        view.frame = NSRect(x: 0, y: 0, width: side, height: height)
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}
