import AppKit
import SwiftUI

// MARK: - Molde de las ventanas de herramientas
//
// Todas las herramientas con ventana (unir, editar foto, metadatos…) usan la misma estructura:
// cabecera con ✕ y título centrado, el contenido, y un pie con los botones. Fondo de vidrio oscuro de Fluxio.

/// Ventana sin barra de título visible: la cabecera la dibuja `ToolWindowView`. Se mueve arrastrando el fondo.
@MainActor
func makeToolWindow(controller: NSViewController, title: String) -> NSWindow {
    let window = NSWindow(contentViewController: controller)
    window.title = title   // para VoiceOver y el menú Ventana
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.isReleasedWhenClosed = false
    window.level = .floating
    return window
}

struct ToolWindowView<Content: View, Footer: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    private typealias TW = DesignTokens.ToolWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .textStyle(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: TW.closeSize, height: TW.closeSize)
                            .background(Circle().fill(DesignTokens.Colors.recessed))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Cerrar")
                    .accessibilityLabel("Cerrar")
                    Spacer()
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .frame(height: TW.headerHeight)

            divider
            content()
                .padding(DesignTokens.Spacing.l)
            divider

            HStack(spacing: DesignTokens.Spacing.s) { footer() }
                .padding(.horizontal, DesignTokens.Spacing.l)
                .frame(height: TW.footerHeight)
        }
        .background(VisualEffectBackground(material: .hudWindow))
        // Las cuatro esquinas redondeadas (sin barra de título, macOS no redondea las de arriba).
        .clipShape(RoundedRectangle(cornerRadius: TW.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TW.cornerRadius, style: .continuous)
            .strokeBorder(DesignTokens.Colors.sliceStroke, lineWidth: DesignTokens.Stroke.hairline))
        .fluxioTheme()
    }

    private var divider: some View {
        Rectangle().fill(DesignTokens.Colors.border).frame(height: DesignTokens.Stroke.hairline)
    }
}

/// Miniatura quieta de un archivo (foto, primer fotograma del video, página del PDF o su icono).
struct FileThumbnailView: View {
    let url: URL
    let side: CGFloat
    @StateObject private var thumbs = FileThumbnails()

    var body: some View {
        Group {
            if let image = thumbs.images.first {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.badge, style: .continuous))
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .onAppear { thumbs.load([url], side: side) }
        .accessibilityHidden(true)
    }
}
