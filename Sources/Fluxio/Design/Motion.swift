import SwiftUI

// Piezas de movimiento reutilizables (micro interacciones). Tiempos y medidas en DesignTokens.Motion.
// Con "Reducir movimiento" se quedan en fundidos simples.

private typealias M = DesignTokens.Motion

/// Un valor que guarda su propia vista (como `@State`; aquí se usa `@StateObject` porque las herramientas de
/// línea de comandos no incluyen las macros de SwiftUI).
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Transiciones

extension AnyTransition {
    /// Aparece o desaparece con escala y desenfoque (cambio de icono).
    static var blurScale: AnyTransition {
        guard !M.reduceMotion else { return .opacity }
        return .modifier(active: BlurScale(scale: M.swapScale, blur: M.swapBlur, opacity: 0),
                         identity: BlurScale(scale: 1, blur: 0, opacity: 1))
    }

    /// Entra subiendo, con fundido, desenfoque y un poco de escala (como una notificación).
    static var toast: AnyTransition {
        guard !M.reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: Toast(offset: M.toastRise, scale: M.toastScale, blur: M.toastBlur, opacity: 0),
                                 identity: Toast(offset: 0, scale: 1, blur: 0, opacity: 1)),
            removal: .modifier(active: Toast(offset: 0, scale: M.toastScale, blur: M.toastBlur / 2, opacity: 0),
                               identity: Toast(offset: 0, scale: 1, blur: 0, opacity: 1)))
    }
}

private struct BlurScale: ViewModifier {
    let scale: CGFloat, blur: CGFloat, opacity: Double
    func body(content: Content) -> some View {
        content.scaleEffect(scale).blur(radius: blur).opacity(opacity)
    }
}

private struct Toast: ViewModifier {
    let offset: CGFloat, scale: CGFloat, blur: CGFloat, opacity: Double
    func body(content: Content) -> some View {
        content.offset(y: offset).scaleEffect(scale).blur(radius: blur).opacity(opacity)
    }
}

// MARK: - Check que se dibuja

/// Círculo relleno con un check que se dibuja trazo a trazo al aparecer (o ya dibujado, con `animated: false`).
struct DrawnCheckmark: View {
    var color: Color
    var size: CGFloat
    var animated = true
    @StateObject private var drawnState = ViewState(false)
    private var drawn: Bool { drawnState.value || !animated }

    var body: some View {
        ZStack {
            Circle().fill(color)
                .scaleEffect(drawn || M.reduceMotion ? 1 : 0.6)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round))
                .padding(size * 0.27)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(M.checkDraw) { drawnState.value = true }
        }
        .accessibilityHidden(true)
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return p
    }
}

// MARK: - Sacudida (error)

extension View {
    /// Sacude la vista de lado a lado una vez al aparecer.
    func shakeOnAppear() -> some View { modifier(ShakeOnAppear()) }
}

private struct ShakeOnAppear: ViewModifier {
    @StateObject private var progress = ViewState<CGFloat>(0)
    func body(content: Content) -> some View {
        content
            .modifier(Shake(progress: progress.value))
            .onAppear {
                guard let animation = M.shake else { return }
                withAnimation(animation) { progress.value = 1 }
            }
    }
}

private struct Shake: GeometryEffect {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Va y vuelve `shakeCount` veces y se apaga hacia el final.
        let x = M.shakeDistance * (1 - progress) * sin(progress * .pi * 2 * M.shakeCount)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

// MARK: - Dígitos que giran

extension View {
    /// Los números cambian girando (en macOS 14 o posterior; antes, cambio directo).
    @ViewBuilder
    func rollingDigits(_ value: Double) -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText(value: value)).animation(M.digits, value: value)
        } else {
            contentTransition(.numericText()).animation(M.digits, value: value)
        }
    }
}

// MARK: - Brillo que recorre un texto

extension View {
    /// Un brillo recorre el contenido de lado a lado mientras se muestra (solo existe mientras se ve).
    func shimmer() -> some View { modifier(Shimmer()) }
}

