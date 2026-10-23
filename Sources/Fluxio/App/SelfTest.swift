import Foundation
import PDFKit

/// Ejecuta todas las conversiones e herramientas posibles sobre un archivo e informa del resultado.
enum SelfTest {
    /// Valores de ejemplo para las herramientas que abren una ventana.
    static let sampleParameters: [EditorKind: [String: Double]] = [
        .crop: ["x": 0.25, "y": 0.25, "w": 0.5, "h": 0.5],
        .trim: ["start": 1, "end": 3],
        .speed: ["speed": 2],
        .normalize: ["loudness": -16, "range": 11, "peak": -1.5],
        .channels: ["mono": 1, "left": 1, "right": 0.5],
        .bleep: ["count": 1, "s0": 0.2, "e0": 0.6],
        .frames: ["count": 2, "t0": 0.5, "t1": 1.5],
        .split: ["count": 1, "c0": 1.5],
        .photoEdit: ["exposure": 0.4, "contrast": 20, "temperature": 30, "vibrance": 25, "clarity": 40, "vignette": 30],
    ]

    @MainActor
    static func run(file path: String, outputFolder: String) -> Int32 {
        run(files: [path], outputFolder: outputFolder)
    }

    /// Con varios archivos prueba las opciones de grupo (unir, comprimir todo…).
    @MainActor
    static func run(files paths: [String], outputFolder: String) -> Int32 {
        _ = NSApplication.shared
        let files = paths.map { FileInfo(url: URL(fileURLWithPath: $0)) }
        let policy = OutputPolicy(customFolder: URL(fileURLWithPath: outputFolder, isDirectory: true),
                                  overwrite: true, quality: 0.9)
        var failures: Int32 = 0
        for converter in ConversionEngine.shared.converters {
            for option in converter.options(for: files) {
                let start = Date()
                var parameters = option.editor.flatMap { sampleParameters[$0] } ?? [:]
                // Metadatos: un cambio de prueba (los cambios viajan con un número que solo vale una vez).
                if option.editor == .metadata {
                    var edits = MetadataEdits()
                    switch MetadataKind.of(files[0]) {
                    case .pdf: edits.changes["pdf|Title"] = "Prueba de Fluxio"
                    case .media: edits.changes["tags|title"] = "Prueba de Fluxio"
                    default: edits.changes["{TIFF}|Software"] = "Fluxio"
                    }
                    parameters["edits"] = MetadataEditStore.shared.put(edits)
                }
                // Anotar, fondo y ocultar: un ejemplo de cada uno.
                switch option.editor {
                case .annotate:
                    parameters["payload"] = ToolPayloadStore.shared.put([
                        Annotation(kind: .arrow(CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.5)), color: MarkupPalette.colors[0]),
                        Annotation(kind: .text(CGPoint(x: 0.1, y: 0.7), "Fluxio"), color: .white),
                        Annotation(kind: .number(CGPoint(x: 0.8, y: 0.3), 1), color: MarkupPalette.colors[4]),
                        Annotation(kind: .magnifier(CGPoint(x: 0.6, y: 0.6), 0.1, 2), color: .white),
                    ])
                case .background:
                    parameters["payload"] = ToolPayloadStore.shared.put(BackgroundStyle())
                case .collage:
                    parameters["payload"] = ToolPayloadStore.shared.put(CollageRequest(layout: CollageLayout(), urls: files.map(\.url)))
                case .redact:
                    var plan = RedactionPlan(); plan.areas = [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)]; plan.style = .blur
                    parameters["payload"] = ToolPayloadStore.shared.put(plan)
                case .organize:
                    // Al revés, la primera duplicada y girada, y todas con el mismo ancho.
                    let count = PDFDocument(url: files[0].url)?.pageCount ?? 1
                    var pages = (0..<count).reversed().map { PDFOrganizePlan.Page(source: $0, rotation: 0) }
                    pages.append(PDFOrganizePlan.Page(source: 0, rotation: 90))
                    parameters["payload"] = ToolPayloadStore.shared.put(PDFOrganizePlan(pages: pages, sameWidth: true))
                default: break
                }
                let context = JobContext(policy: policy, parameters: parameters) { _ in }
                do {
                    let outputs = try converter.runBatch(option, on: files, context: context)
                        ?? files.flatMap { try converter.run(option, on: $0, context: context) }
                    print("OK    \(option.accessibilityLabel) → \(outputs.map(\.lastPathComponent).joined(separator: ", ")) (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
                } catch {
                    print("FALLO \(option.accessibilityLabel): \(error.localizedDescription)")
                    failures += 1
                }
            }
        }
        return failures
    }
}

