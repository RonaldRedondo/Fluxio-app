import AppKit
import SwiftUI
import Combine

/// Arranque de la app: icono en la barra de menú, ventana flotante y Ajustes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var settingsWindow: NSWindow?
    private let settingsTabs = SettingsTabs()
    private let coordinator = DropCoordinator()
    /// Detecta archivos arrastrándose por la pantalla (la tarjeta "Suelta aquí" invita a soltar).
    private let fileDragWatcher = FileDragWatcher()
    private var togglePanelItem: NSMenuItem!
    private var recentMenu = NSMenu(title: "Recientes")
    private var cursorWheel: CursorWheelController!
    private let finderService = FinderService()
    private let hotKey = GlobalHotKey()
    private var hotKeyObserver: AnyCancellable?
    /// Ventana del modo Completo (misma cola que la rueda).
    private let fullWindow = FullModeWindowController()
    /// Cambio entre Lite y Completo (con animación) y atajo ⌃⌥M.
    private var modeSwitcher: ModeSwitcher!
    private let modeHotKey = GlobalHotKey.modeSwitch()
    private var modeItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setUp()

        // Rueda junto al cursor (arrastre con ⌥, clic derecho de Finder y atajo ⌃⌥F).
        cursorWheel = CursorWheelController()
        finderService.onFiles = { [weak self] urls in self?.cursorWheel.present(urls: urls) }
        NSApp.servicesProvider = finderService
        NSUpdateDynamicServices()
        hotKeyObserver = AppSettings.shared.$hotkeyEnabled.sink { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.hotKey.register { [weak self] in self?.convertFinderSelection() }
            } else {
                self.hotKey.unregister()
            }
        }

        // Carpetas vigiladas (Ajustes → Automático).
        FolderWatcher.shared.start()

        panel = FloatingPanel(coordinator: coordinator)
        fileDragWatcher.onChange = { [weak self] dragging in
            withAnimation(DesignTokens.Motion.invite) { self?.coordinator.isDraggingFilesOnScreen = dragging }
        }
        fileDragWatcher.start()
        coordinator.onNeedsKeyFocus = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.panel.makeKeyAndOrderFront(nil)
        }

        modeSwitcher = ModeSwitcher(panel: panel, full: fullWindow)
        fullWindow.model.onSwitchToLite = { [weak self] in self?.modeSwitcher.switchTo(.lite) }
        coordinator.onSwitchMode = { [weak self] in self?.modeSwitcher.switchTo(.full) }
        coordinator.onOpenEngines = { [weak self] in self?.showSettings(tab: .engines) }
        modeHotKey.register { [weak self] in self?.modeSwitcher.toggle() }

        setUpMainMenu()
        setUpStatusItem()
        // Se abre en el último modo que usaste.
        modeSwitcher.restoreAtLaunch(showPanel: AppSettings.shared.showPanelOnLaunch)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if modeSwitcher.mode == .full { fullWindow.show() } else { panel.orderFrontRegardless() }
        return true
    }

    // MARK: Barra de menú

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Silueta del logo (Resources/MenuBarIcon.png). macOS la pinta en blanco o negro según el tema.
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Fluxio")
        if let image, image.size.height > 0 {
            image.size = NSSize(width: 18 * image.size.width / image.size.height, height: 18)
        }
        image?.isTemplate = true
        image?.accessibilityDescription = "Fluxio"
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        togglePanelItem = NSMenuItem(title: "Ocultar ventana flotante", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(togglePanelItem)
        modeItem = NSMenuItem(title: "Cambiar a modo Completo", action: #selector(toggleMode), keyEquivalent: "m")
        modeItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(modeItem)
        menu.addItem(NSMenuItem(title: "Elegir archivo…", action: #selector(chooseFile), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Convertir selección de Finder  (\(GlobalHotKey.display))",
                                action: #selector(convertFinderSelection), keyEquivalent: ""))
        let recentItem = NSMenuItem(title: "Recientes", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Acerca de Fluxio", action: #selector(about), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir de Fluxio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        togglePanelItem.title = panel.isVisible ? "Ocultar ventana flotante" : "Mostrar ventana flotante"
        modeItem.title = isFullShowing ? "Cambiar a modo Lite" : "Cambiar a modo Completo"
        rebuildRecentMenu()
    }

    // MARK: Recientes

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let items = RecentStore.shared.items
        if items.isEmpty {
            let empty = NSMenuItem(title: "Aún no hay conversiones", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "es")
        for (i, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.menuTitle, action: #selector(showRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            entry.toolTip = formatter.localizedString(for: item.date, relativeTo: Date())
            entry.isEnabled = item.exists
            if let first = item.urls.first, item.exists {
                let icon = NSWorkspace.shared.icon(forFile: first.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            recentMenu.addItem(entry)
        }
        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Borrar la lista", action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    @objc private func showRecent(_ sender: NSMenuItem) {
        let items = RecentStore.shared.items
        guard items.indices.contains(sender.tag) else { return }
        let existing = items[sender.tag].urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    @objc private func clearRecents() {
        RecentStore.shared.clear()
    }

    // MARK: Atajo ⌃⌥F

    @objc private func convertFinderSelection() {
        switch FinderSelection.read() {
        case .success(let urls):
            cursorWheel.present(urls: urls)
        case .failure(.empty):
            Notifier.shared.notify(title: "Fluxio", body: "Selecciona uno o varios archivos en Finder y vuelve a pulsar \(GlobalHotKey.display).", files: [])
        case .failure(.notAllowed):
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Fluxio necesita permiso para ver tu selección en Finder"
            alert.informativeText = "Ve a Ajustes del Sistema → Privacidad y seguridad → Automatización → Fluxio y activa «Finder»."
            alert.addButton(withTitle: "Abrir Ajustes")
            alert.addButton(withTitle: "Cancelar")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var isFullShowing: Bool { modeSwitcher.mode == .full && fullWindow.isVisible }

    @objc private func toggleMode() {
        modeSwitcher.toggle()
    }

    // MARK: Menú principal (se ve arriba mientras la ventana Completa está al frente)

    /// Sin este menú, copiar y pegar (⌘C, ⌘V) o cerrar con ⌘W no funcionarían en la ventana Completa.
    private func setUpMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Acerca de Fluxio", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar Fluxio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Salir de Fluxio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, "Fluxio"))

        let fileMenu = NSMenu(title: "Archivo")
        fileMenu.addItem(withTitle: "Agregar archivos…", action: #selector(addFilesToFull), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu, "Archivo"))

        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu, "Edición"))

        let windowMenu = NSMenu(title: "Ventana")
        let liteItem = NSMenuItem(title: "Cambiar a modo Lite", action: #selector(toggleMode), keyEquivalent: "m")
        liteItem.keyEquivalentModifierMask = [.control, .option]
        liteItem.target = self
        windowMenu.addItem(liteItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(windowMenu, "Ventana"))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func addFilesToFull() {
        modeSwitcher.switchTo(.full)
        fullWindow.model.page = .home
        // Tras la animación, para que el selector de archivos no la interrumpa.
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.Motion.modeMorphDuration + 0.1) { [weak self] in
            self?.fullWindow.model.openFilePicker()
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func chooseFile() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.prompt = "Elegir"
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        panel.orderFrontRegardless()
        coordinator.present(urls: open.urls)
    }

    @objc private func openSettings() { showSettings(tab: nil) }

    /// Abre Ajustes; con `tab`, en esa pestaña (la tarjeta de error abre «Motores»).
    private func showSettings(tab: SettingsTabs.Tab?) {
        if let tab { settingsTabs.selected = tab }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(tabs: settingsTabs)))
            window.title = "Ajustes de Fluxio"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Convertidor de archivos")
        ])
    }
}
