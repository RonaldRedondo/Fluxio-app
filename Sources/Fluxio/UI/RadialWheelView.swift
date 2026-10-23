import SwiftUI

/// La rueda radial: un gajo por opción, con el primero centrado arriba.
struct RadialWheelView: View {
    @ObservedObject var coordinator: DropCoordinator

    private let outer = DesignTokens.Wheel.outerRadius
    private let inner = DesignTokens.Wheel.innerRadius

    var body: some View {
        let count = coordinator.options.count
        ZStack {
            // Fondo claro en forma de anillo: el centro, donde flota el archivo, queda transparente.
            DesignTokens.Colors.glass
                .clipShape(Ring(holeRadius: inner - DesignTokens.Wheel.centerHoleInset), style: FillStyle(eoFill: true))
                .frame(width: (outer + DesignTokens.Wheel.backdropPadding) * 2,
                       height: (outer + DesignTokens.Wheel.backdropPadding) * 2)
                .floatingShadow()
                .accessibilityHidden(true)
            // El agujero del centro se ve transparente, pero no puede serlo del todo: macOS deja pasar el arrastre
            // por los píxeles 100 % transparentes y la rueda se cerraba y abría sin parar.
            Circle()
                .fill(Color.black.opacity(DesignTokens.Wheel.holeHitOpacity))
                .frame(width: (inner - DesignTokens.Wheel.centerHoleInset) * 2,
                       height: (inner - DesignTokens.Wheel.centerHoleInset) * 2)
                .accessibilityHidden(true)

            ForEach(Array(coordinator.options.enumerated()), id: \.element.id) { index, option in
                slice(option, index: index, count: count)
            }

            centerHub
        }
        .frame(width: (outer + DesignTokens.Wheel.backdropPadding) * 2,
               height: (outer + DesignTokens.Wheel.backdropPadding) * 2)
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard coordinator.isPinned, case .active(let point) = phase else { return }
            let side = (outer + DesignTokens.Wheel.backdropPadding) * 2
            coordinator.updateHighlight(location: point, center: CGPoint(x: side / 2, y: side / 2))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(coordinator.mode.accessibilityName)
    }

    // MARK: Gajo

    @ViewBuilder
    private func slice(_ option: WheelOption, index: Int, count: Int) -> some View {
        let span = 360.0 / Double(count)
        let start = -90 - span / 2 + span * Double(index)
        let mid = start + span / 2
        let isOn = coordinator.highlighted == index
        let labelRadius = (outer + inner) / 2
        let rad = mid * .pi / 180
        let sector = AnnularSector(startDegrees: start, endDegrees: start + span, innerRadius: inner, outerRadius: outer,
                                   gap: DesignTokens.Wheel.sliceGap, cornerRadius: DesignTokens.Radius.slice)
        // El degradado va de una esquina a otra del propio gajo.
        let side = (outer + DesignTokens.Wheel.backdropPadding) * 2
        let box = sector.path(in: CGRect(x: 0, y: 0, width: side, height: side)).boundingRect
        let gradient = LinearGradient(colors: [DesignTokens.Colors.accent, DesignTokens.Colors.accentEnd],
                                      startPoint: UnitPoint(x: box.minX / side, y: box.minY / side),
                                      endPoint: UnitPoint(x: box.maxX / side, y: box.maxY / side))

        ZStack {
            sector
                .fill(isOn ? AnyShapeStyle(gradient) : AnyShapeStyle(DesignTokens.Colors.sliceFill))
            sector
                .stroke(DesignTokens.Colors.sliceStroke, lineWidth: DesignTokens.Stroke.hairline)

            VStack(spacing: DesignTokens.Wheel.labelSpacing) {
                Image(systemName: option.symbol)
                    .font(.system(size: DesignTokens.IconSize.slice, weight: .medium))
                    // El icono del gajo resaltado da un pequeño salto.
                    .scaleEffect(isOn && !DesignTokens.Motion.reduceMotion ? DesignTokens.Motion.iconPopScale : 1)
                    .animation(DesignTokens.Motion.iconPop, value: isOn)
                // Varias palabras: hasta dos líneas («Quitar / fondo»). Una sola palabra («Metadatos…») no se parte:
                // si no cabe, la letra se reduce un poco.
                let oneWord = !option.title.contains(" ")
                Text(option.title)
                    .textStyle(DesignTokens.Typography.sliceLabel)
                    .multilineTextAlignment(.center)
                    .lineLimit(oneWord ? 1 : 2)
                    .minimumScaleFactor(oneWord ? DesignTokens.Wheel.labelMinScaleOneWord : DesignTokens.Wheel.labelMinScale)
                    .fixedSize(horizontal: false, vertical: !oneWord)
            }
            .foregroundStyle(isOn ? DesignTokens.Colors.onAccent : DesignTokens.Colors.textPrimary)
            // Margen a cada lado para que el texto no toque los bordes del gajo.
            .frame(width: max(DesignTokens.Wheel.labelMinWidth,
                              min(DesignTokens.Wheel.labelMaxWidth,
                                  labelRadius * CGFloat(span) * .pi / 180 - DesignTokens.Wheel.labelSideInset * 2)))
            .offset(x: labelRadius * cos(rad), y: labelRadius * sin(rad))
        }
        .scaleEffect(isOn ? DesignTokens.Wheel.hoverScale : 1)
        // Los gajos aparecen uno tras otro (también al cambiar de rueda).
        .modifier(StaggeredAppear(index: index))
        .contentShape(AnnularSector(startDegrees: start, endDegrees: start + span,
                                    innerRadius: inner, outerRadius: outer, gap: 0))
        .onTapGesture { coordinator.execute(option) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.accessibilityLabel)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { coordinator.execute(option) }
    }

