import SwiftUI

// Componentes reutilizables del sistema de diseño. Todo el aspecto sale de DesignTokens.

private typealias T = DesignTokens

// MARK: - Texto

extension View {
    /// Aplica un estilo de texto completo: fuente, espaciado entre letras, interlineado y mayúsculas.
    func textStyle(_ style: DesignTokens.Typography.Style) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(max(0, (style.lineHeight - 1.2) * style.size))
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

// MARK: - Superficies

extension View {
    /// Borde fino + sombra "tecla" por dentro (brillo arriba, sombra abajo): la superficie parece una tecla.
    func keySurface(radius: CGFloat) -> some View {
        overlay(
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(T.Colors.border, lineWidth: T.Stroke.hairline)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .inset(by: T.Stroke.hairline)
                    .stroke(LinearGradient(stops: [.init(color: T.Shadow.keyHighlight, location: 0),
                                                   .init(color: .clear, location: 0.12),
                                                   .init(color: .clear, location: 0.88),
                                                   .init(color: T.Shadow.keyShade, location: 1)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: T.Stroke.hairline)
            }
            .allowsHitTesting(false)
        )
    }

    /// Tarjeta: fondo de superficie, radio de tarjeta y sombra "tecla".
    func card(radius: CGFloat = DesignTokens.Radius.card, fill: Color = DesignTokens.Colors.surface) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .keySurface(radius: radius)
    }

    /// Sombra de los elementos que flotan sobre el escritorio (rueda, tarjetas de la ventana flotante).
    func floatingShadow() -> some View { shadows(T.Shadow.floating) }

    /// Aplica una lista de capas de sombra.
    func shadows(_ layers: [DesignTokens.Shadow.Layer]) -> some View {
        layers.reduce(AnyView(self)) { view, layer in
            AnyView(view.shadow(color: layer.color, radius: layer.radius, y: layer.y))
        }
    }

    /// Pozo hundido para campos, etiquetas y listas.
    func recessedWell(radius: CGFloat = DesignTokens.Radius.input) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(T.Colors.recessed))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(T.Colors.border, lineWidth: T.Stroke.hairline))
    }
}

// MARK: - Botones

/// Botones de Fluxio: principal (cian sólido con texto blanco), secundario (neutro) y fantasma (solo texto).
/// Sin sombra interior, para que el texto se lea bien. El texto mantiene un contraste de 4,5:1 o más
/// en todos los estados: al pulsar el botón solo se encoge un poco (no se vuelve transparente) y
/// desactivado pasa a ser neutro con borde punteado y texto normal.
struct FluxioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        FluxioButton(configuration: configuration, kind: kind)
    }

    private struct FluxioButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @StateObject private var hover = HoverState()

        private var isHovered: Bool { hover.isOn && isEnabled }

        var body: some View {
            configuration.label
                .textStyle(T.Typography.label)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.vertical, T.Spacing.buttonV)
                .padding(.horizontal, kind == .ghost ? T.Spacing.s : T.Spacing.buttonH)
                .background(background)
                .brightness(isHovered ? T.State.hoverBrightness : 0)
                .scaleEffect(configuration.isPressed && isEnabled ? T.State.pressedScale : 1)
                .contentShape(RoundedRectangle(cornerRadius: T.Radius.button, style: .continuous))
                .onHover { hover.isOn = $0 }
                .animation(T.Motion.control, value: configuration.isPressed)
                .animation(T.Motion.control, value: hover.isOn)
        }

        private var foreground: Color {
            guard isEnabled else { return T.Colors.textPrimary }
            switch kind {
            case .primary: return T.Colors.onPrimaryButton
            case .secondary: return T.Colors.textPrimary
            // Color normal del texto (el gris secundario no llegaba a 4,5:1 en modo claro).
            case .ghost: return T.Colors.textPrimary
            }
        }

        @ViewBuilder private var background: some View {
            let shape = RoundedRectangle(cornerRadius: T.Radius.button, style: .continuous)
            if !isEnabled {
                // Desactivado: neutro y con borde punteado (se nota apagado sin perder legibilidad).
                shape.fill(kind == .ghost ? Color.clear : T.Colors.recessed)
                    .overlay(shape.strokeBorder(T.Colors.border,
                                                style: StrokeStyle(lineWidth: T.Stroke.hairline,
                                                                   dash: T.Stroke.disabledDash)))
            } else {
                switch kind {
                case .primary:
                    // La elevación va solo en el fondo: el texto queda limpio, sin sombra.
                    shape.fill(T.Colors.primaryButton).shadows(T.Shadow.lift)
                case .secondary:
                    shape.fill(T.Colors.recessed)
                        .overlay(shape.strokeBorder(T.Colors.border, lineWidth: T.Stroke.hairline))
                case .ghost:
                    shape.fill(isHovered ? T.Colors.recessed : .clear)
                }
            }
        }
    }
}