private struct Shimmer: ViewModifier {
    func body(content: Content) -> some View {
        if M.reduceMotion {
            content
        } else {
            content.overlay {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: M.shimmerCycle) / M.shimmerCycle
                    let w = M.shimmerWidth
                    let center = -w + (1 + 2 * w) * t
                    LinearGradient(stops: [.init(color: .clear, location: center - w),
                                           .init(color: .white.opacity(0.85), location: center),
                                           .init(color: .clear, location: center + w)],
                                   startPoint: .leading, endPoint: .trailing)
                        .blendMode(.plusLighter)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Barrido de caracteres

/// Texto que, al cambiar, se transforma con una banda de caracteres brillantes que lo recorre de izquierda a
/// derecha (como en un panel de llegadas). Solo se anima cuando `animate` decide que el cambio lo merece.
struct ScrambleText: View {
    let text: String
    var animate: (_ old: String, _ new: String) -> Bool = { _, _ in true }

    @StateObject private var state = ScrambleState()
    private static let glyphs = Array("01<>/\\=+*#%&$@?!{}[]")

    var body: some View {
        Group {
            if let start = state.start {
                TimelineView(.animation) { context in
                    let p = min(1, context.date.timeIntervalSince(start) / M.scrambleDuration)
                    frame(progress: p)
                        .onChange(of: p >= 1) { done in if done { state.start = nil } }
                }
            } else {
                Text(text)
            }
        }
        .onAppear { state.last = text }
        .onChange(of: text) { new in
            let old = state.last ?? new
            state.last = new
            guard !M.reduceMotion, old != new, animate(old, new) else { return }
            state.from = old
            state.start = Date()
        }
        .accessibilityLabel(text)
    }

    /// Lo que se ve en un instante: la parte ya recorrida con el texto nuevo, la banda con caracteres al azar
    /// (en color de acento) y lo que falta con el texto anterior. Mide lo mismo que el texto nuevo: si el
    /// anterior era más largo (una ruta), la banda se quedaría escondida tras los "…".
    private func frame(progress p: Double) -> Text {
        let new = Array(text), old = Array(state.from)
        let length = new.count
        let band = M.scrambleBand
        let head = p * (Double(length) + band)          // posición de la banda
        var done = "", glow = "", rest = ""
        for i in 0..<length {
            let x = Double(i)
            if x < head - band {
                if i < new.count { done.append(new[i]) }
            } else if x < head {
                let source = i < new.count ? new[i] : (i < old.count ? old[i] : " ")
                glow.append(source == " " ? " " : Self.glyphs.randomElement()!)
            } else if i < old.count {
                rest.append(old[i])
            }
        }
        return Text(done) + Text(glow).foregroundColor(DesignTokens.Colors.accent) + Text(rest)
    }
}

private final class ScrambleState: ObservableObject {
    @Published var start: Date?
    var from = ""
    var last: String?
}

// MARK: - Filas que aparecen escalonadas

extension View {
    /// La vista aparece subiendo, con desenfoque; si aparecen varias a la vez, una tras otra.
    func staggeredRowAppear() -> some View { modifier(RowAppear()) }
}

private struct RowAppear: ViewModifier {
    @StateObject private var shown = ViewState(false)
    /// Momentos en que aparecieron las últimas filas (para escalonar las que llegan juntas).
    @MainActor private static var recent: [Date] = []

    func body(content: Content) -> some View {
        content
            .offset(y: shown.value || M.reduceMotion ? 0 : M.rowRise)
            .blur(radius: shown.value || M.reduceMotion ? 0 : M.rowBlur)
            .opacity(shown.value ? 1 : 0)
            .onAppear {
                let now = Date()
                Self.recent = Self.recent.filter { now.timeIntervalSince($0) < 0.5 } + [now]
                let delay = min(M.rowStaggerMax, Double(Self.recent.count - 1) * M.rowStagger)
                withAnimation(M.row.delay(delay)) { shown.value = true }
            }
    }
}
