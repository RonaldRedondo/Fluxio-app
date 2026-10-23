import SwiftUI

/// Contenido de la ventana flotante según el estado: zona para soltar, rueda, progreso o resultado.
struct PanelRootView: View {
    @ObservedObject var coordinator: DropCoordinator
    @ObservedObject var settings = AppSettings.shared
    /// Rueda junto al cursor: sin tarjeta "Suelta aquí" (la ventana se oculta en reposo).
    var compact = false
    @StateObject private var hover = ViewState(false)
    private var hovering: Bool { hover.value }

    private typealias M = DesignTokens.Motion

    /// Mientras arrastras archivos por la pantalla, la tarjeta invita a soltar.
    private var inviting: Bool { coordinator.isDraggingFilesOnScreen }
    var body: some View {
        VStack(spacing: 0) {
            categoryLabel
                .frame(height: DesignTokens.Wheel.categoryBand)
            content
                .frame(width: DesignTokens.Wheel.windowSide, height: DesignTokens.Wheel.windowSide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fluxioTheme()
    }

    /// Encima de la rueda: en qué rueda estás, en una pastilla de vidrio.
    @ViewBuilder
    private var categoryLabel: some View {
        if case .choosing = coordinator.phase {
            let title = coordinator.isInSubmenu ? "\(coordinator.mode.title) · Más" : coordinator.mode.title
            ZStack {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: coordinator.mode.symbol)
                        .foregroundStyle(DesignTokens.Colors.accentGradient)
                    Text(title)
                }
                .textStyle(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .background(Capsule().fill(DesignTokens.Colors.glass))
                .overlay(Capsule().strokeBorder(DesignTokens.Colors.sliceStroke, lineWidth: DesignTokens.Stroke.hairline))
                .id(title)
                .transition(.blurScale)
            }
            .animation(M.iconPop, value: title)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
        } else {
            Color.clear
        }
    }

    private var content: some View {
        ZStack {
            switch coordinator.phase {
            case .idle:
                if compact {
                    Color.clear
                } else {
                    idleCard.transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            case .choosing:
                // La rueda nace del punto por donde entró el archivo.
                RadialWheelView(coordinator: coordinator)
                    .transition(M.reduceMotion ? .opacity
                                : .scale(scale: M.wheelOriginScale, anchor: coordinator.wheelAnchor).combined(with: .opacity))
            case .working:
                progressCard.transition(.toast)
            case .done(let message, let files):
                resultCard(success: true, message: message, files: files)
                    .transition(.toast)
            case .failed(let message):
                resultCard(success: false, message: message, files: [])
                    .shakeOnAppear()
                    .transition(.toast)
            }
        }
    }

    // MARK: Zona para soltar

    private var idleCard: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: DesignTokens.IconSize.hero, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accentGradient)
                // El icono sube al pasar el ratón y más aún mientras arrastras un archivo.
                .offset(y: M.reduceMotion ? 0 : inviting ? DesignTokens.Panel.inviteIconLift
                                            : hovering ? DesignTokens.Panel.hoverIconLift : 0)
                .animation(M.invite, value: inviting)
                .animation(M.invite, value: hovering)
            Text("Suelta aquí")
                .textStyle(DesignTokens.Typography.headline)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                hint(.convert)
                hint(.tools)
                hint(.actions)
            }
            .textStyle(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .frame(width: DesignTokens.Panel.idleCardSize.width, height: DesignTokens.Panel.idleCardSize.height)
        .background(card)
        .overlay(
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.largeCard - DesignTokens.Stroke.dropZoneInset,
                                 style: .continuous)
                    .strokeBorder(DesignTokens.Colors.dropZoneStroke,
                                  style: StrokeStyle(lineWidth: DesignTokens.Stroke.dropZone,
                                                     dash: DesignTokens.Stroke.dropZoneDash))
                    .opacity(inviting ? 0 : 1)
                // Invitación: la línea punteada pasa al degradado de la marca y avanza. Solo existe mientras
                // dura la invitación (así no gasta nada en reposo).
                if inviting {
                    TimelineView(.animation(paused: M.reduceMotion)) { context in
                        let pattern = DesignTokens.Stroke.dropZoneDash.reduce(0, +)
                        let cycle = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: M.inviteDashCycle) / M.inviteDashCycle
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.largeCard - DesignTokens.Stroke.dropZoneInset,
                                         style: .continuous)
                            .strokeBorder(DesignTokens.Colors.accentGradient,
                                          style: StrokeStyle(lineWidth: DesignTokens.Panel.inviteStroke, lineCap: .round,
                                                             dash: DesignTokens.Stroke.dropZoneDash,
                                                             dashPhase: M.reduceMotion ? 0 : -pattern * CGFloat(cycle)))
                    }
                    .transition(.opacity)
                }
            }
            .padding(DesignTokens.Stroke.dropZoneInset)
            .animation(M.invite, value: inviting)
        )
        .scaleEffect(inviting && !M.reduceMotion ? DesignTokens.Panel.inviteScale : 1)
        .animation(M.invite, value: inviting)
        .onHover { hover.value = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zona para soltar archivos")
        .accessibilityHint("Arrastra un archivo aquí. También puedes usar Elegir archivo en el menú de Fluxio.")
        .overlay(alignment: .topTrailing) {
            if let switchMode = coordinator.onSwitchMode {
                Button(action: switchMode) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                }
                .buttonStyle(.fluxioGhost)
                .padding(DesignTokens.Spacing.s)
                .help("Cambiar a modo Completo (\(GlobalHotKey.modeDisplay))")
                .accessibilityLabel("Cambiar a modo Completo")
            }
        }
    }

    private func hint(_ mode: WheelMode) -> some View {
        HStack(spacing: DesignTokens.Spacing.s - DesignTokens.Spacing.xxs) {
            Image(systemName: settings.modifier(for: mode).symbol)
                .fontWeight(.bold)
                .imageScale(.small)
                .frame(width: DesignTokens.Panel.hintKeyWidth)
            Text(mode == .convert ? "Convertir" : mode.title)
        }
    }

    // MARK: Progreso

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack(spacing: DesignTokens.Spacing.s) {
                ProgressView().controlSize(.small)
                Text(coordinator.waitingInQueue ? "En cola…" : "Convirtiendo…").textStyle(DesignTokens.Typography.headline)
                    .shimmer()
            }
            Text(coordinator.jobTitle)
                .textStyle(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Group {
                if coordinator.progressKnown {
                    ProgressView(value: coordinator.progress)
                } else {
                    // El formato no informa de su avance: barra animada en lugar de un 0 % que parece congelado.
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .tint(DesignTokens.Colors.accent)
            .accessibilityLabel("Progreso")
            .accessibilityValue(coordinator.progressKnown ? "\(Int(coordinator.progress * 100)) por ciento" : "En curso")
            HStack {
                Text(coordinator.waitingInQueue ? "Espera a que termine la anterior"
                     : coordinator.progressKnown ? "\(Int(coordinator.progress * 100)) %" : "Trabajando…")
                    .font(DesignTokens.Typography.caption.font.monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .rollingDigits(Double(Int(coordinator.progress * 100)))
                Spacer()
                Button("Cancelar") { coordinator.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.fluxioSecondary)
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(width: DesignTokens.Panel.statusCardWidth)
        .background(card)
    }

    // MARK: Resultado

    private func resultCard(success: Bool, message: String, files: [URL]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
                if success {
                    // El check se dibuja al aparecer.
                    DrawnCheckmark(color: DesignTokens.Colors.success, size: DesignTokens.IconSize.large)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignTokens.IconSize.large))
                        .foregroundStyle(DesignTokens.Colors.error)
                }
                Text(message)
                    .textStyle(DesignTokens.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cerrar") { coordinator.dismissResult() }
                    .buttonStyle(.fluxioSecondary)
                if !files.isEmpty {
                    Button("Mostrar en Finder") { coordinator.showInFinder(files) }
                        .buttonStyle(.fluxioPrimary)
                } else if !success && coordinator.failedForMissingEngine {
                    Button("Abrir Motores") { coordinator.openEngines() }
                        .buttonStyle(.fluxioPrimary)
                }
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(width: DesignTokens.Panel.statusCardWidth)
        .background(card)
        .accessibilityElement(children: .contain)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.largeCard, style: .continuous)
            .fill(DesignTokens.Colors.glass)
            .keySurface(radius: DesignTokens.Radius.largeCard)
            .floatingShadow()
            // `isMovableByWindowBackground` no llega a través de SwiftUI: el fondo de la tarjeta mueve la ventana.
            .overlay(WindowDragArea())
    }
}