    // MARK: Centro

    /// "Prueba ⌘ o ⌃": las teclas de las otras ruedas.
    private var otherModesHint: String {
        let keys = WheelMode.allCases.filter { $0 != coordinator.mode }
            .map { AppSettings.shared.modifier(for: $0).glyph }
        return "Prueba " + keys.joined(separator: " o ")
    }

    /// Ángulo (grados) del centro del gajo resaltado; el primero está arriba (-90°).
    private var highlightedAngle: Double? {
        let count = coordinator.options.count
        guard let index = coordinator.highlighted, count > 0, coordinator.options.indices.contains(index) else { return nil }
        return -90 + 360 / Double(count) * Double(index)
    }

    private var centerHub: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            if coordinator.options.isEmpty {
                Image(systemName: "nosign").font(.system(size: DesignTokens.IconSize.large, weight: .semibold))
                Text("Nada disponible").textStyle(DesignTokens.Typography.wheelCenter)
                Text(otherModesHint).textStyle(DesignTokens.Typography.wheelHint)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else {
                // El archivo que arrastras flota en el centro, solo (sin nombre de rueda), y se inclina
                // hacia la opción resaltada.
                // Con la rueda fija, la miniatura sube y se achica un poco para dejar sitio a la pista de abajo.
                FloatingFileStack(files: coordinator.files.map(\.url), leanAngle: highlightedAngle,
                                  side: coordinator.isPinned ? DesignTokens.Wheel.thumbSizePinned
                                                             : DesignTokens.Wheel.thumbSize)
                    .offset(y: coordinator.isPinned ? -DesignTokens.Wheel.thumbPinnedLift : 0)
            }
        }
        .multilineTextAlignment(.center)
        .animation(DesignTokens.Motion.iconPop, value: coordinator.mode)
        .animation(DesignTokens.Motion.iconPop, value: coordinator.isInSubmenu)
        .frame(width: inner * 2 - DesignTokens.Spacing.s, height: inner * 2 - DesignTokens.Spacing.s)
        // Con la rueda fija, la pista va abajo del todo para no mover la miniatura del centro.
        .overlay(alignment: .bottom) {
            if coordinator.isPinned && !coordinator.options.isEmpty {
                HStack(spacing: DesignTokens.Wheel.hintIconSpacing) {
                    Image(systemName: coordinator.isInSubmenu ? "chevron.left" : "arrow.right.to.line")
                        .imageScale(.small)
                    Text(coordinator.isInSubmenu ? "volver" : "cambiar")
                }
                .textStyle(DesignTokens.Typography.wheelHint)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .padding(.bottom, DesignTokens.Wheel.hintBottomInset)
            }
        }
        // Centro transparente: se ve el fondo de la rueda.
        .contentShape(Circle())
        .onTapGesture {
            if coordinator.isInSubmenu { coordinator.leaveSubmenu() } else if coordinator.isPinned { coordinator.nextMode() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(coordinator.mode.title). \(coordinator.files.count) archivo(s)")
        .accessibilityHint("Pulsa Tab para cambiar de rueda, Escape para cerrar")
    }
}

/// Un círculo con un agujero redondo en el medio (se rellena con la regla par-impar).
struct Ring: Shape {
    let holeRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path(ellipseIn: rect)
        p.addEllipse(in: CGRect(x: rect.midX - holeRadius, y: rect.midY - holeRadius,
                                width: holeRadius * 2, height: holeRadius * 2))
        return p
    }
}

/// Cada gajo aparece desde el centro, un poco después que el anterior.
private struct StaggeredAppear: ViewModifier {
    let index: Int
    @StateObject private var shown = ViewState(false)

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown.value || DesignTokens.Motion.reduceMotion ? 1 : 0.6)
            .opacity(shown.value ? 1 : 0)
            .onAppear {
                withAnimation(DesignTokens.Motion.sliceAppear.delay(Double(index) * DesignTokens.Motion.sliceStagger)) {
                    shown.value = true
                }
            }
    }
}

