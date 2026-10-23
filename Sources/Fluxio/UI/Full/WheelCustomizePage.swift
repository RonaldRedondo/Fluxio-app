import SwiftUI

/// Modo Completo → «Rueda»: elegir qué opciones salen en cada rueda, en qué orden y cuáles van en «Más…» u ocultas.
@MainActor
final class WheelCustomizeModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let option: WheelOption
        var placement: WheelLayout.Placement
        var id: String { option.id }
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.placement == b.placement }
    }

    @Published var category: WheelCategory = .photos { didSet { if !category.modes.contains(mode) { mode = category.modes[0] }; load() } }
    @Published var mode: WheelMode = .tools { didSet { load() } }
    @Published private(set) var items: [Item] = []
    @Published var dragging: String?
    @Published var dragOffset: CGFloat = 0
    private var consumed: CGFloat = 0

    init() { load() }

    private var key: String { WheelCustomizer.key(category, mode) }
    var isCustomized: Bool { AppSettings.shared.wheelLayouts[key] != nil }
    var visibleCount: Int { items.filter { $0.placement == .visible }.count }

    /// Las opciones en el orden guardado (o el de serie) con su sitio.
    private func load() {
        // Sitio de serie: el mismo reparto que la rueda real (principales primero; si caben todas, todas a la
        // vista; si no, las 7 primeras a la vista y el resto en «Más…»).
        let all = WheelCustomizer.defaultOptions(category, mode)
        let defaults = all.filter { !$0.secondary } + all.filter(\.secondary)
        let fits = defaults.count <= ConversionEngine.maxSlices
        var list = defaults.enumerated().map { i, o in
            Item(option: o, placement: fits || i < ConversionEngine.maxSlices - 1 ? .visible : .more)
        }
        if let layout = AppSettings.shared.wheelLayouts[key] {
            let rank = Dictionary(layout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            list.sort { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
            for i in list.indices { if let p = layout.placement[list[i].id] { list[i].placement = p } }
        }
        items = list
    }

    /// Se guarda al momento: la próxima rueda ya sale así.
    private func save() {
        AppSettings.shared.wheelLayouts[key] = WheelLayout(order: items.map(\.id),
                                                           placement: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.placement) }))
        objectWillChange.send()
    }

    func set(_ id: String, _ placement: WheelLayout.Placement) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(DesignTokens.Motion.toast) { items[i].placement = placement }
        save()
    }

    func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        withAnimation(DesignTokens.Motion.toast) { items.swapAt(index, target) }
        save()
    }

    func reset() {
        AppSettings.shared.wheelLayouts[key] = nil
        withAnimation(DesignTokens.Motion.toast) { load() }
    }

    /// Arrastrar una fila para cambiar su puesto (como al ordenar archivos para unir).
    func drag(_ id: String, translation: CGFloat, step: CGFloat) {
        if dragging != id { dragging = id; consumed = 0 }
        guard let start = items.firstIndex(where: { $0.id == id }) else { return }
        var index = start, offset = translation - consumed, list = items
        while offset > step / 2, index < list.count - 1 { list.swapAt(index, index + 1); index += 1; consumed += step; offset -= step }
        while offset < -step / 2, index > 0 { list.swapAt(index, index - 1); index -= 1; consumed -= step; offset += step }
        if index == start { dragOffset = offset } else { withAnimation(DesignTokens.Motion.toast) { items = list; dragOffset = offset } }
    }

    func endDrag() {
        withAnimation(DesignTokens.Motion.toast) { dragging = nil; dragOffset = 0 }
        consumed = 0
        save()
    }

    /// Lo que se verá en la rueda (primer nivel), con el mismo reparto que la rueda de verdad.
    var preview: [WheelOption] {
        let options = items.compactMap { item -> WheelOption? in
            guard item.placement != .hidden else { return nil }
            var o = item.option
            o.secondary = item.placement == .more
            o.inMore = item.placement == .more
            return o
        }
        return ConversionEngine.fold(options)
    }
}

struct WheelCustomizePage: View {
    @StateObject private var model = WheelCustomizeModel()
    let header: AnyView

