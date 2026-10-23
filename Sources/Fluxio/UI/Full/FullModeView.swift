import SwiftUI
import UniformTypeIdentifiers

// Modo Completo: ventana con barra lateral para gestionar archivos (agregar, elegir formato,
// convertir, ver el avance, quitar y abrir el resultado). Usa la misma cola que la rueda.

private typealias T = DesignTokens

/// Secciones de la barra lateral.
enum FullPage: Hashable, Identifiable {
    case home
    case wheel
    case settings(SettingsTabs.Tab)
    case about

    static let all: [FullPage] = groups.flatMap(\.pages)

    /// La barra lateral por grupos (el primero, sin título).
    static let groups: [(title: String?, pages: [FullPage])] = [
        (nil, [.home]),
        ("Personalizar", [.wheel, .settings(.general)]),
        ("Conversión", [.settings(.saving), .settings(.images), .settings(.media), .settings(.pdf)]),
        ("Automatizar", [.settings(.automation)]),
        ("Sistema", [.settings(.engines), .about]),
    ]

    var id: String {
        switch self {
        case .home: return "home"
        case .wheel: return "wheel"
        case .settings(let tab): return "settings." + tab.rawValue
        case .about: return "about"
        }
    }

    var title: String {
        switch self {
        case .home: return "Inicio"
        case .wheel: return "Rueda"
        case .settings(let tab): return tab.title
        case .about: return "Acerca de"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .wheel: return "chart.pie"
        case .settings(let tab): return tab.symbol
        case .about: return "info.circle"
        }
    }
}

/// Estado de la ventana Completa (sin @State, que necesita Xcode).
@MainActor
final class FullModeModel: ObservableObject {
    @Published var page: FullPage = .home
    @Published var isDropTargeted = false
    /// Último formato elegido: se propone para los archivos que agregues después.
    @Published var lastFormatKey: String? {
        didSet { UserDefaults.standard.set(lastFormatKey, forKey: "fullModeLastFormat") }
    }
    /// Lo pide el selector Lite | Completo.
    var onSwitchToLite: () -> Void = {}

    init() {
        lastFormatKey = UserDefaults.standard.string(forKey: "fullModeLastFormat")
    }

    let queue = ConversionQueue.shared

    /// Agrega archivos a la cola y les propone el último formato usado, si les sirve.
    func add(_ urls: [URL]) {
        let ids = queue.add(urls)
        guard let key = lastFormatKey else { return }
        for id in ids {
            guard let item = queue.item(id), item.option == nil,
                  let option = ConversionEngine.shared.option(for: item.file, target: key) else { continue }
            queue.setOption(option, for: id)
        }
    }

    func choose(_ option: WheelOption, for id: UUID) {
        queue.setOption(option, for: id)
        lastFormatKey = ConversionEngine.key(of: option)
    }

    /// Elige el mismo formato para todos los archivos que esperan y lo admiten.
    func chooseForAll(key: String) {
        for item in queue.items where item.status == .waiting {
            if let option = ConversionEngine.shared.option(for: item.file, target: key) {
                queue.setOption(option, for: item.id)
            }
        }
        lastFormatKey = key
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Agregar"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Recibe archivos soltados desde Finder.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.add([url]) } }
            }
        }
        return true
    }
}

// MARK: - Ventana

struct FullModeView: View {
    @ObservedObject var model: FullModeModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Rectangle().fill(T.Colors.border).frame(width: T.Stroke.hairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(T.Colors.canvas)
        }
        .ignoresSafeArea()
        .fluxioTheme()
        .frame(minWidth: T.FullMode.windowMinSize.width, minHeight: T.FullMode.windowMinSize.height)
    }

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .home:
            HomePage(model: model)
        case .settings(let tab):
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: tab.title, model: model)
                    .padding(.horizontal, T.Spacing.xxl)
                SettingsView().page(tab)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, T.Spacing.l)
            }
        case .wheel:
            WheelCustomizePage(header: AnyView(PageHeader(title: "Personalizar rueda", model: model)))
        case .about:
            AboutPage(model: model)
        }
    }
}

// MARK: - Barra lateral

private struct Sidebar: View {
    @ObservedObject var model: FullModeModel

