import SwiftUI

private typealias T = DesignTokens

/// Estado de los motores para la pestaña Motores (se comparte entre Ajustes y el modo Completo).
@MainActor
final class EnginesModel: ObservableObject {
    static let shared = EnginesModel()

    enum State: Equatable {
        case notInstalled
        /// El Mac ya lo tenía (Homebrew, Aplicaciones…): se usa ese.
        case onMac(String)
        case installed
        case working(Double?, String)
        case failed(String)
    }

    @Published private(set) var states: [EngineID: State] = [:]
    /// Motores recién instalados en esta visita a la página: su barra de progreso termina en un check.
    @Published var justInstalled: Set<EngineID> = []

    private init() { refresh() }

    /// Revisa qué motores tiene ya el Mac y cuáles instaló Fluxio.
    func refresh() {
        for id in EngineID.allCases {
            if case .working = states[id] { continue }
            if Engines.isInstalledByFluxio(id) {
                states[id] = .installed
            } else if let path = Engines.onMac(id) {
                states[id] = .onMac(path)
            } else if case .failed = states[id] {
                continue
            } else {
                states[id] = .notInstalled
            }
        }
    }

    /// Instalaciones en marcha, para poder cancelarlas mientras se descargan.
    private var installs: [EngineID: Task<Void, Never>] = [:]

    func cancelInstall(_ id: EngineID) {
        installs[id]?.cancel()
    }

    func install(_ id: EngineID) {
        states[id] = .working(0, "Preparando…")
        installs[id] = Task.detached {
            defer { Task { @MainActor in EnginesModel.shared.installs[id] = nil } }
            do {
                try await Engines.install(id) { fraction, phase in
                    Task { @MainActor in
                        if case .working = EnginesModel.shared.states[id] {
                            EnginesModel.shared.states[id] = .working(fraction, phase)
                        }
                    }
                }
                await MainActor.run {
                    withAnimation(DesignTokens.Motion.statusSwap) {
                        EnginesModel.shared.justInstalled.insert(id)
                        EnginesModel.shared.states[id] = .installed
                    }
                    EnginesModel.shared.refresh()
                }
            } catch {
                let cancelled = error is CancellationError || (error as? ConversionError).map { if case .cancelled = $0 { true } else { false } } == true
                await MainActor.run {
                    // Cancelado por ti: vuelve a «No instalado», sin mensaje de error.
                    EnginesModel.shared.states[id] = cancelled ? .notInstalled : .failed(error.localizedDescription)
                    if cancelled { EnginesModel.shared.refresh() }
                }
            }
        }
    }

    func remove(_ id: EngineID) {
        let spec = Engines.spec(id)
        guard confirmRemoval(title: "¿Quitar \(spec.name)?",
                             text: "Se borran \(spec.diskMB) MB. Si lo necesitas otra vez, tendrás que volver a descargarlo "
                                 + "(\(spec.downloadMB) MB).") else { return }
        try? Engines.remove(id)
        states[id] = .notInstalled
        refresh()
    }

    /// Quita la copia que ya tenía el Mac, después de confirmarlo.
    func removeFromMac(_ id: EngineID) {
        guard confirmRemoval(title: "¿Quitar \(Engines.spec(id).name) de tu Mac?",
                             text: "Esta copia no la instaló Fluxio (está en \(Engines.onMac(id) ?? "tu Mac")) y puede que otras "
            + "apps la usen. Si viene de Homebrew, se desinstala con Homebrew; si no, va a la Papelera y puedes recuperarla.")
        else { return }
        states[id] = .working(nil, "Quitando…")
        Task.detached {
            do {
                try Engines.removeFromMac(id)
                await MainActor.run {
                    EnginesModel.shared.states[id] = .notInstalled
                    EnginesModel.shared.refresh()
                }
            } catch {
                await MainActor.run { EnginesModel.shared.states[id] = .failed(error.localizedDescription) }
            }
        }
    }

