import AppKit

/// Los dos modos de la interfaz.
enum InterfaceMode: String {
    /// La rueda radial y la ventana flotante.
    case lite
    /// La ventana de gestión de archivos.
    case full
}

/// Cambia entre los modos Lite y Completo con la animación de "ventana que se transforma",
/// y recuerda el último modo usado. La cola de archivos no se toca: los dos modos la comparten.
@MainActor
final class ModeSwitcher {
    private let panel: NSPanel
    private let full: FullModeWindowController
    private var isAnimating = false
    private static let key = "interfaceMode"

    private(set) var mode: InterfaceMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    init(panel: NSPanel, full: FullModeWindowController) {
        self.panel = panel
        self.full = full
        mode = UserDefaults.standard.string(forKey: Self.key).flatMap(InterfaceMode.init(rawValue:)) ?? .lite
        // Si cierras la ventana Completa con su botón rojo, Fluxio sigue en la barra de menú en modo Lite.
        full.onClose = { [weak self] in
            guard let self else { return }
            self.mode = .lite
            self.panel.orderFrontRegardless()
        }
    }

    /// Al abrir Fluxio: el último modo usado.
    func restoreAtLaunch(showPanel: Bool) {
        switch mode {
        case .full: full.show()
        case .lite: if showPanel { panel.orderFrontRegardless() }
        }
    }

    func toggle() {
        switchTo(mode == .full && full.isVisible ? .lite : .full)
    }

    func switchTo(_ target: InterfaceMode) {
        guard !isAnimating else { return }
        switch target {
        case .full:
            if full.isVisible { full.show(); mode = .full; return }
            if panel.isVisible { animateToFull() } else { full.show() }
            mode = .full
        case .lite:
            if full.isVisible { animateToLite() } else { panel.orderFrontRegardless() }
            mode = .lite
        }
    }

    // MARK: Animaciones

    private func animateToLite() {
        let window = full.prepare()
        guard !DesignTokens.Motion.reduceMotion,
              let from = WindowMorph.snapshot(of: window, trimTransparent: false, includeFrame: true),
              let to = WindowMorph.snapshot(of: panel, trimTransparent: true) else {
            WindowMorph.crossfade(from: window, to: panel, show: { panel.orderFrontRegardless() }) {
                NSApp.setActivationPolicy(.accessory)
            }
            return
        }
        isAnimating = true
        // La tarjeta ya está en su sitio, invisible: al final solo aparece (sin saltos).
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        WindowMorph.run(from: from, fromRadius: DesignTokens.FullMode.windowCornerRadius,
                        to: to, toRadius: DesignTokens.Radius.largeCard, hiding: window, revealing: panel) { [weak self] in
            NSApp.setActivationPolicy(.accessory)
            self?.isAnimating = false
        }
    }

    private func animateToFull() {
        guard !DesignTokens.Motion.reduceMotion,
              let from = WindowMorph.snapshot(of: panel, trimTransparent: true) else {
            let window = full.prepare()
            NSApp.setActivationPolicy(.regular)
            WindowMorph.crossfade(from: panel, to: window, show: { full.show() }) {}
            return
        }
        // La ventana se activa al empezar (icono del Dock, barra de menús, botones de color) pero invisible,
        // y la foto de destino se hace así, activa: al final no cambia nada.
        let window = full.showInvisible()
        guard let to = WindowMorph.snapshot(of: window, trimTransparent: false, includeFrame: true) else {
            window.alphaValue = 1
            panel.orderOut(nil)
            return
        }
        isAnimating = true
        WindowMorph.run(from: from, fromRadius: DesignTokens.Radius.largeCard,
                        to: to, toRadius: DesignTokens.FullMode.windowCornerRadius, hiding: panel, revealing: window) { [weak self] in
            self?.isAnimating = false
        }
    }
}