import AppKit
import SwiftUI

/// Dibuja la ventana flotante en sus distintos estados como imágenes PNG (para revisar el diseño).
///   Fluxio --snapshot <carpeta> <archivo-de-ejemplo>
@MainActor
enum Snapshot {
    static func run(folder: String, sample: String) {
        let coordinator = DropCoordinator()
        coordinator.onSwitchMode = {}   // para que se vea el botón de cambio de modo
        let side: CGFloat = (DesignTokens.Wheel.outerRadius + DesignTokens.Wheel.backdropPadding) * 2 + 16
        let url = URL(fileURLWithPath: sample)

        func render(_ name: String, dark: Bool) {
            let view = NSHostingView(rootView: PanelRootView(coordinator: coordinator)
                .background(Color(nsColor: dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.85, alpha: 1))))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // dejar terminar animaciones
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(dark ? "oscuro" : "claro").png"))
        }

        for dark in [false, true] {
            coordinator.phase = .idle
            render("1-reposo", dark: dark)
            coordinator.present(urls: [url])
            coordinator.highlighted = 1
            render("2-rueda-convertir", dark: dark)
            coordinator.nextMode()
            render("3-rueda-herramientas", dark: dark)
            coordinator.nextMode()
            coordinator.highlighted = 0
            render("4-rueda-acciones", dark: dark)
            coordinator.phase = .done(message: "Listo: foto.png", files: [url])
            render("5-resultado", dark: dark)
            coordinator.phase = .failed(ConversionError.missingTool(name: "cwebp", install: "FFmpeg").localizedDescription)
            coordinator.failedForMissingEngine = true
            render("6-error", dark: dark)
            coordinator.failedForMissingEngine = false
        }
    }
}

/// Comprueba progreso y cancelación: convierte a WebM y cancela a los 2 segundos.
///   Fluxio --canceltest <video> <carpeta-de-salida>
enum CancelTest {
    static func run(file path: String, outputFolder: String) -> Int32 {
        let file = FileInfo(url: URL(fileURLWithPath: path))
        let policy = OutputPolicy(customFolder: URL(fileURLWithPath: outputFolder, isDirectory: true),
                                  overwrite: true, quality: 0.9)
        let progress = ProgressBox()
        let context = JobContext(policy: policy) { progress.value = $0 }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            print(String(format: "Progreso a los 2 s: %.0f%% — cancelando…", progress.value * 100))
            context.cancel()
        }
        let option = WheelOption(id: "media.convert.webm", providerID: "media.convert", title: "", symbol: "",
                                 accessibilityLabel: "")
        do {
            _ = try MediaConverter().run(option, on: file, context: context)
            print("FALLO: terminó sin cancelarse")
            return 1
        } catch {
            print("OK: \(error.localizedDescription)")
            return 0
        }
    }

    private final class ProgressBox: @unchecked Sendable { var value = 0.0 }

    /// Cancelar una sola fila: dos videos a la vez a WebM; se cancela solo el primero y el segundo debe terminar.
    @MainActor
    static func runOne(outputFolder: String, files paths: [String]) -> Int32 {
        _ = NSApplication.shared
        let engine = ConversionEngine.shared
        let files = paths.map { FileInfo(url: URL(fileURLWithPath: $0)) }
        let policy = OutputPolicy(customFolder: URL(fileURLWithPath: outputFolder, isDirectory: true),
                                  overwrite: true, quality: 0.9)
        let option = WheelOption(id: "media.convert.webm", providerID: "media.convert", title: "", symbol: "",
                                 accessibilityLabel: "")
        var result: ConversionEngine.Outcome?
        engine.run(option, on: files, policy: policy) { result = $0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print("Cancelando solo el primero…")
            engine.cancel(fileAt: 0)
        }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let first = result!.perFile[0], second = result!.perFile[1]
        print(first.isEmpty ? "OK: el primero se canceló" : "FALLO: el primero terminó igual")
        print(second.isEmpty ? "FALLO: el segundo no terminó" : "OK: el segundo terminó (\(second[0].lastPathComponent))")
        return first.isEmpty && !second.isEmpty ? 0 : 1
    }
}

