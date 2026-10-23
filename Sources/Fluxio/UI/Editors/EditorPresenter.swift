import AppKit
import SwiftUI

/// Abre las ventanas de recorte y de corte, y devuelve lo elegido.
@MainActor
final class EditorPresenter: NSObject, NSWindowDelegate {
    static let shared = EditorPresenter()

    private var window: NSWindow?
    private var trimModel: TrimModel?
    /// Lo que hay que parar al cerrar (los reproductores de video).
    private var cleanup: (() -> Void)?
    private var onConfirm: (([String: Double], [FileInfo]) -> Void)?

    /// Abre la ventana de `kind`. Al confirmar devuelve los parámetros elegidos y los archivos (en el orden elegido).
    /// `step` ("2 de 3") se añade al título cuando se editan varios archivos uno tras otro.
    func present(_ kind: EditorKind, files: [FileInfo], option: WheelOption, step: String? = nil,
                 onConfirm: @escaping ([String: Double], [FileInfo]) -> Void) throws {
        guard let file = files.first else { return }
        close()
        self.onConfirm = onConfirm
        let controller: NSViewController
        let title: String

        switch kind {
        case .normalize, .channels, .bleep:
            let suffix = step.map { " · \($0)" } ?? ""
            let host: NSHostingController<AnyView>
            switch kind {
            case .normalize:
                let model = NormalizeModel(url: file.url)
                cleanup = { model.audio.stop() }
                title = "Normalizar volumen" + suffix
                host = NSHostingController(rootView: AnyView(NormalizeEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(model.parameters, files: [file]) })))
            case .channels:
                let model = ChannelsModel(url: file.url)
                cleanup = { model.audio.stop() }
                title = "Canales de audio" + suffix
                host = NSHostingController(rootView: AnyView(ChannelsEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(model.parameters, files: [file]) })))
            default:
                let model = BleepModel(url: file.url)
                cleanup = { model.audio.stop() }
                title = "Pitido" + suffix
                host = NSHostingController(rootView: AnyView(BleepEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(model.parameters, files: [file]) })))
            }
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return
        case .speed, .frames, .split:
            let suffix = step.map { " · \($0)" } ?? ""
            let host: NSHostingController<AnyView>
            switch kind {
            case .speed:
                let model = SpeedModel(url: file.url)
                cleanup = { model.video.stop() }
                title = "Cambiar velocidad" + suffix
                host = NSHostingController(rootView: AnyView(SpeedEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(["speed": model.speed], files: [file]) })))
            case .frames:
                let model = FramesModel(url: file.url)
                cleanup = { model.video.stop() }
                title = "Guardar fotogramas" + suffix
                host = NSHostingController(rootView: AnyView(FramesEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(model.parameters, files: [file]) })))
            default:
                let model = SplitModel(url: file.url)
                cleanup = { model.video.stop() }
                title = "Dividir video" + suffix
                host = NSHostingController(rootView: AnyView(SplitEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(model.parameters, files: [file]) })))
            }
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return
        case .collage:
            let model = CollageModel(files: files)
            title = "Crear collage"
            let host = NSHostingController(rootView: CollageEditorView(
                model: model, onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in
                    self?.confirm(["payload": ToolPayloadStore.shared.put(model.request)], files: model.order.files)
                }))
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return
        case .annotate, .background, .redact:
            let suffix = step.map { " · \($0)" } ?? ""
            let host: NSHostingController<AnyView>
            switch kind {
            case .annotate:
                guard let model = AnnotateModel(url: file.url) else { throw ConversionError.unreadable(file.url.lastPathComponent) }
                title = "Anotar foto" + suffix
                host = NSHostingController(rootView: AnyView(AnnotateEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(["payload": ToolPayloadStore.shared.put(model.annotations)], files: [file]) })))
            case .background:
                guard let model = BackgroundModel(url: file.url) else { throw ConversionError.unreadable(file.url.lastPathComponent) }
                title = "Añadir fondo" + suffix
                host = NSHostingController(rootView: AnyView(BackgroundEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(["payload": ToolPayloadStore.shared.put(model.finalStyle)], files: [file]) })))
            default:
                guard let model = RedactModel(url: file.url) else { throw ConversionError.unreadable(file.url.lastPathComponent) }
                title = "Ocultar zonas" + suffix
                host = NSHostingController(rootView: AnyView(RedactEditorView(
                    model: model, title: title, onCancel: { [weak self] in self?.close() },
                    onConfirm: { [weak self] in self?.confirm(["payload": ToolPayloadStore.shared.put(model.plan)], files: [file]) })))
            }
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return
        case .organize:
            guard let model = OrganizeModel(url: file.url) else {
                throw ConversionError.message("“\(file.url.lastPathComponent)” tiene contraseña o no se puede leer.")
            }
            title = "Organizar páginas" + (step.map { " · \($0)" } ?? "")
            let host = NSHostingController(rootView: OrganizePDFEditorView(
                model: model, title: title,
                onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in
                    self?.confirm(["payload": ToolPayloadStore.shared.put(model.plan)], files: [file])
                }))
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return
        case .metadata:
            let model = MetadataModel(file: file)
            title = "Metadatos" + (step.map { " · \($0)" } ?? "")
            let host = NSHostingController(rootView: MetadataEditorView(
                model: model, title: title,
                onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in
                    self?.confirm(["edits": MetadataEditStore.shared.put(model.collected)], files: [file])
                }))
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return
        case .photoEdit:
            guard let model = PhotoEditModel(url: file.url) else { throw ConversionError.unreadable(file.url.lastPathComponent) }
            title = "Editar foto" + (step.map { " · \($0)" } ?? "")
            let host = NSHostingController(rootView: PhotoEditorView(
                model: model, title: title, fileName: file.url.lastPathComponent,
                onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in self?.confirm(model.parameters, files: [file]) }))
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return
        case .order:
            let model = OrderModel(files: files)
            let isVideo = MediaFormat.kind(of: file).isVideo
            title = isVideo ? "Unir videos" : "Unir PDF"
            let host = NSHostingController(rootView: OrderEditorView(
                model: model, title: title,
                caption: isVideo ? "Orden de reproducción" : "Orden de los documentos",
                actionTitle: isVideo ? "Unir videos" : "Unir PDF",
                onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in self?.confirm(["ordered": 1], files: model.files) }))
            host.sizingOptions = [.preferredContentSize]
            present(makeToolWindow(controller: host, title: title))
            return

        case .crop:
            let isVideo = MediaFormat.kind(of: file).isVideo
            guard let model = isVideo ? CropModel(videoURL: file.url) : CropModel(url: file.url) else {
                throw ConversionError.unreadable(file.url.lastPathComponent)
            }
            title = "Recortar · \(file.url.lastPathComponent)" + (step.map { " (\($0))" } ?? "")
            controller = NSHostingController(rootView: CropEditorView(
                model: model,
                onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in self?.confirm(model.parameters, files: files) }))
        case .trim:
            let model = TrimModel(url: file.url, isVideo: MediaFormat.kind(of: file).isVideo)
            trimModel = model
            title = "Cortar · \(file.url.lastPathComponent)" + (step.map { " (\($0))" } ?? "")
            controller = NSHostingController(rootView: TrimEditorView(
                model: model,
                onCancel: { [weak self] in self?.close() },
                onConfirm: { [weak self] in self?.confirm(model.parameters, files: files) }))
        }

        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        present(window)
    }

    private func present(_ window: NSWindow) {
        window.delegate = self
        // Primero el tamaño que pide el contenido; luego se centra (si no, se centra con el tamaño provisional
        // y la ventana puede quedar medio fuera de la pantalla).
        if let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size.width > 0, size.height > 0 { window.setContentSize(size) }
        }
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func confirm(_ parameters: [String: Double], files: [FileInfo]) {
        let callback = onConfirm
        close()
        callback?(parameters, files)
    }

    private func close() {
        trimModel?.stop()
        trimModel = nil
        cleanup?(); cleanup = nil
        onConfirm = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        trimModel?.stop()
        trimModel = nil
        cleanup?(); cleanup = nil
        onConfirm = nil
        window = nil
    }
}
