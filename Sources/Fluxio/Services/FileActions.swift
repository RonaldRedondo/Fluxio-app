import AppKit

/// Acciones rápidas sobre archivos (rueda Ctrl). No crean archivos nuevos.
@MainActor
enum FileActions {
    static let providerID = "file.actions"

    private enum Action: String {
        case copyPath, airdrop, move, terminal, finder, copy, float
    }

    static func options(for files: [FileInfo]) -> [WheelOption] {
        guard !files.isEmpty else { return [] }
        return [
            option(.airdrop, "AirDrop", "dot.radiowaves.left.and.right", "Enviar por AirDrop"),
            option(.float, "Float", "pin", "Dejar en un estante flotante"),
            option(.copy, "Copiar", "doc.on.doc", "Copiar el archivo para pegarlo en Finder"),
            option(.move, "Mover a…", "tray.and.arrow.up", "Mover a otra carpeta"),
            option(.copyPath, "Copiar ruta", "doc.on.clipboard", "Copiar la ruta del archivo"),
            option(.terminal, "Terminal", "terminal", "Abrir la carpeta en Terminal"),
            option(.finder, "Finder", "folder", "Mostrar en Finder"),
        ]
    }

    private static func option(_ action: Action, _ title: String, _ symbol: String, _ label: String) -> WheelOption {
        WheelOption(id: "\(providerID).\(action.rawValue)", providerID: providerID,
                    title: title, symbol: symbol, accessibilityLabel: label)
    }

    /// Ejecuta la acción. Devuelve un mensaje corto para mostrar, o lanza un error.
    static func perform(_ option: WheelOption, on files: [FileInfo]) throws -> String? {
        let urls = files.map(\.url)
        switch Action(rawValue: String(option.id.dropFirst(providerID.count + 1))) {
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            return urls.count == 1 ? "Ruta copiada" : "\(urls.count) rutas copiadas"

        case .copy:
            // Como ⌘C en Finder: luego se pegan con ⌘V en cualquier carpeta (o en otra app que acepte archivos).
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            return urls.count == 1 ? "Archivo copiado: pégalo con ⌘V" : "\(urls.count) archivos copiados: pégalos con ⌘V"

        case .float:
            ShelfController.shared.open(urls, near: NSEvent.mouseLocation)
            return nil

        case .airdrop:
            NSApp.activate(ignoringOtherApps: true)
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                throw ActionError("AirDrop no está disponible. Actívalo en el Centro de control.")
            }
            service.perform(withItems: urls)
            return nil

        case .move:
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Mover aquí"
            panel.message = "Elige la carpeta de destino"
            guard panel.runModal() == .OK, let folder = panel.url else { return nil }
            for url in urls {
                let target = folder.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    throw ActionError("Ya existe “\(url.lastPathComponent)” en la carpeta elegida.")
                }
                try FileManager.default.moveItem(at: url, to: target)
            }
            return urls.count == 1 ? "Archivo movido" : "\(urls.count) archivos movidos"

        case .terminal:
            let folder = files[0].isDirectory ? urls[0] : urls[0].deletingLastPathComponent()
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            return nil

        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return nil

        case nil:
            throw ConversionError.unsupported
        }
    }

    struct ActionError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