/// Forma de "gajo": un anillo cortado entre dos ángulos, con las cuatro esquinas redondeadas.
/// El hueco entre gajos tiene el mismo ancho en toda su longitud.
struct AnnularSector: Shape {
    var startDegrees: Double
    var endDegrees: Double
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var gap: CGFloat
    var cornerRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = outerRadius, rho = innerRadius, g = gap / 2
        let span = (endDegrees - startDegrees) * .pi / 180

        // Una sola opción: un anillo completo.
        if span >= 2 * .pi - 0.001 {
            var p = Path()
            p.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
            p.addEllipse(in: CGRect(x: c.x - rho, y: c.y - rho, width: 2 * rho, height: 2 * rho))
            return p
        }

        // Radio de las esquinas, limitado para que quepa en gajos estrechos o anillos finos.
        let s = sin(span / 2)
        let maxByWidth = (rho * s - g) / max(0.001, 1 - s)
        let r = max(0, min(cornerRadius, (R - rho) / 2 - 0.5, maxByWidth))

        let a0 = startDegrees * .pi / 180, a1 = endDegrees * .pi / 180
        func u(_ a: Double) -> CGPoint { CGPoint(x: cos(a), y: sin(a)) }
        // Normal hacia el interior del gajo en cada borde.
        let n0 = CGPoint(x: -sin(a0), y: cos(a0))
        let n1 = CGPoint(x: sin(a1), y: -cos(a1))

        func add(_ p: CGPoint, _ q: CGPoint, _ k: CGFloat = 1) -> CGPoint { CGPoint(x: p.x + q.x * k, y: p.y + q.y * k) }
        func scale(_ p: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
        func abs(_ p: CGPoint) -> CGPoint { CGPoint(x: c.x + p.x, y: c.y + p.y) }
        func angle(_ p: CGPoint, from o: CGPoint) -> Angle { .radians(atan2(p.y - o.y, p.x - o.x)) }

        /// Esquina sobre un borde recto: centro del círculo, punto de contacto con el borde y con el arco.
        func corner(edge a: Double, normal n: CGPoint, outer: Bool) -> (center: CGPoint, onEdge: CGPoint, onArc: CGPoint) {
            let dist = outer ? R - r : rho + r                       // distancia del centro de la esquina al centro de la rueda
            let along = sqrt(max(0, dist * dist - (g + r) * (g + r)))
            let center = add(scale(u(a), along), n, g + r)
            let onEdge = add(scale(u(a), along), n, g)
            let onArc = scale(center, (outer ? R : rho) / dist)
            return (abs(center), abs(onEdge), abs(onArc))
        }

        let os = corner(edge: a0, normal: n0, outer: true)
        let oe = corner(edge: a1, normal: n1, outer: true)
        let ie = corner(edge: a1, normal: n1, outer: false)
        let `is` = corner(edge: a0, normal: n0, outer: false)

        var p = Path()
        p.move(to: `is`.onEdge)
        p.addLine(to: os.onEdge)
        if r > 0 { p.addArc(center: os.center, radius: r, startAngle: angle(os.onEdge, from: os.center),
                            endAngle: angle(os.onArc, from: os.center), clockwise: false) }
        p.addArc(center: c, radius: R, startAngle: angle(os.onArc, from: c), endAngle: angle(oe.onArc, from: c), clockwise: false)
        if r > 0 { p.addArc(center: oe.center, radius: r, startAngle: angle(oe.onArc, from: oe.center),
                            endAngle: angle(oe.onEdge, from: oe.center), clockwise: false) }
        p.addLine(to: ie.onEdge)
        if r > 0 { p.addArc(center: ie.center, radius: r, startAngle: angle(ie.onEdge, from: ie.center),
                            endAngle: angle(ie.onArc, from: ie.center), clockwise: false) }
        p.addArc(center: c, radius: rho, startAngle: angle(ie.onArc, from: c), endAngle: angle(`is`.onArc, from: c), clockwise: true)
        if r > 0 { p.addArc(center: `is`.center, radius: r, startAngle: angle(`is`.onArc, from: `is`.center),
                            endAngle: angle(`is`.onEdge, from: `is`.center), clockwise: false) }
        p.closeSubpath()
        return p
    }
}

/// Fondo translúcido nativo de macOS.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Icono de la rueda (barra lateral → «Rueda»): un anillo de gajos separados, como la rueda de verdad.
/// Es una imagen "plantilla": toma el color o el degradado de quien la pinta, como un símbolo del sistema.
enum WheelGlyph {
    static let image: NSImage = {
        let side = DesignTokens.WheelGlyph.size
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let g = DesignTokens.WheelGlyph.self
            let count = g.slices
            let span = 360.0 / Double(count)
            for i in 0..<count {
                let start = -90 - span / 2 + span * Double(i)
                let sector = AnnularSector(startDegrees: start, endDegrees: start + span,
                                           innerRadius: side * g.innerRatio, outerRadius: side / 2 - 0.5,
                                           gap: g.gap, cornerRadius: g.corner)
                cg.addPath(sector.path(in: rect).cgPath)
            }
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
