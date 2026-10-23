import AppKit
import SwiftUI

/// Cerebro de la ventana flotante: qué se muestra, qué opción está resaltada y qué pasa al soltar.
@MainActor
final class DropCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// La rueda está visible. `pinned` = se soltó en el centro y espera teclado o clic.
        case choosing(pinned: Bool)
        case working
        case done(message: String, files: [URL])
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var mode: WheelMode = .convert
    @Published var options: [WheelOption] = []
    @Published var highlighted: Int?
    @Published private(set) var files: [FileInfo] = []
    /// Tarea en curso: nombre, avance (0…1) y si el formato informa de su avance.
    @Published private(set) var jobTitle = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressKnown = false
    /// Tu conversión espera a que termine otra (de la otra rueda o del modo Completo).
    @Published private(set) var waitingInQueue = false

    let engine = ConversionEngine.shared
    /// Cola compartida con el modo Completo: las conversiones de la rueda también aparecen allí.
    let queue = ConversionQueue.shared
    /// Trabajo de esta rueda que está en la cola (para poder cancelarlo).
    private var currentJobID: UUID?
    /// Marca de la última conversión pedida desde esta rueda: los avisos de una anterior ya no cambian la tarjeta.
    private var currentTicket: UUID?

    /// Adónde vuelve la tarjeta al cerrar la rueda sin elegir: a la barra de avance si aún se convierte algo.
    private var restingPhase: Phase { currentJobID != nil ? .working : .idle }
    let settings = AppSettings.shared
    private var dismissWork: DispatchWorkItem?

    /// Se llama cuando la ventana debe pasar a primer plano (para recibir teclado).
    var onNeedsKeyFocus: (() -> Void)?
    /// Botón de la tarjeta "Suelta aquí" para pasar al modo Completo (solo en la ventana flotante).
    @Published var onSwitchMode: (() -> Void)?
    /// Abre Ajustes → Motores (botón de la tarjeta de error cuando falta un motor).
    var onOpenEngines: (() -> Void)?
    /// El último error fue «falta el motor…»: la tarjeta ofrece «Abrir Motores».
    @Published var failedForMissingEngine = false
    /// Hay archivos arrastrándose por la pantalla (la tarjeta invita a soltar).
    @Published var isDraggingFilesOnScreen = false
    /// Punto por donde entró el archivo: la rueda nace de ahí.
    @Published private(set) var wheelAnchor: UnitPoint = .center
    /// Rueda junto al cursor: no se cierra al salir de ella mientras sigue el arrastre.
    var keepWheelOnExit = false

    var isWheelVisible: Bool {
        if case .choosing = phase { return true }
        return false
    }

    var isPinned: Bool { phase == .choosing(pinned: true) }

    // MARK: - Arrastre

    /// Mientras otra conversión sigue en marcha también se puede abrir la rueda: lo nuevo espera su turno en la cola.
    func dragEntered(urls: [URL], modifiers: NSEvent.ModifierFlags, at anchor: UnitPoint = .center) -> Bool {
        guard !urls.isEmpty else { return false }
        wheelAnchor = anchor
        cancelAutoDismiss()
        files = urls.map(FileInfo.init)
        setMode(settings.mode(for: modifiers))
        withAnimation(DesignTokens.Motion.wheelAppear) { phase = .choosing(pinned: false) }
        return true
    }

    func dragUpdated(location: CGPoint, center: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let newMode = settings.mode(for: modifiers)
        if newMode != mode { setMode(newMode) }
        updateHighlight(location: location, center: center)
    }

    func dragExited() {
        guard !keepWheelOnExit, case .choosing(pinned: false) = phase else { return }
        withAnimation(DesignTokens.Motion.wheelAppear) { phase = restingPhase }
        highlighted = nil
    }

    func dropped() {
        if let index = highlighted, options.indices.contains(index) {
            execute(options[index])
        } else {
            // Soltado en el centro: la rueda se queda abierta para elegir con teclado o clic.
            phase = .choosing(pinned: true)
            highlighted = options.isEmpty ? nil : 0
            onNeedsKeyFocus?()
        }
    }

    /// Abrir la rueda desde el menú "Elegir archivo…" (útil con teclado y VoiceOver).
    func present(urls: [URL]) {
        guard !urls.isEmpty else { return }
        wheelAnchor = .center
        files = urls.map(FileInfo.init)
        setMode(.convert)
        withAnimation(DesignTokens.Motion.wheelAppear) { phase = .choosing(pinned: true) }
        highlighted = options.isEmpty ? nil : 0
        onNeedsKeyFocus?()
    }

    // MARK: - Selección

    private func setMode(_ newMode: WheelMode) {
        mode = newMode
        parentStack = []
        switch newMode {
        case .actions: options = ConversionEngine.fold(WheelCustomizer.apply(FileActions.options(for: files), files: files, mode: .actions))
        default: options = engine.options(for: files, mode: newMode)
        }
        highlighted = isPinned && !options.isEmpty ? 0 : nil
    }

    func nextMode() {
        let all = WheelMode.allCases
        let i = all.firstIndex(of: mode) ?? 0
        withAnimation(DesignTokens.Motion.hover) { setMode(all[(i + 1) % all.count]) }
    }

    /// Calcula qué gajo está bajo el cursor según el ángulo respecto al centro.
    func updateHighlight(location: CGPoint, center: CGPoint) {
        let index = Self.sliceIndex(at: location, center: center, count: options.count)
        if index != highlighted {
            withAnimation(DesignTokens.Motion.hover) { highlighted = index }
        }
    }

    static func sliceIndex(at point: CGPoint, center: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y   // y hacia abajo
        guard hypot(dx, dy) > DesignTokens.Wheel.innerRadius else { return nil }
        let span = 360.0 / Double(count)
        var degrees = atan2(dy, dx) * 180 / .pi       // 0° = derecha, sentido horario
        degrees += 90 + span / 2                       // 0° = arriba, centrado en el primer gajo
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return min(Int(degrees / span), count - 1)
    }

    func moveHighlight(by delta: Int) {
        guard !options.isEmpty else { return }
        let current = highlighted ?? (delta > 0 ? -1 : 0)
        let next = (current + delta + options.count) % options.count
        withAnimation(DesignTokens.Motion.hover) { highlighted = next }
    }

    func confirmHighlighted() {
        guard let index = highlighted, options.indices.contains(index) else { return }
        execute(options[index])
    }

    func cancel() {
        if phase == .working, let job = currentJobID { queue.cancelJob(job); return }
        withAnimation(DesignTokens.Motion.wheelAppear) { phase = restingPhase }
        highlighted = nil
    }

    // MARK: - Ejecución

    /// Las ruedas de las que venimos mientras se muestra un «Más…» (puede haber uno dentro de otro).
    @Published private(set) var parentStack: [[WheelOption]] = []

    var isInSubmenu: Bool { !parentStack.isEmpty }

    /// Vuelve a la rueda anterior (de «Más…» a la principal, o de un «Más…» al de fuera).
    func leaveSubmenu() {
        guard let parent = parentStack.last else { return }
        withAnimation(DesignTokens.Motion.wheelAppear) {
            options = parent
            parentStack.removeLast()
            highlighted = parent.firstIndex { $0.children != nil } ?? 0
        }
    }

    func execute(_ option: WheelOption) {
        // "Más…": la rueda se transforma en la segunda rueda y espera ratón o teclado.
        if let children = option.children {
            withAnimation(DesignTokens.Motion.wheelAppear) {
                parentStack.append(options)
                options = children
                phase = .choosing(pinned: true)
                highlighted = 0
            }
            onNeedsKeyFocus?()
            return
        }
        let files = self.files
        highlighted = nil
        parentStack = []

        if option.providerID == FileActions.providerID {
            withAnimation(DesignTokens.Motion.wheelAppear) { phase = restingPhase }
            do {
                if let message = try FileActions.perform(option, on: files) {
                    finish(.done(message: message, files: []))
                }
            } catch {
                finish(.failed(error.localizedDescription), errors: [error])
            }
            return
        }

        // Herramientas que primero necesitan elegir algo (zona de recorte, inicio y fin).
        if let editor = option.editor, !files.isEmpty {
            withAnimation(DesignTokens.Motion.wheelAppear) { phase = restingPhase }
            if editor.isPerFile && files.count > 1 {
                editOneByOne(option, editor: editor, files: files, index: 0)
                return
            }
            do {
                try EditorPresenter.shared.present(editor, files: files, option: option) { [weak self] parameters, chosen in
                    self?.runEngine(option, files: chosen, parameters: parameters)
                }
            } catch {
                finish(.failed(error.localizedDescription), errors: [error])
            }
            return
        }
        runEngine(option, files: files, parameters: [:])
    }

    /// Editar varias fotos (o sus metadatos): se abre la ventana de la primera; al guardar, se convierte en la
    /// cola y se abre la siguiente. Si cierras la ventana, las que faltan se saltan.
    private func editOneByOne(_ option: WheelOption, editor: EditorKind, files: [FileInfo], index: Int) {
        guard files.indices.contains(index) else { return }
        do {
            try EditorPresenter.shared.present(editor, files: [files[index]], option: option,
                                               step: "\(index + 1) de \(files.count)") { [weak self] parameters, chosen in
                self?.runEngine(option, files: chosen, parameters: parameters)
                DispatchQueue.main.async {
                    self?.editOneByOne(option, editor: editor, files: files, index: index + 1)
                }
            }
        } catch {
            finish(.failed(error.localizedDescription), errors: [error])
        }
    }

    private func runEngine(_ option: WheelOption, files: [FileInfo], parameters: [String: Double]) {
        jobTitle = files.count == 1 ? files[0].url.lastPathComponent : "\(files.count) archivos"
        progress = 0
        progressKnown = false
        waitingInQueue = queue.isRunning
        withAnimation(DesignTokens.Motion.wheelAppear) { phase = .working }
        let ticket = UUID()
        currentTicket = ticket
        var callbacks = ConversionQueue.Callbacks()
        callbacks.onStart = { [weak self] in
            guard let self, self.currentTicket == ticket else { return }
            self.waitingInQueue = false
        }
        callbacks.onProgress = { [weak self] value in
            guard let self, self.currentTicket == ticket, self.phase == .working else { return }
            self.progress = value
            if value > 0 { self.progressKnown = true }
        }
        callbacks.completion = { [weak self] outcome in
            // Una conversión anterior que termina mientras ya pediste otra: su resultado va a Recientes y a la
            // notificación, sin tocar la tarjeta.
            guard let self, self.currentTicket == ticket else { return }
            self.currentJobID = nil
            self.waitingInQueue = false
            // Si la rueda está abierta (elegías otra cosa), no se tapa con el resultado.
            if case .choosing = self.phase { return }
            // La cola ya guardó el resultado en Recientes y mostró la notificación.
            if let message = ConversionQueue.summary(of: outcome) {
                self.finish(.done(message: message, files: outcome.outputs))
            } else {
                self.finish(.failed(ConversionQueue.failureMessage(of: outcome)), errors: outcome.failures.map(\.error))
            }
        }
        currentJobID = queue.submit(option, files: files, parameters: parameters, callbacks: callbacks)
    }

    private func finish(_ newPhase: Phase, errors: [Error] = []) {
        failedForMissingEngine = errors.contains { ($0 as? ConversionError)?.isMissingTool == true }
        withAnimation(DesignTokens.Motion.wheelAppear) { phase = newPhase }
        // Los errores se quedan hasta que pulses «Cerrar»: así da tiempo a leerlos. El resultado bueno se oculta solo.
        if case .failed = newPhase {
            cancelAutoDismiss()
        } else {
            scheduleAutoDismiss(after: DesignTokens.Panel.resultDuration)
        }
    }

    func openEngines() {
        dismissResult()
        onOpenEngines?()
    }

    func showInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        dismissResult()
    }

    func dismissResult() {
        cancelAutoDismiss()
        withAnimation(DesignTokens.Motion.wheelAppear) { phase = .idle }
    }

    private func scheduleAutoDismiss(after seconds: Double) {
        cancelAutoDismiss()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .done, .failed: self.dismissResult()
            default: break
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelAutoDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }
}