extension ButtonStyle where Self == FluxioButtonStyle {
    static var fluxioPrimary: FluxioButtonStyle { FluxioButtonStyle(kind: .primary) }
    static var fluxioSecondary: FluxioButtonStyle { FluxioButtonStyle(kind: .secondary) }
    static var fluxioGhost: FluxioButtonStyle { FluxioButtonStyle(kind: .ghost) }
}

/// Si el ratón está encima (sin @State, que necesita Xcode).
final class HoverState: ObservableObject {
    @Published var isOn = false
}

// MARK: - Etiqueta pequeña

/// Etiqueta compacta para versiones, extensiones o contadores.
struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .textStyle(T.Typography.caption)
            .foregroundStyle(T.Colors.textSecondary)
            .padding(.horizontal, T.Spacing.s - T.Spacing.xxs)
            .padding(.vertical, T.Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: T.Radius.badge, style: .continuous).fill(T.Colors.recessed))
    }
}

// MARK: - Tema de toda la app

extension View {
    /// Fuente, color de acento y estilo base de Fluxio. Se pone en la raíz de cada ventana.
    func fluxioTheme() -> some View {
        self
            .font(T.Typography.body.font)
            .tint(T.Colors.accent)
    }
}

// MARK: - Pestañas con pastilla que se desliza

/// Pestañas en un carril: la elegida va en una pastilla elevada que se desliza hasta la nueva al cambiar.
/// Hay una sola pastilla que se mueve (no se funden dos), así no deja rastro.
struct SlidingTabs<ID: Hashable>: View {
    struct Tab: Identifiable {
        let id: ID
        let title: String
        let symbol: String?
    }

    let tabs: [Tab]
    @Binding var selection: ID
    @Namespace private var pill

    var body: some View {
        HStack(spacing: T.Spacing.xxs) {
            ForEach(tabs) { tab in
                let on = tab.id == selection
                Button { withAnimation(T.Motion.tabSlide) { selection = tab.id } } label: {
                    HStack(spacing: T.Spacing.xs) {
                        if let symbol = tab.symbol { Image(systemName: symbol) }
                        Text(tab.title).lineLimit(1)
                    }
                    .textStyle(T.Typography.label)
                    .fontWeight(on ? .semibold : .medium)
                    .foregroundStyle(on ? T.Colors.textPrimary : T.Colors.textSecondary)
                    .padding(.horizontal, T.Spacing.m)
                    .frame(height: T.Tabs.height)
                    .contentShape(Rectangle())
                    .matchedGeometryEffect(id: tab.id, in: pill, isSource: true)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(T.Tabs.inset)
        .background(
            // La pastilla sigue a la pestaña elegida.
            RoundedRectangle(cornerRadius: T.Tabs.pillRadius, style: .continuous)
                .fill(T.Colors.tabPill)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .matchedGeometryEffect(id: selection, in: pill, isSource: false)
        )
        .background(RoundedRectangle(cornerRadius: T.Tabs.pillRadius + T.Tabs.inset, style: .continuous).fill(T.Colors.recessed))
    }
}