    private typealias WC = DesignTokens.WheelCustomize

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            header
            Text("Elige qué opciones salen en cada rueda, en qué orden, y cuáles van dentro de «Más…» u ocultas. Los cambios se aplican al momento.")
                .textStyle(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            // Tipo de archivo y rueda, en pestañas con pastilla que se desliza.
            ScrollView(.horizontal, showsIndicators: false) {
                SlidingTabs(tabs: WheelCategory.allCases.map { .init(id: $0, title: $0.title, symbol: $0.symbol) },
                            selection: $model.category)
                    .padding(.vertical, DesignTokens.Spacing.xs)
            }
            if model.category.modes.count > 1 {
                SlidingTabs(tabs: [.init(id: WheelMode.convert, title: "Convertir a", symbol: WheelMode.convert.symbol),
                                   .init(id: WheelMode.tools, title: "Herramientas", symbol: WheelMode.tools.symbol)],
                            selection: $model.mode)
                    .fixedSize()
            }

            HStack(alignment: .top, spacing: DesignTokens.Spacing.xl) {
                VStack(spacing: DesignTokens.Spacing.m) {
                    WheelPreview(options: model.preview, category: model.category)
                        .frame(width: WC.previewSide, height: WC.previewSide)
                    Text(model.visibleCount > ConversionEngine.maxSlices - 1
                         ? "Caben 7 a la vista: las que pasen de 7 van solas a «Más…»."
                         : "\(model.visibleCount) a la vista")
                        .textStyle(DesignTokens.Typography.caption)
                        .foregroundStyle(model.visibleCount > ConversionEngine.maxSlices - 1 ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(width: WC.previewSide)
                    Button { model.reset() } label: { Label("Restablecer esta rueda", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.fluxioSecondary).disabled(!model.isCustomized)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                    Text("Arrastra las filas para ordenarlas.")
                        .textStyle(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                    ScrollView(.vertical) {
                        VStack(spacing: DesignTokens.Spacing.s) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index).zIndex(model.dragging == item.id ? 1 : 0)
                            }
                        }
                        .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.xxl)
        .padding(.bottom, DesignTokens.Spacing.l)
    }

    private func chip(_ category: WheelCategory) -> some View {
        let on = model.category == category
        return Button { model.category = category } label: {
            Label(category.title, systemImage: category.symbol)
                .textStyle(DesignTokens.Typography.label)
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.vertical, DesignTokens.Spacing.s)
                .background(Capsule().fill(on ? AnyShapeStyle(DesignTokens.Colors.accentGradient) : AnyShapeStyle(DesignTokens.Colors.recessed)))
                .foregroundStyle(on ? DesignTokens.Colors.onAccent : DesignTokens.Colors.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ item: WheelCustomizeModel.Item, index: Int) -> some View {
        let dragged = model.dragging == item.id
        return HStack(spacing: DesignTokens.Spacing.m) {
            Image(systemName: "line.3.horizontal").foregroundStyle(DesignTokens.Colors.textSecondary).accessibilityHidden(true)
            Image(systemName: item.option.symbol)
                .frame(width: 22)
                .foregroundStyle(item.placement == .hidden ? AnyShapeStyle(DesignTokens.Colors.textSecondary) : AnyShapeStyle(DesignTokens.Colors.accentGradient))
            Text(item.option.title)
                .textStyle(DesignTokens.Typography.label)
                .foregroundStyle(item.placement == .hidden ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary)
                .strikethrough(item.placement == .hidden)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.s)
            Picker("Dónde", selection: Binding(get: { item.placement }, set: { model.set(item.id, $0) })) {
                Text("A la vista").tag(WheelLayout.Placement.visible)
                Text("En Más…").tag(WheelLayout.Placement.more)
                Text("Oculta").tag(WheelLayout.Placement.hidden)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: WC.placementWidth)
            .accessibilityLabel("Dónde va \(item.option.title)")
            VStack(spacing: 0) {
                Button { model.move(index, by: -1) } label: { arrow("chevron.up") }
                    .buttonStyle(.plain).disabled(index == 0).accessibilityLabel("Subir \(item.option.title)")
                Button { model.move(index, by: 1) } label: { arrow("chevron.down") }
                    .buttonStyle(.plain).disabled(index == model.items.count - 1).accessibilityLabel("Bajar \(item.option.title)")
            }
            .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .frame(height: WC.rowHeight)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous).fill(DesignTokens.Colors.recessed))
        .scaleEffect(dragged && !DesignTokens.Motion.reduceMotion ? 1.02 : 1)
        .shadow(color: .black.opacity(dragged ? 0.35 : 0), radius: 10, y: 4)
        .offset(y: dragged ? model.dragOffset : 0)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { model.drag(item.id, translation: $0.translation.height, step: WC.rowHeight + DesignTokens.Spacing.s) }
            .onEnded { _ in model.endDrag() })
    }

    /// Flecha pequeña con zona de clic amplia (toda la caja, no solo el dibujo).
    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: WC.arrowIcon, weight: .bold))
            .frame(width: WC.arrowTarget.width, height: WC.arrowTarget.height)
            .contentShape(Rectangle())
    }
}

/// Dibujo de la rueda tal como se verá (solo el primer nivel, sin poder pulsar).
struct WheelPreview: View {
    let options: [WheelOption]
    let category: WheelCategory

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let outer = side / 2 - 6, inner = outer * DesignTokens.Wheel.innerRadius / DesignTokens.Wheel.outerRadius
            let count = max(1, options.count)
            ZStack {
                // Anillo claro con sombra, como la rueda de verdad: el centro queda hueco.
                DesignTokens.Colors.glass
                    .clipShape(Ring(holeRadius: inner - DesignTokens.Wheel.centerHoleInset), style: FillStyle(eoFill: true))
                    .frame(width: side, height: side)
                    .floatingShadow()
                ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                    let span = 360.0 / Double(count)
                    let start = -90 - span / 2 + span * Double(i)
                    let mid = (start + span / 2) * .pi / 180
                    let r = (outer + inner) / 2
                    let sector = AnnularSector(startDegrees: start, endDegrees: start + span, innerRadius: inner, outerRadius: outer,
                                               gap: DesignTokens.Wheel.sliceGap, cornerRadius: DesignTokens.Radius.slice)
                    ZStack {
                        sector.fill(i == 0 ? AnyShapeStyle(DesignTokens.Colors.accentGradient) : AnyShapeStyle(DesignTokens.Colors.sliceFill))
                        sector.stroke(DesignTokens.Colors.sliceStroke, lineWidth: DesignTokens.Stroke.hairline)
                        VStack(spacing: 2) {
                            Image(systemName: option.symbol).font(.system(size: 14, weight: .medium))
                            Text(option.title).font(.system(size: 10, weight: .semibold))
                                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(i == 0 ? DesignTokens.Colors.onAccent : DesignTokens.Colors.textPrimary)
                        .frame(width: max(44, r * CGFloat(span) * .pi / 180 - 12))
                        .offset(x: r * cos(mid), y: r * sin(mid))
                    }
                }
                Image(systemName: category.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.accentGradient)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(DesignTokens.Motion.toast, value: options.map(\.id))
        }
        .accessibilityElement()
        .accessibilityLabel("Vista previa: " + options.map(\.title).joined(separator: ", "))
    }
}