extension Snapshot {
    /// Dibuja las ventanas de recorte y de corte.
    static func editors(folder: String, image: String, video: String) {
        func save(_ view: NSView, _ name: String, size: NSSize) {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(2.2))   // una descarga que se detiene un momento
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        if let crop = CropModel(url: URL(fileURLWithPath: image)) {
            crop.aspect = .r4x3
            crop.resize(corner: 3, by: CGSize(width: -0.2, height: -0.2))
            save(NSHostingView(rootView: CropEditorView(model: crop, onCancel: {}, onConfirm: {})),
                 "editor-recorte.png", size: NSSize(width: 700, height: 560))
        }
        let trim = TrimModel(url: URL(fileURLWithPath: video), isVideo: true)
        trim.start = 1.2
        trim.end = 4.5
        save(NSHostingView(rootView: TrimEditorView(model: trim, onCancel: {}, onConfirm: {})),
             "editor-corte.png", size: NSSize(width: 700, height: 560))
    }
}

/// Prueba el motor real (en paralelo): convierte varios archivos con una opción y mide el tiempo.
///   Fluxio --paralleltest <opción> <carpeta-de-salida> <archivos…>
@MainActor
enum ParallelTest {
    static func run(optionID: String, outputFolder: String, files paths: [String]) -> Int32 {
        let engine = ConversionEngine.shared
        let files = paths.map { FileInfo(url: URL(fileURLWithPath: $0)) }
        guard let option = engine.converters.flatMap({ $0.options(for: files) }).first(where: { $0.id == optionID }) else {
            print("Opción no disponible: \(optionID)"); return 1
        }
        let policy = OutputPolicy(customFolder: URL(fileURLWithPath: outputFolder, isDirectory: true),
                                  overwrite: false, quality: 0.9)
        let start = Date()
        var done = false
        var code: Int32 = 0
        engine.run(option, on: files, policy: policy) { outcome in
            print(String(format: "%.1f s · %d creados · %d fallos · a la vez: %d", Date().timeIntervalSince(start),
                         outcome.outputs.count, outcome.failures.count, ConversionEngine.parallelLimit))
            outcome.failures.forEach { print("FALLO", $0.file.lastPathComponent, $0.error.localizedDescription) }
            code = outcome.failures.isEmpty ? 0 : 1
            done = true
        }
        var lastPrint = Date()
        while !done {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if Date().timeIntervalSince(lastPrint) > 0.5, let job = engine.job {
                print(String(format: "  progreso: %.0f%% · %@", job.progress * 100, job.title))
                lastPrint = Date()
            }
        }
        return code
    }
}

extension Snapshot {
    /// Dibuja la tarjeta de progreso mientras convierte de verdad (para revisar que se actualiza).
    static func progress(folder: String, file: String, optionID: String) {
        let coordinator = DropCoordinator()
        let side: CGFloat = (DesignTokens.Wheel.outerRadius + DesignTokens.Wheel.backdropPadding) * 2 + 16
        let view = NSHostingView(rootView: PanelRootView(coordinator: coordinator, compact: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        coordinator.present(urls: [URL(fileURLWithPath: file)])
        guard let option = coordinator.options.first(where: { $0.id == optionID }) else { print("sin opción"); return }
        coordinator.execute(option)
        for second in [2.0, 5.0] {
            let until = Date().addingTimeInterval(second == 2 ? 2 : 3)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("progreso-\(Int(second))s.png"))
            print("t=\(second)s motor: \(Int((ConversionEngine.shared.job?.progress ?? -1) * 100))%")
        }
        ConversionEngine.shared.cancel()
    }
}

/// Prueba los ajustes de conversión: nombre, subcarpeta, imagen, video y PDF.
///   Fluxio --optionstest <carpeta-de-trabajo> <imagen> <video> <pdf>
@MainActor
enum OptionsTest {
    static func run(folder: String, image: String, video: String, pdf: String) -> Int32 {
        _ = NSApplication.shared
        let work = URL(fileURLWithPath: folder, isDirectory: true)
        // Copiamos los originales a la carpeta de trabajo para probar la subcarpeta "junto al original".
        func copy(_ path: String) -> FileInfo {
            let dest = work.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dest)
            return FileInfo(url: dest)
        }
        var policy = OutputPolicy(customFolder: nil, overwrite: true, quality: 0.9, subfolder: "Convertidos")
        policy.naming.pattern = "{nombre}_{formato}"
        policy.image = ImageOptions(resize: .longEdge, longEdge: 300, grayscale: true, flip: .horizontal, keepMetadata: false)
        policy.media = MediaOptions(resolution: .p480, codec: .hevc, quality: .small, audioBitrate: 96)
        policy.pdf = PDFOptions(pageRange: "2", dpi: 72)

