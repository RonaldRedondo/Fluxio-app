import AppKit
import SwiftUI

/// La ventana del modo Completo. Mientras está abierta, Fluxio muestra su icono en el Dock
/// (una ventana grande sin icono en el Dock es difícil de encontrar).
@MainActor
final class FullModeWindowController: NSObject, NSWindowDelegate {
    let model = FullModeModel()
    private var window: NSWindow?
    /// Se llama cuando el usuario cierra la ventana.
    var onClose: () -> Void = {}

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = prepare()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Para la animación de cambio de modo: la ventana se pone en su sitio, activa (barra de menús, botones de
    /// color) pero invisible. Así todos esos cambios ocurren al empezar, tapados por la animación, y al final
    /// solo hay que hacerla visible.
    func showInvisible() -> NSWindow {
        let window = prepare()
        window.alphaValue = 0
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        return window
    }

    /// La ventana lista (creada y en su sitio) pero sin mostrarla: la animación de cambio de modo la fotografía.
    func prepare() -> NSWindow {
        let window = self.window ?? makeWindow()
        self.window = window
        return window
    }

    /// Oculta la ventana sin avisar de que se cerró (al cambiar de modo desde el código).
    func hide() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let size = DesignTokens.FullMode.windowSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Fluxio"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Sin la animación de apertura de macOS: se reproducía justo después de la nuestra y daba un salto.
        window.animationBehavior = .none
        window.minSize = DesignTokens.FullMode.windowMinSize
        window.contentViewController = NSHostingController(rootView: FullModeView(model: model))
        window.setContentSize(size)
        window.delegate = self
        if !window.setFrameUsingName("FluxioFullWindow") { window.center() }
        window.setFrameAutosaveName("FluxioFullWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }
}
