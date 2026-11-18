import PDFKit
import SwiftUI

/// Pedir la contraseña de un PDF que la necesita para abrirse, antes de guardar una copia sin ella.
/// La contraseña se comprueba aquí mismo: la ventana solo se cierra cuando es la correcta.
@MainActor
final class UnlockPDFModel: ObservableObject {
    let url: URL
    @Published var password = "" { didSet { if password != oldValue { wrong = false } } }
    /// La última contraseña probada no abría el PDF.
    @Published private(set) var wrong = false
    /// Cambia en cada intento fallido, para sacudir el campo.
    @Published private(set) var attempts = 0

    init(url: URL) { self.url = url }

    var canConfirm: Bool { !password.isEmpty && !wrong }

    /// `true` si la contraseña abre el PDF.
    func check() -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        if !doc.isLocked || doc.unlock(withPassword: password) { return true }
        wrong = true
        withAnimation(DesignTokens.Motion.reduceMotion ? nil : .linear(duration: DesignTokens.ToolWindow.unlockShakeDuration)) {
            attempts += 1
        }
        return false
    }
}

struct UnlockPDFEditorView: View {
    @ObservedObject var model: UnlockPDFModel
    let title: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var focused: Bool
    private typealias TW = DesignTokens.ToolWindow

    var body: some View {
        ToolWindowView(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                HStack(spacing: DesignTokens.Spacing.m) {
                    Image(systemName: "lock.doc")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(DesignTokens.Colors.accent)
                        .frame(width: TW.unlockIconSize, height: TW.unlockIconSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.url.lastPathComponent)
                            .textStyle(DesignTokens.Typography.label)
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("Pide contraseña para abrirse. Escríbela y Fluxio guardará una copia sin ella; el original no cambia.")
                            .textStyle(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    SecureField("Contraseña", text: $model.password)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(submit)
                        .padding(.horizontal, DesignTokens.Spacing.s)
                        .frame(height: TW.unlockFieldHeight)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                            .fill(DesignTokens.Colors.recessed))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                            .strokeBorder(model.wrong ? DesignTokens.Colors.error : DesignTokens.Colors.accent.opacity(focused ? 0.8 : 0),
                                          lineWidth: DesignTokens.Stroke.hairline))
                        .modifier(Shake(attempts: model.attempts))
                        .accessibilityLabel("Contraseña del PDF")

                    Text("Contraseña incorrecta. Prueba otra vez.")
                        .textStyle(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.error)
                        .opacity(model.wrong ? 1 : 0)
                        .accessibilityHidden(!model.wrong)
                }
            }
        } footer: {
            Spacer()
            Button("Cancelar", action: onCancel)
                .buttonStyle(.fluxioSecondary)
            Button("Quitar contraseña", action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.fluxioPrimary)
                .disabled(!model.canConfirm)
        }
        .frame(width: TW.unlockWidth)
        .onAppear { focused = true }
    }

    private func submit() {
        guard model.canConfirm else { return }
        if model.check() { onConfirm() } else { focused = true }
    }
}

/// Sacude el campo de lado a lado (como la pantalla de inicio de sesión de macOS) cada vez que sube `attempts`.
private struct Shake: GeometryEffect {
    var attempts: Int
    var animatableData: CGFloat

    init(attempts: Int) {
        self.attempts = attempts
        animatableData = CGFloat(attempts)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}
