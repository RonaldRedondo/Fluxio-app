import AppKit
import Combine

/// Tecla modificadora que abre una rueda.
enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }

    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Cmd"
        case .control: return "⌃ Ctrl"
        case .option: return "⌥ Opción"
        }
    }

    var glyph: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }
    /// El mismo símbolo dibujado por macOS: queda centrado con el texto (el carácter «⌃» se ve demasiado arriba).
    var symbol: String {
        switch self {
        case .shift: return "shift"
        case .command: return "command"
        case .control: return "control"
        case .option: return "option"
        }
    }
}

/// Dónde se guardan los resultados.
enum DestinationMode: String, CaseIterable, Identifiable {
    case besideOriginal, subfolder, customFolder
    var id: String { rawValue }
}

/// Ajustes guardados en el Mac (UserDefaults).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var convertModifier: ModifierKey { didSet { save(convertModifier.rawValue, "convertModifier") } }
    @Published var toolsModifier: ModifierKey { didSet { save(toolsModifier.rawValue, "toolsModifier") } }
    @Published var actionsModifier: ModifierKey { didSet { save(actionsModifier.rawValue, "actionsModifier") } }
    @Published var destination: DestinationMode { didSet { save(destination.rawValue, "destination") } }
    @Published var customFolderPath: String { didSet { save(customFolderPath, "customFolderPath") } }
    @Published var overwrite: Bool { didSet { save(overwrite, "overwrite") } }
    @Published var quality: Double { didSet { save(quality, "quality") } }
    @Published var showNotifications: Bool { didSet { save(showNotifications, "showNotifications") } }
    @Published var showPanelOnLaunch: Bool { didSet { save(showPanelOnLaunch, "showPanelOnLaunch") } }
    /// Ajustes de conversión.
    @Published var naming: NamingOptions { didSet { saveCodable(naming, "naming") } }
    @Published var image: ImageOptions { didSet { saveCodable(image, "imageOptions") } }
    @Published var media: MediaOptions { didSet { saveCodable(media, "mediaOptions") } }
    @Published var pdf: PDFOptions { didSet { saveCodable(pdf, "pdfOptions") } }
    /// Rueda junto al cursor al arrastrar archivos con la tecla de activación.
    @Published var cursorWheelEnabled: Bool { didSet { save(cursorWheelEnabled, "cursorWheelEnabled") } }
    @Published var cursorTrigger: ModifierKey { didSet { save(cursorTrigger.rawValue, "cursorTrigger") } }
    /// Atajo global ⌃⌥F para convertir lo seleccionado en Finder.
    @Published var hotkeyEnabled: Bool { didSet { save(hotkeyEnabled, "hotkeyEnabled") } }
    /// Carpetas vigiladas: lo que entra en ellas se convierte solo.
    @Published var watchRules: [WatchRule] { didSet { saveCodable(watchRules, "watchRules") } }
    /// Ruedas personalizadas (Modo Completo → Rueda): orden y sitio de cada opción, por categoría y rueda.
    @Published var wheelLayouts: [String: WheelLayout] { didSet { saveCodable(wheelLayouts, "wheelLayouts") } }

    private init() {
        Self.migrateFromConverso()
        func key<T: RawRepresentable>(_ name: String, _ fallback: T) -> T where T.RawValue == String {
            UserDefaults.standard.string(forKey: name).flatMap(T.init(rawValue:)) ?? fallback
        }
        convertModifier = key("convertModifier", ModifierKey.shift)
        toolsModifier = key("toolsModifier", ModifierKey.command)
        actionsModifier = key("actionsModifier", ModifierKey.control)
        destination = key("destination", DestinationMode.besideOriginal)
        customFolderPath = defaults.string(forKey: "customFolderPath") ?? ""
        overwrite = defaults.object(forKey: "overwrite") as? Bool ?? false
        quality = defaults.object(forKey: "quality") as? Double ?? 0.9
        showNotifications = defaults.object(forKey: "showNotifications") as? Bool ?? true
        showPanelOnLaunch = defaults.object(forKey: "showPanelOnLaunch") as? Bool ?? true
        naming = Self.loadCodable("naming") ?? NamingOptions()
        image = Self.loadCodable("imageOptions") ?? ImageOptions()
        media = Self.loadCodable("mediaOptions") ?? MediaOptions()
        pdf = Self.loadCodable("pdfOptions") ?? PDFOptions()
        cursorWheelEnabled = defaults.object(forKey: "cursorWheelEnabled") as? Bool ?? true
        cursorTrigger = key("cursorTrigger", ModifierKey.option)
        hotkeyEnabled = defaults.object(forKey: "hotkeyEnabled") as? Bool ?? true
        watchRules = Self.loadCodable("watchRules") ?? []
        wheelLayouts = Self.loadCodable("wheelLayouts") ?? [:]
    }

    /// La app se llamaba "Converso": copiamos sus ajustes una sola vez para no perderlos.
    private static func migrateFromConverso() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromConverso") else { return }
        if let old = defaults.persistentDomain(forName: "local.converso.app") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromConverso")
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func loadCodable<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// Qué rueda corresponde a las teclas pulsadas. Sin tecla → conversión.
    func mode(for flags: NSEvent.ModifierFlags) -> WheelMode {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(actionsModifier.flag) { return .actions }
        if flags.contains(toolsModifier.flag) { return .tools }
        if flags.contains(convertModifier.flag) { return .convert }
        return .convert
    }

    func modifier(for mode: WheelMode) -> ModifierKey {
        switch mode {
        case .convert: return convertModifier
        case .tools: return toolsModifier
        case .actions: return actionsModifier
        }
    }

    var outputPolicy: OutputPolicy {
        let folder = destination == .customFolder && !customFolderPath.isEmpty
            ? URL(fileURLWithPath: customFolderPath, isDirectory: true) : nil
        return OutputPolicy(customFolder: folder, overwrite: overwrite, quality: quality,
                            subfolder: destination == .subfolder ? naming.subfolder : nil,
                            naming: naming, image: image, media: media, pdf: pdf)
    }
}