        let cases: [(FileInfo, Converter, String)] = [
            (copy(image), ImageConverter(), "image.convert.png"),
            (copy(video), MediaConverter(), "media.convert.mkv"),
            (copy(pdf), ImageConverter(), "image.convert.png"),
        ]
        var failures: Int32 = 0
        for (file, converter, id) in cases {
            guard let option = converter.options(for: file).first(where: { $0.id == id }) else {
                print("FALLO sin opción \(id)"); failures += 1; continue
            }
            do {
                let out = try converter.run(option, on: file, context: JobContext(policy: policy) { _ in })
                print("OK", out.map { $0.path.replacingOccurrences(of: folder, with: "…") }.joined(separator: ", "))
            } catch {
                print("FALLO", id, error.localizedDescription); failures += 1
            }
        }
        return failures
    }
}

extension Snapshot {
    /// Dibuja la ventana de Ajustes, una imagen por pestaña.
    static func settings(folder: String) {
        // Una carpeta vigilada de ejemplo para ver cómo queda la fila (se deshace al terminar).
        let saved = AppSettings.shared.watchRules
        defer { AppSettings.shared.watchRules = saved }
        AppSettings.shared.watchRules = [WatchRule(path: NSHomeDirectory() + "/Downloads", target: "jpg"),
                                         WatchRule(path: NSHomeDirectory() + "/Desktop/Capturas", target: "webp", enabled: false)]
        for tab in SettingsTabs.Tab.allCases {
            let tabs = SettingsTabs()
            tabs.selected = tab
            let view = NSHostingView(rootView: SettingsView(tabs: tabs))
            view.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 560), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("ajustes-\(tab.rawValue).png"))
        }
    }
}

/// Prueba de carpeta vigilada: lo que ya estaba no se toca; un archivo copiado poco a poco se convierte al terminar.
///   Fluxio --watchtest <carpeta-nueva> <archivo-de-ejemplo>
@MainActor
enum WatchTest {
    static func run(folder: String, sample: String) -> Int32 {
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let source = URL(fileURLWithPath: sample)
        let ext = source.pathExtension
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: dir.appendingPathComponent("ya-estaba.\(ext)"))

        let settings = AppSettings.shared
        let saved = settings.watchRules
        defer { settings.watchRules = saved }
        let rule = WatchRule(path: dir.path, target: "png")
        FolderWatcher.shared.quiet = true
        FolderWatcher.shared.start()
        settings.watchRules = [rule]
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Copia lenta, como una descarga: la mitad, espera, el resto.
        let data = (try? Data(contentsOf: source)) ?? Data()
        let target = dir.appendingPathComponent("nuevo.\(ext)")
        fm.createFile(atPath: target.path, contents: data.prefix(data.count / 2))
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))   // una descarga que se detiene un momento
        let early = (try? fm.contentsOfDirectory(atPath: rule.outputURL.path)) ?? []
        if let handle = try? FileHandle(forWritingTo: target) {
            handle.seekToEndOfFile()
            handle.write(data.suffix(from: data.count / 2))
            try? handle.close()
        }
        let start = Date()
        let expected = rule.outputURL.appendingPathComponent("nuevo.png")
        while !fm.fileExists(atPath: expected.path) && Date().timeIntervalSince(start) < 20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // por si convirtiera algo más (no debería)
        let made = (try? fm.contentsOfDirectory(atPath: rule.outputURL.path)) ?? []
        print("antes de terminar la copia:", early.isEmpty ? "nada (bien)" : early.joined(separator: ", "))
        print("en Convertidos:", made.sorted().joined(separator: ", "),
              String(format: "(%.1f s tras terminar la copia)", Date().timeIntervalSince(start) - 1.5))
        let ok = made == ["nuevo.png"] && early.isEmpty
        print(ok ? "OK" : "FALLO")
        return ok ? 0 : 1
    }
}

