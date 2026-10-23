import AppKit
import Carbon

/// "Convertir con Fluxio" en el clic derecho de Finder (Servicios / Acciones rápidas de macOS).
/// Se declara en Info.plist (NSServices); macOS llama a `convertWithFluxio` con los archivos elegidos.
final class FinderService: NSObject {
    var onFiles: (([URL]) -> Void)?

    @objc func convertWithFluxio(_ pasteboard: NSPasteboard, userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No llegó ningún archivo." as NSString
            return
        }
        DispatchQueue.main.async { self.onFiles?(urls) }
    }
}

/// Atajos de teclado globales: funcionan aunque Fluxio no esté en primer plano y no necesitan permisos.
/// - ⌃⌥F: convertir lo seleccionado en Finder.
/// - ⌃⌥M: cambiar entre los modos Lite y Completo.
final class GlobalHotKey {
    static let display = "⌃⌥F"
    static let modeDisplay = "⌃⌥M"

    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerRef: EventHandlerRef?
    private let keyCode: UInt32
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    init(keyCode: Int = kVK_ANSI_F, id: UInt32 = 1) {
        self.keyCode = UInt32(keyCode)
        self.id = id
    }

    /// Atajo ⌃⌥M para cambiar de modo.
    static func modeSwitch() -> GlobalHotKey { GlobalHotKey(keyCode: kVK_ANSI_M, id: 2) }

    func register(action: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        Self.actions[id] = action
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x464C_5849), id: id)   // "FLXI"
        RegisterEventHotKey(keyCode, UInt32(controlKey | optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.actions[id] = nil
    }

    /// Un solo receptor para todos los atajos: mira cuál se pulsó y ejecuta su acción.
    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let id = pressed.id
            DispatchQueue.main.async { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

/// Lee los archivos seleccionados en Finder. La primera vez macOS pide permiso
/// ("Fluxio quiere controlar Finder"); se revisa en Ajustes del Sistema → Privacidad y seguridad → Automatización.
enum FinderSelection {
    enum Problem: Error {
        case notAllowed, empty
    }

    static func read() -> Result<[URL], Problem> {
        let source = """
        tell application "Finder"
            set picked to selection as alias list
            set out to ""
            repeat with f in picked
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo) else {
            // -1743: el usuario no dio permiso de Automatización.
            let code = errorInfo?[NSAppleScript.errorNumber] as? Int
            return .failure(code == -1743 ? .notAllowed : .empty)
        }
        let paths = (result.stringValue ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return paths.isEmpty ? .failure(.empty) : .success(paths.map { URL(fileURLWithPath: $0) })
    }
}