    /// Aviso antes de borrar: «Quitar» en rojo y «Cancelar» como botón por defecto (Enter no borra nada).
    private func confirmRemoval(title: String, text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        let remove = alert.addButton(withTitle: "Quitar")
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        alert.addButton(withTitle: "Cancelar").keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Pestaña Motores: qué hace cada motor, si ya está y un botón para instalarlo o quitarlo.
struct EnginesPage: View {
    @ObservedObject var model = EnginesModel.shared

    var body: some View {
        Form {
            Section {
                Text("Fluxio revisa si tu Mac ya tiene cada motor: si lo tiene, lo usa y no descarga nada. "
                     + "Los que falten se descargan de su web oficial solo si los quieres, sin Terminal ni contraseña.")
                    .textStyle(T.Typography.caption)
                    .foregroundStyle(T.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Incluidos en Fluxio: WebP, Potrace (vectorizar) y XZ. No hace falta instalarlos.",
                      systemImage: "checkmark.circle.fill")
                    .textStyle(T.Typography.caption)
                    .foregroundStyle(T.Colors.textSecondary)
            }
            ForEach(Engines.all, id: \.id) { spec in
                Section { EngineRow(spec: spec, state: model.states[spec.id] ?? .notInstalled, model: model) }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        .onDisappear { model.justInstalled = [] }
    }
}

private struct EngineRow: View {
    let spec: EngineSpec
    let state: EnginesModel.State
    let model: EnginesModel

    var body: some View {
        HStack(alignment: .center, spacing: T.Spacing.l) {
            VStack(alignment: .leading, spacing: T.Spacing.xs) {
                HStack(spacing: T.Spacing.s) {
                    Text(spec.name).textStyle(T.Typography.labelLarge)
                    Badge(text: badge)
                }
                Text(spec.adds).textStyle(T.Typography.caption).foregroundStyle(T.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(spec.without).textStyle(T.Typography.caption).foregroundStyle(T.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
            Spacer(minLength: T.Spacing.s)
            actions
        }
        .padding(.vertical, T.Spacing.xs)
    }

    /// No se puede instalar en este Mac (y tampoco lo tiene ya).
    private var blocked: String? {
        if case .notInstalled = state { return spec.unavailable }
        return nil
    }

    private var badge: String {
        if blocked != nil { return "No disponible en tu macOS" }
        switch state {
        case .notInstalled: return "No instalado"
        case .onMac: return "Ya lo tienes en tu Mac"
        case .installed: return "Instalado"
        case .working: return "Instalando…"
        case .failed: return "No se pudo instalar"
        }
    }

    @ViewBuilder private var detail: some View {
        if let blocked {
            Text(blocked).textStyle(T.Typography.caption).foregroundStyle(T.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // Cada cambio de estado (por ejemplo, la barra de progreso → el check) con fundido y desenfoque.
            ZStack(alignment: .leading) {
                stateDetail
                    .id(detailKey)
                    .transition(.blurScale)
            }
            .animation(T.Motion.statusSwap, value: detailKey)
        }
    }

    private var detailKey: String {
        switch state {
        case .notInstalled: return "no"
        case .onMac: return "mac"
        case .installed: return model.justInstalled.contains(spec.id) ? "recien" : "instalado"
        case .working: return "instalando"
        case .failed: return "error"
        }
    }

    @ViewBuilder private var stateDetail: some View {
        switch state {
        case .onMac(let path):
            // El verde va en el icono; el texto, en el color normal (el verde como texto pequeño no llega al contraste mínimo).
            Label {
                Text("Fluxio usa el que ya está en \(path). No hay que instalar nada.")
                    .foregroundStyle(T.Colors.textPrimary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(T.Colors.success)
            }
            .textStyle(T.Typography.caption)
            .lineLimit(2)
        case .working(let fraction, let phase):
            VStack(alignment: .leading, spacing: T.Spacing.xxs) {
                if let fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                Text(phase + (fraction.map { " \(Int($0 * 100)) %" } ?? ""))
                    .textStyle(T.Typography.caption).foregroundStyle(T.Colors.textSecondary)
            }
        case .failed(let message):
            Text(message).textStyle(T.Typography.caption).foregroundStyle(T.Colors.error)
                .fixedSize(horizontal: false, vertical: true)
        case .installed where model.justInstalled.contains(spec.id):
            // Recién instalado: la barra de progreso termina en un check que se dibuja.
            HStack(spacing: T.Spacing.xs) {
                DrawnCheckmark(color: T.Colors.success, size: T.IconSize.small)
                Text("Listo para usar")
            }
            .textStyle(T.Typography.caption)
            .foregroundStyle(T.Colors.textPrimary)
            .accessibilityElement(children: .combine)
        default:
            Text("Descarga \(spec.downloadMB) MB · \(spec.diskMB) MB en disco")
                .textStyle(T.Typography.caption).foregroundStyle(T.Colors.textSecondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .notInstalled, .failed:
            HStack(spacing: T.Spacing.s) {
                Button(state == .notInstalled ? "Instalar" : "Reintentar") { model.install(spec.id) }
                    .buttonStyle(.fluxioPrimary)
                    .disabled(blocked != nil)
                Button("Quitar") {}.buttonStyle(.fluxioSecondary).disabled(true)
            }
        case .installed:
            HStack(spacing: T.Spacing.s) {
                Button("Instalar") {}.buttonStyle(.fluxioPrimary).disabled(true)
                Button("Quitar") { model.remove(spec.id) }.buttonStyle(.fluxioSecondary)
            }
        case .working(_, let phase):
            HStack(spacing: T.Spacing.s) {
                Button("Instalar") {}.buttonStyle(.fluxioPrimary).disabled(true)
                // Mientras se descarga se puede cancelar; al instalar, ya no (se deja terminar para no dejarlo a medias).
                if Engines.cancellablePhases.contains(phase) {
                    Button("Cancelar") { model.cancelInstall(spec.id) }.buttonStyle(.fluxioSecondary)
                } else {
                    Button("Quitar") {}.buttonStyle(.fluxioSecondary).disabled(true)
                }
            }
        case .onMac:
            // Ya lo tiene el Mac: no hace falta instalar; sí se puede quitar la copia del Mac.
            HStack(spacing: T.Spacing.s) {
                Button("Instalar") {}.buttonStyle(.fluxioPrimary).disabled(true)
                Button("Quitar") { model.removeFromMac(spec.id) }.buttonStyle(.fluxioSecondary)
                    .help("Desinstalar la copia que ya tiene tu Mac")
            }
        }
    }
}