/// Prueba de la cola compartida: trabajos en orden, resultado por archivo, cancelar uno en espera
/// y "Convertir todo" con formatos elegidos a mano.
///   Fluxio --queuetest <carpeta-de-salida> <imagen1> <imagen2> <video>
@MainActor
enum QueueTest {
    static func run(folder: String, image1: String, image2: String, video: String) -> Int32 {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let saved = (settings.destination, settings.customFolderPath, settings.showNotifications)
        defer { (settings.destination, settings.customFolderPath, settings.showNotifications) = saved }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        settings.destination = .customFolder
        settings.customFolderPath = folder
        settings.showNotifications = false
        ConversionQueue.shared.recordsHistory = false

        let queue = ConversionQueue.shared
        let engine = ConversionEngine.shared
        let images = [image1, image2].map { FileInfo(url: URL(fileURLWithPath: $0)) }
        let clip = FileInfo(url: URL(fileURLWithPath: video))
        guard let png = engine.option(for: images[0], target: "png"),
              let gif = engine.option(for: clip, target: "gif"),
              let jpg = engine.option(for: images[1], target: "jpg") else { print("FALLO: faltan opciones"); return 1 }
        var problems: [String] = []
        func check(_ ok: Bool, _ what: String) { print(ok ? "OK    " : "FALLO ", what); if !ok { problems.append(what) } }

        var order: [String] = []
        var callbacksA = ConversionQueue.Callbacks()
        callbacksA.onStart = { order.append("A") }
        var callbacksB = ConversionQueue.Callbacks()
        callbacksB.onStart = { order.append("B") }
        var cancelledC = false
        var callbacksC = ConversionQueue.Callbacks()
        callbacksC.completion = { cancelledC = $0.cancelled }

        queue.submit(png, files: images, callbacks: callbacksA)
        queue.submit(gif, files: [clip], callbacks: callbacksB)
        let jobC = queue.submit(png, files: [images[0]], callbacks: callbacksC)
        check(queue.items.filter { $0.status == .converting }.count == 2, "el primer trabajo empieza enseguida (2 imágenes)")
        check(queue.items.filter { $0.status == .queued }.count == 2, "los otros esperan su turno")
        queue.cancelJob(jobC)
        check(cancelledC && queue.items.last?.status == .cancelled, "cancelar un trabajo en espera")

        // "Convertir todo" con un formato elegido a mano (como en el modo Completo).
        let added = queue.add([URL(fileURLWithPath: image2)])
        queue.setOption(jpg, for: added[0])
        check(queue.readyCount == 1, "un archivo listo para convertir")
        queue.convertAll()

        let start = Date()
        while (queue.isRunning || queue.items.contains { $0.status == .queued }) && Date().timeIntervalSince(start) < 120 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        check(order == ["A", "B"], "los trabajos se hacen en orden: \(order)")
        let done = queue.items.filter { $0.status == .done }
        check(done.count == 4, "4 archivos convertidos (\(done.count))")
        check(queue.items.first { $0.id == added[0] }?.outputs.first?.pathExtension == "jpg", "«jpg» da JPG, no JPEG 2000")
        check(done.allSatisfy { $0.outputs.count == 1 && FileManager.default.fileExists(atPath: $0.outputs[0].path) },
              "cada archivo sabe qué creó")
        for item in queue.items { print("   ", item.name, "→", item.status, item.outputs.map(\.lastPathComponent)) }
        queue.clearFinished()
        check(queue.items.isEmpty, "limpiar lo terminado")
        return problems.isEmpty ? 0 : 1
    }
}

extension Snapshot {
    /// Dibuja la ventana del modo Completo con archivos en la cola: esperando, convirtiendo y terminados.
    ///   Fluxio --snapshot-full <carpeta> <archivo1> <archivo2> …
    static func full(folder: String, files: [String]) {
        let settings = AppSettings.shared
        let saved = (settings.destination, settings.customFolderPath, settings.showNotifications)
        defer { (settings.destination, settings.customFolderPath, settings.showNotifications) = saved }
        let output = URL(fileURLWithPath: folder).appendingPathComponent("salida")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        settings.destination = .customFolder
        settings.customFolderPath = output.path
        settings.showNotifications = false
        ConversionQueue.shared.recordsHistory = false

        let model = FullModeModel()
        model.lastFormatKey = nil
        model.add(files.map { URL(fileURLWithPath: $0) })
        let queue = ConversionQueue.shared
        // Formatos de ejemplo: el primero que tenga cada archivo entre estos.
        for item in queue.items.dropLast() {
            for key in ["png", "jpg", "gif", "mp3", "pdf"] {
                if let option = ConversionEngine.shared.option(for: item.file, target: key) {
                    queue.setOption(option, for: item.id); break
                }
            }
        }
        let size = DesignTokens.FullMode.windowSize

        func render(_ name: String, dark: Bool) {
            let view = NSHostingView(rootView: FullModeView(model: model))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = view.appearance
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(dark ? "oscuro" : "claro").png"))
        }

        for dark in [false, true] { render("1-cola", dark: dark) }
        queue.convertAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        render("2-convirtiendo", dark: false)
        let start = Date()
        while queue.isRunning && Date().timeIntervalSince(start) < 60 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        for dark in [false, true] { render("3-terminado", dark: dark) }
        model.page = .settings(.general)
        render("4-ajustes", dark: false)
        model.page = .about
        for dark in [false, true] { render("5-acerca", dark: dark) }
        model.page = .wheel
        for dark in [false, true] { render("6-rueda", dark: dark) }
        model.page = .settings(.engines)
        for dark in [false, true] { render("7-motores", dark: dark) }
        for item in queue.items { print(item.name, item.status, item.outputs.map(\.lastPathComponent)) }
    }
}