    var body: some View {
        VStack(alignment: .leading, spacing: T.Spacing.xxs) {
            VStack(alignment: .leading, spacing: T.Spacing.xs) {
                Wordmark()
                Text("Convertidor de archivos")
                    .textStyle(T.Typography.caption)
                    .foregroundStyle(T.Colors.textSecondary)
            }
            .padding(.horizontal, T.Spacing.m)
            .padding(.top, T.FullMode.titlebarHeight + T.Spacing.s)
            .padding(.bottom, T.Spacing.xl)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Fluxio, convertidor de archivos")

            // Si la ventana es baja, la lista se desplaza (la versión se queda abajo).
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: T.Spacing.xxs) {
            ForEach(Array(FullPage.groups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Text(title)
                        .textStyle(T.Typography.eyebrow)
                        .foregroundStyle(T.Colors.textSecondary)
                        .padding(.horizontal, T.Spacing.m)
                        .padding(.top, T.Spacing.l)
                        .padding(.bottom, T.Spacing.xxs)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.pages) { page in
                    NavRow(page: page, isSelected: model.page == page) { model.page = page }
                }
            }
            }
            }
            Spacer(minLength: 0)
            Text("Versión \(AppInfo.version)")
                .textStyle(T.Typography.mono)
                .foregroundStyle(T.Colors.textSecondary)
                .padding(.horizontal, T.Spacing.m)
                .padding(.bottom, T.Spacing.l)
        }
        .padding(.horizontal, T.Spacing.m)
        .frame(width: T.FullMode.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(T.Colors.surface)
    }
}

private struct NavRow: View {
    let page: FullPage
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()
    /// Al elegir la sección, el icono da un pequeño salto y vuelve a su tamaño.
    @StateObject private var pop = ViewState(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: T.Spacing.m) {
                Group {
                    // «Rueda» usa su propio icono con gajos; el resto, símbolos del sistema.
                    if page == .wheel {
                        Image(nsImage: WheelGlyph.image).renderingMode(.template)
                    } else {
                        Image(systemName: page.symbol)
                            .font(.system(size: T.IconSize.nav, weight: .medium))
                    }
                }
                .frame(width: T.IconSize.large)
                    .foregroundStyle(isSelected ? AnyShapeStyle(T.Colors.accentGradient)
                                                : AnyShapeStyle(T.Colors.textSecondary))
                    .scaleEffect(pop.value ? T.Motion.iconPopScale : 1)
                Text(page.title)
                    .textStyle(T.Typography.labelLarge)
                    .foregroundStyle(T.Colors.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: T.FullMode.navItemHeight)
            .padding(.horizontal, T.Spacing.m)
            .background(
                ZStack {
                    if hover.isOn && !isSelected {
                        RoundedRectangle(cornerRadius: T.Radius.input, style: .continuous).fill(T.Colors.recessed)
                    }
                    // El resaltado aparece en su sitio (crece un poco y se funde); el anterior se va sin rastro.
                    if isSelected {
                        RoundedRectangle(cornerRadius: T.Radius.input, style: .continuous)
                            .fill(T.Colors.accentSoft)
                            .transition(.asymmetric(insertion: T.Motion.reduceMotion ? .opacity
                                                        : .scale(scale: T.Motion.navSelectScale).combined(with: .opacity),
                                                    removal: .identity))
                    }
                }
                .animation(T.Motion.navSelect, value: isSelected)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(NavPressStyle())
        .onHover { hover.isOn = $0 }
        .onChange(of: isSelected) { selected in
            guard selected, !T.Motion.reduceMotion else { return }
            withAnimation(T.Motion.iconPop) { pop.value = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + T.Motion.navPopHold) {
                withAnimation(T.Motion.iconPop) { pop.value = false }
            }
        }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Al pulsar una sección, la fila se hunde un poco (como los demás botones).
struct NavPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? T.State.pressedScale : 1)
            .animation(T.Motion.control, value: configuration.isPressed)
    }
}

/// Logo de texto: las letras toman el color del texto (claro u oscuro) y el punto conserva su color.
struct Wordmark: View {
    var height: CGFloat = DesignTokens.FullMode.wordmarkHeight

    private static func image(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Wordmark").flatMap(NSImage.init(contentsOf:))
    }
    private static let letters = image("Wordmark-text")
    private static let dot = image("Wordmark-dot")

