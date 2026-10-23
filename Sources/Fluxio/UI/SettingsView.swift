import SwiftUI

/// Pestaña elegida en Ajustes.
final class SettingsTabs: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case general, saving, images, media, pdf, automation, engines
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .saving: return "Guardar"
            case .images: return "Imágenes"
            case .media: return "Video y audio"
            case .pdf: return "PDF"
            case .automation: return "Automático"
            case .engines: return "Motores"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .saving: return "folder"
            case .images: return "photo"
            case .media: return "film"
            case .pdf: return "doc.richtext"
            case .automation: return "folder.badge.gearshape"
            case .engines: return "cpu"
            }
        }
    }

    @Published var selected: Tab = .general
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var tabs = SettingsTabs()
    @ObservedObject var terminal = TerminalCommandModel()

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            page(tabs.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fluxioTheme()
        .frame(width: DesignTokens.Settings.windowSize.width, height: DesignTokens.Settings.windowSize.height)
    }

    /// El contenido de una pestaña. El modo Completo lo usa para mostrar cada sección en su barra lateral.
    @ViewBuilder
    func page(_ tab: SettingsTabs.Tab) -> some View {
        switch tab {
        case .general: general
        case .saving: saving
        case .images: images
        case .media: media
        case .pdf: pdf
        case .automation: automation
        case .engines: EnginesPage()
        }
    }

    /// Pestañas al estilo de los Ajustes de macOS: icono arriba, nombre debajo y aire entre ellas.
    private var tabBar: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            ForEach(SettingsTabs.Tab.allCases) { tab in
                let isOn = tabs.selected == tab
                Button {
                    tabs.selected = tab
                } label: {
                    VStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: DesignTokens.IconSize.tab, weight: .regular))
                            .frame(height: DesignTokens.IconSize.tabBox)
                            .foregroundStyle(isOn ? AnyShapeStyle(DesignTokens.Colors.accentGradient)
                                                  : AnyShapeStyle(DesignTokens.Colors.textSecondary))
                        Text(tab.title)
                            .textStyle(isOn ? DesignTokens.Typography.tabSelected : DesignTokens.Typography.tab)
                            .foregroundStyle(isOn ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                    }
                    .frame(minWidth: DesignTokens.Settings.tabMinWidth)
                    .padding(.vertical, DesignTokens.Spacing.s)
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                            .fill(isOn ? DesignTokens.Colors.accentSoft : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.m)
        .padding(.horizontal, DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Rueda junto al cursor") {
                Toggle("Abrir la rueda donde está el cursor al arrastrar archivos", isOn: $settings.cursorWheelEnabled)
                if settings.cursorWheelEnabled {
                    modifierPicker("Tecla para abrirla", selection: $settings.cursorTrigger)
                }
                Toggle("Atajo \(GlobalHotKey.display): convertir lo seleccionado en Finder", isOn: $settings.hotkeyEnabled)
                note("También puedes hacer clic derecho sobre archivos en Finder → «Convertir con Fluxio». Si no aparece: "
                     + "Ajustes del Sistema → Teclado → Atajos de teclado → Servicios → Archivos y carpetas.")
            }
            Section("Teclas para cambiar de rueda") {
                modifierPicker("Convertir formato", selection: $settings.convertModifier)
                modifierPicker("Herramientas", selection: $settings.toolsModifier)
                modifierPicker("Acciones", selection: $settings.actionsModifier)
                note("Si no pulsas ninguna, se abre la rueda de conversión.")
            }
            Section("Otros") {
                Toggle("Mostrar notificación al terminar", isOn: $settings.showNotifications)
                Toggle("Mostrar la ventana flotante al abrir Fluxio", isOn: $settings.showPanelOnLaunch)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Guardar

    private var saving: some View {
        Form {
            Section("Dónde guardar") {
                Picker("Guardar resultados", selection: $settings.destination) {
                    Text("Junto al archivo original").tag(DestinationMode.besideOriginal)
                    Text("En una subcarpeta junto al original").tag(DestinationMode.subfolder)
                    Text("En una carpeta fija").tag(DestinationMode.customFolder)
                }
                if settings.destination == .subfolder {
                    TextField("Nombre de la subcarpeta", text: $settings.naming.subfolder)
                }
                if settings.destination == .customFolder {
                    HStack {
                        Text(settings.customFolderPath.isEmpty ? "Ninguna carpeta elegida" : settings.customFolderPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Elegir…", action: chooseFolder).buttonStyle(.fluxioSecondary)
                    }
                }
            }
            Section("Nombre del archivo") {
                TextField("Patrón", text: $settings.naming.pattern)
                note("Palabras que se reemplazan: {nombre} (nombre del original), {formato}, {fecha} y {hora}.\n"
                     + "Ejemplo: \(settings.naming.expand(name: "foto", ext: "png")).png")
                Toggle("Sobrescribir si ya existe un archivo con el mismo nombre", isOn: $settings.overwrite)
                note(settings.overwrite
                     ? "Se reemplazará el archivo existente (nunca el original)."
                     : "Se añadirá un número: «foto (1).png».")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Imágenes

    private var images: some View {
        Form {
            Section("Calidad") {
                Slider(value: $settings.quality, in: 0.5...1, step: 0.05) {
                    Text("JPG / HEIC / AVIF / WebP")
                } minimumValueLabel: { Text("50%") } maximumValueLabel: { Text("100%") }
                note("Calidad actual: \(Int(settings.quality * 100))%")
            }
            Section("Tamaño") {
                Picker("Cambiar tamaño", selection: $settings.image.resize) {
                    ForEach(ImageOptions.Resize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                switch settings.image.resize {
                case .none: EmptyView()
                case .percent: number("Porcentaje", value: $settings.image.percent, unit: "%")
                case .longEdge: number("Lado más largo", value: $settings.image.longEdge, unit: "px")
                case .width: number("Ancho", value: $settings.image.width, unit: "px")
                }
                if settings.image.resize == .longEdge || settings.image.resize == .width {
                    note("Las imágenes más pequeñas no se agrandan.")
                }
            }
            Section("Ajustes") {
                Toggle("Escala de grises (blanco y negro)", isOn: $settings.image.grayscale)
                Picker("Voltear", selection: $settings.image.flip) {
                    ForEach(ImageOptions.Flip.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Conservar metadatos (cámara, fecha, ubicación)", isOn: $settings.image.keepMetadata)
                Stepper(value: $settings.image.traceColors, in: 2...16) {
                    Text("Colores al convertir en vector (SVG): \(settings.image.traceColors)")
                }
                note("Se aplican al convertir imágenes y al pasar páginas de PDF a imagen.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Video y audio

    private var media: some View {
        Form {
            Section("Video") {
                Picker("Resolución máxima", selection: $settings.media.resolution) {
                    ForEach(MediaOptions.Resolution.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Códec (MP4, MOV, MKV)", selection: $settings.media.codec) {
                    ForEach(MediaOptions.VideoCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Calidad", selection: $settings.media.quality) {
                    ForEach(MediaOptions.Quality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                note("Con «Original» e «Igual que el original», cambiar de MOV a MP4 es instantáneo y sin pérdida. "
                     + "Elegir otra resolución o códec obliga a recodificar (tarda más).")
            }
            Section("Audio") {
                Picker("Calidad del audio", selection: $settings.media.audioBitrate) {
                    ForEach(MediaOptions.audioBitrates, id: \.self) { kbps in
                        Text(kbps == 0 ? "Automática" : "\(kbps) kbps").tag(kbps)
                    }
                }
                note("Más kbps = mejor sonido y archivo más grande. 128 kbps es suficiente para voz; 256–320 para música.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: PDF

    private var pdf: some View {
        Form {
            Section("Páginas") {
                TextField("Rango de páginas", text: $settings.pdf.pageRange, prompt: Text("Todas"))
                note("Ejemplos: «1-3», «1, 4, 7», «5-» (de la 5 al final). Vacío = todas.\n"
                     + "Se usa al pasar un PDF a imágenes o a texto y al dividirlo.")
            }
            Section("Resolución al convertir a imagen") {
                Picker("Puntos por pulgada", selection: $settings.pdf.dpi) {
                    ForEach(PDFOptions.dpiChoices, id: \.self) { dpi in
                        Text(dpiLabel(dpi)).tag(dpi)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Automático

    private var automation: some View {
        Form {
            Section("Carpetas vigiladas") {
                if settings.watchRules.isEmpty {
                    note("Aún no hay carpetas. Añade una y todo lo que pongas en ella se convertirá solo.")
                }
                ForEach($settings.watchRules) { $rule in
                    HStack(spacing: DesignTokens.Spacing.m) {
                        Toggle("Vigilar", isOn: $rule.enabled).labelsHidden()
                        Image(systemName: "folder.fill").foregroundStyle(DesignTokens.Colors.accentGradient)
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                            Text(rule.name).textStyle(DesignTokens.Typography.label)
                            Text(rule.path).textStyle(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("Convertir a", selection: $rule.target) {
                            ForEach(WatchRule.targets, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(width: DesignTokens.Settings.pickerWidth)
                        Button {
                            NSWorkspace.shared.open(rule.url)
                        } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                        .help("Abrir la carpeta en Finder")
                        Button {
                            settings.watchRules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Dejar de vigilar esta carpeta")
                    }
                    .opacity(rule.enabled ? 1 : 0.55)
                }
                Button("Añadir carpeta…", action: addWatchedFolder).buttonStyle(.fluxioSecondary)
                note("Cada archivo nuevo que entre en la carpeta se convierte al formato elegido y el resultado se guarda "
                     + "en su subcarpeta «\(WatchRule.outputFolderName)». Lo que ya estaba dentro no se toca, y los archivos "
                     + "que no se pueden convertir a ese formato se ignoran. Funciona mientras Fluxio esté abierto.")
            }
            Section("Comando en Terminal") {
                if let path = terminal.path {
                    HStack {
                        Label("Instalado en \(path)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(terminal.isCurrent ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.warning)
                        Spacer()
                        if !terminal.isCurrent { Button("Reinstalar", action: terminal.install).buttonStyle(.fluxioPrimary) }
                        Button("Quitar", action: terminal.uninstall).buttonStyle(.fluxioSecondary)
                    }
                    if !terminal.isCurrent {
                        note("Fluxio cambió de sitio desde que instalaste el comando: pulsa «Reinstalar».")
                    }
                } else {
                    HStack {
                        Text("El comando «fluxio» no está instalado.")
                        Spacer()
                        Button("Instalar", action: terminal.install).buttonStyle(.fluxioPrimary)
                    }
                }
                if let error = terminal.error {
                    note(error)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Ejemplos (escríbelos en Terminal):").textStyle(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Group {
                        Text("fluxio foto.heic a jpg")
                        Text("fluxio *.png a webp -o ~/Desktop")
                        Text("fluxio opciones video.mov")
                        Text("fluxio ayuda")
                    }
                    .textStyle(DesignTokens.Typography.mono)
                    .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Vigilar"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.watchRules.contains(where: { $0.path == url.path }) {
            settings.watchRules.append(WatchRule(path: url.path))
        }
    }

    // MARK: Ayudantes

    private func dpiLabel(_ dpi: Int) -> String {
        switch dpi {
        case 72: return "72 ppp (pantalla, ligero)"
        case 144: return "144 ppp (Retina)"
        case 200: return "200 ppp"
        case 300: return "300 ppp (impresión)"
        default: return "\(dpi) ppp"
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).textStyle(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func number(_ title: String, value: Binding<Int>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: DesignTokens.Settings.numberFieldWidth)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func modifierPicker(_ title: String, selection: Binding<ModifierKey>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierKey.allCases) { key in Text(key.label).tag(key) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Elegir"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customFolderPath = url.path
        }
    }
}

/// Estado del comando `fluxio` para la pestaña Automático.
final class TerminalCommandModel: ObservableObject {
    @Published private(set) var path = TerminalCommand.installedPath
    @Published private(set) var isCurrent = TerminalCommand.isCurrent
    @Published private(set) var error: String?

    func install() {
        do {
            _ = try TerminalCommand.install()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        TerminalCommand.uninstall()
        refresh()
    }

    private func refresh() {
        path = TerminalCommand.installedPath
        isCurrent = TerminalCommand.isCurrent
    }
}