/// Prueba de la animación de cambio de modo, sin mostrar nada en pantalla: mide el rectángulo que se
/// transforma varias veces por segundo (tamaño, esquinas, opacidad) y dibuja algunos fotogramas.
///   Fluxio --morphtest <carpeta>
@MainActor
enum MorphTest {
    static func run(folder: String) -> Int32 {
        _ = NSApplication.shared
        WindowMorph.invisibleForTests = true
        let panel = FloatingPanel(coordinator: DropCoordinator())
        let full = FullModeWindowController()
        let window = full.prepare()
        var problems = 0

        func measure(_ name: String, from: WindowMorph.Snapshot, fromRadius: CGFloat,
                     to: WindowMorph.Snapshot, toRadius: CGFloat, source: NSWindow) {
            print("\n\(name): de \(Int(from.rect.width))×\(Int(from.rect.height)) a \(Int(to.rect.width))×\(Int(to.rect.height))")
            var finished = false
            let start = Date()
            WindowMorph.run(from: from, fromRadius: fromRadius, to: to, toRadius: toRadius, hiding: source) {
                finished = true
            }
            var samples: [(t: Double, w: CGFloat, r: CGFloat, out: Float, inc: Float)] = []
            var frame = 0
            while !finished && Date().timeIntervalSince(start) < 2 {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                guard let box = WindowMorph.lastBox?.presentation(),
                      let layers = WindowMorph.lastLayers else { continue }
                let t = Date().timeIntervalSince(start)
                samples.append((t, box.bounds.width, box.cornerRadius,
                                layers.outgoing.presentation()?.opacity ?? -1, layers.incoming.presentation()?.opacity ?? -1))
                if frame % 6 == 0, let layer = WindowMorph.lastBox?.superlayer?.presentation() {
                    // Dibuja el fotograma actual.
                    let size = layer.bounds.size
                    if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                       let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                        layer.render(in: ctx.cgContext)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(frame).png"))
                    }
                }
                frame += 1
            }
            let total = Date().timeIntervalSince(start)
            for s in samples where Int(s.t * 1000) % 50 < 17 || s.t == samples.last?.t {
                print(String(format: "  %3.0f ms  ancho %6.1f  esquinas %4.1f  origen %.2f  destino %.2f",
                             s.t * 1000, s.w, s.r, s.out, s.inc))
            }
            let widths = samples.map(\.w)
            let monotonic = zip(widths, widths.dropFirst()).allSatisfy { from.rect.width > to.rect.width ? $0 >= $1 - 0.5 : $0 <= $1 + 0.5 }
            let ok = finished && total < 0.6 && monotonic && samples.count > 12
            print(String(format: "  %@ · %.0f ms · %d fotogramas medidos · sin saltos: %@", ok ? "OK" : "FALLO",
                         total * 1000, samples.count, monotonic ? "sí" : "no"))
            if !ok { problems += 1 }
        }

        guard let fullShot = WindowMorph.snapshot(of: window, trimTransparent: false, includeFrame: true),
              let liteShot = WindowMorph.snapshot(of: panel, trimTransparent: true) else {
            print("FALLO: no pude fotografiar las ventanas"); return 1
        }
        measure("completo-a-lite", from: fullShot, fromRadius: DesignTokens.FullMode.windowCornerRadius,
                to: liteShot, toRadius: DesignTokens.Radius.largeCard, source: window)
        measure("lite-a-completo", from: liteShot, fromRadius: DesignTokens.Radius.largeCard,
                to: fullShot, toRadius: DesignTokens.FullMode.windowCornerRadius, source: panel)
        return problems == 0 ? 0 : 1
    }
}