    var body: some View {
        if let letters = Self.letters, let dot = Self.dot {
            ZStack {
                Image(nsImage: letters).renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(T.Colors.textPrimary)
                Image(nsImage: dot).resizable().scaledToFit()
            }
            .frame(height: height)
            .accessibilityHidden(true)
        } else {
            Text("Fluxio").textStyle(T.Typography.subheading)
        }
    }
}

// MARK: - Encabezado de página (título + selector de modo)

struct PageHeader: View {
    let title: String
    @ObservedObject var model: FullModeModel

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .textStyle(T.Typography.title)
                .foregroundStyle(T.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            ModeSwitch(isFull: true) { full in if !full { model.onSwitchToLite() } }
        }
        .padding(.top, T.FullMode.titlebarHeight + T.Spacing.s)
        .padding(.bottom, T.Spacing.l)
    }
}

/// Dos botones independientes, "Lite" y "Completo". El del modo actual queda marcado; al elegir el otro, la
/// marca se desliza hasta él y después empieza el cambio de modo.
struct ModeSwitch: View {
    let isFull: Bool
    let onSelect: (Bool) -> Void

    var body: some View {
        HStack(spacing: T.Spacing.s) {
            modeButton("Lite", symbol: "circle.circle", selected: !isFull) { onSelect(false) }
            modeButton("Completo", symbol: "sidebar.left", selected: isFull) { onSelect(true) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modo de la interfaz")
    }

    @ViewBuilder
    private func modeButton(_ title: String, symbol: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        if selected {
            // El modo en el que estás: marcado con el acento suave y sin acción.
            Label(title, systemImage: symbol)
                .textStyle(T.Typography.label)
                .foregroundStyle(T.Colors.textPrimary)
                .padding(.vertical, T.Spacing.buttonV)
                .padding(.horizontal, T.Spacing.buttonH)
                .background(RoundedRectangle(cornerRadius: T.Radius.button, style: .continuous)
                    .fill(T.Colors.accentSoft))
                .overlay(RoundedRectangle(cornerRadius: T.Radius.button, style: .continuous)
                    .strokeBorder(T.Colors.accent, lineWidth: T.Stroke.hairline))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                .accessibilityHint("Modo actual")
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }
                .buttonStyle(.fluxioSecondary)
                .help("Cambiar a modo \(title) (\(GlobalHotKey.modeDisplay))")
        }
    }
}

// MARK: - Inicio

private struct HomePage: View {
    @ObservedObject var model: FullModeModel
    @ObservedObject var queue = ConversionQueue.shared
    @ObservedObject var recents = RecentStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.Spacing.xl) {
                PageHeader(title: "Inicio", model: model)
                    .padding(.bottom, -T.Spacing.l)
                DropZone(model: model)
                QueueSection(model: model, queue: queue)
                RecentSection(recents: recents)
            }
            .padding(.horizontal, T.Spacing.xxl)
            .padding(.bottom, T.Spacing.xxl)
            .frame(maxWidth: T.FullMode.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTargeted) { model.handleDrop($0) }
    }
}

private struct DropZone: View {
    @ObservedObject var model: FullModeModel

    var body: some View {
        let targeted = model.isDropTargeted
        VStack(spacing: T.Spacing.m) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: T.IconSize.dropZone, weight: .medium))
                .foregroundStyle(T.Colors.accentGradient)
                .frame(width: T.FullMode.dropIconCircle, height: T.FullMode.dropIconCircle)
                .background(Circle().fill(T.Colors.accentSoft))
            Text("Suelta archivos aquí")
                .textStyle(T.Typography.headline)
                .foregroundStyle(T.Colors.textPrimary)
            Text("O elige archivos desde tu Mac. También puedes mantener ⌥ Opción mientras arrastras en Finder: la rueda se abre junto al cursor.")
                .textStyle(T.Typography.body)
                .foregroundStyle(T.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: T.FullMode.dropTextMaxWidth)
            Button("Agregar archivos…", action: model.openFilePicker)
                .buttonStyle(.fluxioSecondary)
                .padding(.top, T.Spacing.xs)
        }
        .padding(T.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: T.FullMode.dropZoneMinHeight)
        .background(RoundedRectangle(cornerRadius: T.Radius.largeCard, style: .continuous)
            .fill(targeted ? T.Colors.accentSoft : T.Colors.recessed))
        .overlay(RoundedRectangle(cornerRadius: T.Radius.largeCard, style: .continuous)
            .strokeBorder(targeted ? AnyShapeStyle(T.Colors.accentGradient) : AnyShapeStyle(T.Colors.border),
                          lineWidth: targeted ? T.Stroke.focus : T.Stroke.hairline))
        .animation(T.Motion.control, value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zona para soltar archivos")
    }
}

