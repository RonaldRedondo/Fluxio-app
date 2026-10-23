import AppKit

/// Avisa cuando estás arrastrando archivos por la pantalla (desde Finder, el Escritorio…), aunque todavía
/// no estén sobre Fluxio: la tarjeta "Suelta aquí" lo usa para invitarte a soltar.
///
/// No necesita permisos ni gasta nada en reposo: solo escucha mientras arrastras con el ratón.
@MainActor
final class FileDragWatcher {
    var onChange: (Bool) -> Void = { _ in }
    private(set) var isDraggingFiles = false
    private var monitors: [Any] = []
    private var lastChangeCount = NSPasteboard(name: .drag).changeCount
    private var endTimer: Timer?

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged, handler: { event in handler(event); return event }) {
            monitors.append(local)
        }
    }

    private func mouseDragged() {
        guard !isDraggingFiles else { return }
        // Un arrastre nuevo cambia el portapapeles de arrastre; solo cuentan los que llevan archivos.
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount
        guard board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        set(true)
        // Mientras dura el arrastre se mira si ya se soltó el botón (Finder se queda con los eventos del ratón).
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self?.endTimer?.invalidate()
                self?.endTimer = nil
                self?.set(false)
            }
        }
    }

    private func set(_ value: Bool) {
        guard value != isDraggingFiles else { return }
        isDraggingFiles = value
        onChange(value)
    }
}