// MARK: Cola

private struct QueueSection: View {
    @ObservedObject var model: FullModeModel
    @ObservedObject var queue: ConversionQueue

    /// Formatos que admite al menos uno de los archivos que esperan (para "Formato para todos").
    private var commonFormats: [(key: String, title: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for item in queue.items where item.status == .waiting {
            for option in ConversionEngine.shared.optionGroups(for: item.file).first?.options ?? [] {
                let key = ConversionEngine.key(of: option)
                if seen.insert(key).inserted { result.append((key, option.title)) }
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.Spacing.m) {
            HStack(spacing: T.Spacing.s) {
                Text("Cola").textStyle(T.Typography.headline)
                if !queue.items.isEmpty {
                    // El contador salta cada vez que cambia.
                    ZStack {
                        Badge(text: "\(queue.items.count)")
                            .id(queue.items.count)
                            .transition(T.Motion.reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                    }
                    .animation(T.Motion.badgePop, value: queue.items.count)
                }
                Spacer()
                let formats = commonFormats
                if !formats.isEmpty {
                    Menu {
                        ForEach(formats, id: \.key) { format in
                            Button(format.title) { model.chooseForAll(key: format.key) }
                        }
                    } label: {
                        Text("Formato para todos")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .textStyle(T.Typography.label)
                    .tint(T.Colors.textPrimary)
                    .padding(.vertical, T.Spacing.buttonV - T.Spacing.xxs)
                    .padding(.horizontal, T.Spacing.buttonH)
                    .recessedWell(radius: T.Radius.button)
                }
                if queue.items.contains(where: { $0.status.isFinished }) {
                    Button("Limpiar terminados", action: queue.clearFinished)
                        .buttonStyle(.fluxioGhost)
                }
                Button(queue.readyCount > 1 ? "Convertir todo (\(queue.readyCount))" : "Convertir", action: queue.convertAll)
                    .buttonStyle(.fluxioPrimary)
                    .disabled(queue.readyCount == 0)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            if queue.items.isEmpty {
                Text("Los archivos que agregues aparecerán aquí. Elige a qué formato convertir cada uno y pulsa Convertir.")
                    .textStyle(T.Typography.body)
                    .foregroundStyle(T.Colors.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 0) {
                            if index > 0 { Rectangle().fill(T.Colors.border).frame(height: T.Stroke.hairline) }
                            QueueRow(item: item, model: model, queue: queue)
                                .equatable()
                        }
                        // Al agregar, las filas aparecen una tras otra; al quitarlas, se disuelven.
                        .staggeredRowAppear()
                        .transition(.asymmetric(insertion: .identity, removal: .blurScale))
                    }
                }
                .animation(T.Motion.row, value: queue.items.map(\.id))
                .card()
                .clipShape(RoundedRectangle(cornerRadius: T.Radius.card, style: .continuous))
            }
        }
    }
}

/// Una fila por archivo. No vigila la cola ni la ventana (solo las usa en los botones): se vuelve a dibujar
/// únicamente cuando cambia su archivo (estado, avance, formato…), no cada vez que avanza otro.
private struct QueueRow: View, Equatable {
    let item: ConversionQueue.Item
    let model: FullModeModel
    let queue: ConversionQueue

    static func == (lhs: QueueRow, rhs: QueueRow) -> Bool { lhs.item == rhs.item }

    private var subtitle: String {
        if case .failed(let message) = item.status { return message }
        if item.status == .done, let first = item.outputs.first {
            return item.outputs.count == 1 ? "Creado: \(first.lastPathComponent)" : "Creados \(item.outputs.count) archivos"
        }
        return (item.file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: T.Spacing.m) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.file.url.path))
                .resizable()
                .frame(width: T.FullMode.rowIconSize, height: T.FullMode.rowIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: T.Spacing.xxs) {
                Text(item.name)
                    .textStyle(T.Typography.labelLarge)
                    .foregroundStyle(T.Colors.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                // Al terminar, la ruta se transforma en el nombre del resultado con un barrido de caracteres.
                ScrambleText(text: subtitle, animate: { _, new in new.hasPrefix("Creado") })
                    .textStyle(T.Typography.caption)
                    .foregroundStyle(isFailed ? T.Colors.error : T.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(subtitle)
            }
            Spacer(minLength: T.Spacing.m)
            FormatMenu(item: item, model: model)
                .frame(width: T.FullMode.formatMenuWidth)
            StatusView(item: item)
                .frame(width: T.FullMode.statusWidth, alignment: .leading)
            RowActions(item: item, queue: queue)
                .frame(width: T.FullMode.rowActionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, T.Spacing.l)
        .padding(.vertical, T.Spacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }
}

private struct FormatMenu: View {
    let item: ConversionQueue.Item
    let model: FullModeModel

    private var isLocked: Bool { item.status == .queued || item.status == .converting }

    var body: some View {
        Menu {
            ForEach(ConversionEngine.shared.optionGroups(for: item.file), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Button(option.accessibilityLabel) { model.choose(option, for: item.id) }
                    }
                }
            }
        } label: {
            Text(item.option?.title ?? "Elegir formato")
        }
        .menuStyle(.borderlessButton)
        .textStyle(T.Typography.label)
        .tint(item.option == nil ? T.Colors.textSecondary : T.Colors.textPrimary)
        .padding(.vertical, T.Spacing.buttonV - T.Spacing.xxs)
        .padding(.horizontal, T.Spacing.s)
        .recessedWell()
        .disabled(isLocked)
        .opacity(isLocked ? T.State.disabledOpacity : 1)
        .accessibilityLabel("Convertir a")
        .accessibilityValue(item.option?.title ?? "Sin elegir")
    }
}

private struct StatusView: View {
    let item: ConversionQueue.Item

    /// Cada estado distinto se cambia con fundido y desenfoque.
    private var key: String {
        switch item.status {
        case .waiting: return item.option == nil ? "elige" : "listo-para"
        case .queued: return "cola"
        case .converting: return "convirtiendo"
        case .done: return "listo"
        case .failed: return "error"
        case .cancelled: return "cancelado"
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .id(key)
                .transition(.blurScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(T.Motion.statusSwap, value: key)
    }

    @ViewBuilder
    private var content: some View {
        switch item.status {
        case .waiting:
            Text(item.option == nil ? "Elige un formato" : "Listo para convertir")
                .textStyle(T.Typography.caption)
                .foregroundStyle(T.Colors.textSecondary)
        case .queued:
            Label("En cola", systemImage: "clock")
                .textStyle(T.Typography.caption)
                .foregroundStyle(T.Colors.textSecondary)
        case .converting:
            VStack(alignment: .leading, spacing: T.Spacing.xs) {
                if item.progressKnown {
                    ProgressBar(value: item.progress)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(T.Colors.accent)
                }
                Text(item.progressKnown ? "\(Int(item.progress * 100)) %" : "Convirtiendo…")
                    .font(T.Typography.caption.font.monospacedDigit())
                    .foregroundStyle(T.Colors.textSecondary)
                    .rollingDigits(Double(Int(item.progress * 100)))
                    .shimmer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progreso")
            .accessibilityValue(item.progressKnown ? "\(Int(item.progress * 100)) por ciento" : "En curso")
        case .done:
            // El check se dibuja al terminar.
            HStack(spacing: T.Spacing.xs) {
                DrawnCheckmark(color: T.Colors.success, size: T.IconSize.small)
                Text("Listo")
            }
            .textStyle(T.Typography.label)
            // El verde va en el ✓; el texto, en el color normal (el verde como texto pequeño no llega al contraste mínimo).
            .foregroundStyle(T.Colors.textPrimary)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .textStyle(T.Typography.label)
                .foregroundStyle(T.Colors.error)
                .help(message)
        case .cancelled:
            Label("Cancelado", systemImage: "xmark.circle")
                .textStyle(T.Typography.label)
                .foregroundStyle(T.Colors.textSecondary)
        }
    }
}

/// Barra de progreso fina con el degradado de la marca.
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(T.Colors.recessed)
                Capsule().fill(T.Colors.accentGradientHorizontal)
                    .frame(width: max(T.FullMode.progressHeight, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: T.FullMode.progressHeight)
        .animation(T.Motion.control, value: value)
    }
}

private struct RowActions: View {
    let item: ConversionQueue.Item
    let queue: ConversionQueue

    var body: some View {
        HStack(spacing: T.Spacing.xs) {
            switch item.status {
            case .done:
                Button("Abrir") { open(item.outputs) }
                    .buttonStyle(.fluxioSecondary)
                    .fixedSize()
                iconButton("magnifyingglass", "Mostrar en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(item.outputs)
                }
                iconButton("xmark", "Quitar de la lista") { queue.remove(item.id) }
            case .queued, .converting:
                iconButton("stop.circle", "Cancelar") { queue.cancel(item.id) }
            case .failed, .cancelled:
                iconButton("arrow.clockwise", "Volver a intentar") { queue.convert([item.id]) }
                iconButton("xmark", "Quitar de la lista") { queue.remove(item.id) }
            case .waiting:
                iconButton("xmark", "Quitar de la lista") { queue.remove(item.id) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: T.IconSize.small, weight: .medium))
                .frame(width: T.IconSize.large, height: T.IconSize.large)
        }
        .buttonStyle(.fluxioGhost)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Abre el resultado con su app; si son varios, los muestra en Finder.
    private func open(_ urls: [URL]) {
        if urls.count == 1 { NSWorkspace.shared.open(urls[0]) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

// MARK: Recientes

private struct RecentSection: View {
    @ObservedObject var recents: RecentStore

    var body: some View {
        VStack(alignment: .leading, spacing: T.Spacing.m) {
            HStack {
                Text("Conversiones recientes").textStyle(T.Typography.headline)
                Spacer()
                if !recents.items.isEmpty {
                    Button("Borrar", action: recents.clear).buttonStyle(.fluxioGhost)
                }
            }
            if recents.items.isEmpty {
                Text("Tus archivos convertidos aparecerán aquí.")
                    .textStyle(T.Typography.body)
                    .foregroundStyle(T.Colors.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recents.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(T.Colors.border).frame(height: T.Stroke.hairline) }
                        RecentRow(item: item)
                    }
                }
                .card()
                .clipShape(RoundedRectangle(cornerRadius: T.Radius.card, style: .continuous))
            }
        }
    }
}

private struct RecentRow: View {
    let item: RecentStore.Item

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "es")
        return formatter
    }()

    /// "Hace un momento", "hace 5 minutos"…
    private static func when(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        guard seconds >= 60 else { return "Hace un momento" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        let exists = item.exists
        HStack(spacing: T.Spacing.m) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths.first ?? "/"))
                .resizable()
                .frame(width: T.FullMode.rowIconSize - T.Spacing.s, height: T.FullMode.rowIconSize - T.Spacing.s)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: T.Spacing.xxs) {
                Text(item.menuTitle)
                    .textStyle(T.Typography.label)
                    .foregroundStyle(T.Colors.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(exists ? Self.when(item.date) : "Ya no está en su carpeta")
                    .textStyle(T.Typography.caption)
                    .foregroundStyle(T.Colors.textSecondary)
            }
            Spacer()
            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(item.urls.filter { FileManager.default.fileExists(atPath: $0.path) })
            }
            .buttonStyle(.fluxioGhost)
            .disabled(!exists)
        }
        .padding(.horizontal, T.Spacing.l)
        .padding(.vertical, T.Spacing.s + T.Spacing.xxs)
    }
}

// MARK: - Acerca de

private struct AboutPage: View {
    @ObservedObject var model: FullModeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Acerca de", model: model)
            VStack(spacing: T.Spacing.m) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: T.FullMode.aboutIconSize, height: T.FullMode.aboutIconSize)
                    .accessibilityHidden(true)
                Wordmark(height: T.FullMode.wordmarkHeight + T.Spacing.s)
                Text("Convertidor de archivos")
                    .textStyle(T.Typography.body)
                    .foregroundStyle(T.Colors.textSecondary)
                Badge(text: "Versión \(AppInfo.version)")
                Text("Tipografía Inter, con licencia SIL Open Font License.")
                    .textStyle(T.Typography.caption)
                    .foregroundStyle(T.Colors.textSecondary)
                    .padding(.top, T.Spacing.s)
            }
            .frame(maxWidth: .infinity)
            .padding(T.Spacing.cardPadding)
            .card()
            Spacer()
        }
        .padding(.horizontal, T.Spacing.xxl)
        .frame(maxWidth: T.FullMode.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }
}

/// Datos de la app (versión).
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
