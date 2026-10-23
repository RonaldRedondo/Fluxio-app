import AppKit
import QuartzCore

/// Animación de cambio de modo: parece una sola ventana que se transforma en la otra.
///
/// macOS no puede convertir una ventana en otra, así que se hace una "foto" de las dos y se ponen
/// en una ventana temporal transparente. Allí un rectángulo con esquinas redondeadas cambia de
/// tamaño, posición y esquinas (con Core Animation, a 60 fps) mientras una foto se desvanece y la
/// otra aparece. La ventana real de destino ya está en su sitio, invisible, debajo de la animación: en los
/// últimos instantes aparece con un fundido (también su sombra) y la ventana temporal se quita cuando la real
/// ya se ve. Así el final no tiene saltos.
@MainActor
enum WindowMorph {
    /// Foto de lo que se ve en una ventana y dónde está en la pantalla.
    struct Snapshot {
        let image: CGImage
        /// Rectángulo visible en la pantalla (sin los márgenes transparentes).
        let rect: NSRect
    }

    /// Hace la foto de una ventana (aunque esté oculta).
    /// - `trimTransparent`: recorta los márgenes transparentes (la ventana flotante es más grande que su tarjeta).
    /// - `includeFrame`: incluye la barra de título (botones de cerrar, minimizar…).
    static func snapshot(of window: NSWindow, trimTransparent: Bool, includeFrame: Bool = false) -> Snapshot? {
        guard let content = window.contentView else { return nil }
        let view = includeFrame ? (content.superview ?? content) : content
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard var image = rep.cgImage else { return nil }

        let scale = CGFloat(image.width) / view.bounds.width
        // Parte visible, en píxeles (origen arriba a la izquierda).
        var visible = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if trimTransparent, let bounds = opaqueBounds(of: image) {
            visible = bounds
            image = image.cropping(to: bounds) ?? image
        }
        // A puntos de la vista. La de la ventana flotante cuenta desde arriba (`isFlipped`), las demás desde abajo;
        // si no se tiene en cuenta, la tarjeta (que no está centrada en su ventana) acaba desplazada.
        let y = view.isFlipped ? visible.minY / scale : view.bounds.height - visible.maxY / scale
        let inView = NSRect(x: visible.minX / scale, y: y,
                            width: visible.width / scale, height: visible.height / scale)
        let inWindow = view.convert(inView, to: nil)
        return Snapshot(image: image, rect: window.convertToScreen(inWindow))
    }

    /// Solo para la prueba automática: la animación corre sin verse en pantalla y deja ver su rectángulo.
    static var invisibleForTests = false
    private(set) static var lastBox: CALayer?
    private(set) static var lastLayers: (outgoing: CALayer, incoming: CALayer)?

    /// Transforma `from` en `to`. Oculta `source` al empezar, hace visible `destination` (ya colocada e
    /// invisible) al final y llama a `completion` cuando la animación termina.
    static func run(from: Snapshot, fromRadius: CGFloat, to: Snapshot, toRadius: CGFloat,
                    hiding source: NSWindow, revealing destination: NSWindow? = nil,
                    completion: @escaping () -> Void) {
        let margin = DesignTokens.Spacing.xxxl
        let area = from.rect.union(to.rect).insetBy(dx: -margin, dy: -margin)

        let stage = NSWindow(contentRect: area, styleMask: [.borderless], backing: .buffered, defer: false)
        stage.isOpaque = false
        stage.backgroundColor = .clear
        stage.hasShadow = false
        stage.ignoresMouseEvents = true
        stage.level = .statusBar
        stage.isReleasedWhenClosed = false
        stage.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero, size: area.size))
        host.wantsLayer = true
        stage.contentView = host
        let local = { (rect: NSRect) in rect.offsetBy(dx: -area.minX, dy: -area.minY) }
        let start = local(from.rect), end = local(to.rect)

        // El rectángulo que se transforma (recorta lo que tiene dentro con sus esquinas).
        let box = CALayer()
        box.frame = start
        box.cornerRadius = fromRadius
        box.cornerCurve = .continuous
        box.masksToBounds = true
        let outgoing = imageLayer(from.image, size: start.size)
        let incoming = imageLayer(to.image, size: start.size)
        incoming.opacity = 0
        box.addSublayer(outgoing)
        box.addSublayer(incoming)
        host.layer?.addSublayer(box)

        lastBox = box
        lastLayers = (outgoing, incoming)
        if invisibleForTests { stage.alphaValue = 0 }

        // Primero se ve la ventana temporal (idéntica a la de origen) y luego se oculta la real: sin parpadeo.
        stage.orderFrontRegardless()
        stage.displayIfNeeded()
        CATransaction.flush()
        source.orderOut(nil)

        let duration = DesignTokens.Motion.modeMorphDuration
        let reveal = DesignTokens.Motion.modeRevealDuration
        let handoff = destination == nil ? 0 : DesignTokens.Motion.modeHandoffDuration
        let ease = CubicBezier(DesignTokens.Motion.modeMorphCurve)
        let fromSize = start.size, toSize = end.size
        let fromCenter = CGPoint(x: start.midX, y: start.midY), toCenter = CGPoint(x: end.midX, y: end.midY)

        // Cada fotograma de la pantalla, Fluxio coloca la caja él mismo (en vez de dejar que macOS anime solo):
        // a veces macOS dejaba de pintar la ventana temporal y la animación se veía congelada.
        func beginMorph() {
            let began = CACurrentMediaTime()
            var finished = false
            FrameDriver.start(on: host) { now in
                let elapsed = now - began
                let p = min(1, max(0, elapsed / duration))
                let e = CGFloat(ease.value(at: p))
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let size = CGSize(width: fromSize.width + (toSize.width - fromSize.width) * e,
                                  height: fromSize.height + (toSize.height - fromSize.height) * e)
                box.bounds = CGRect(origin: .zero, size: size)
                box.position = CGPoint(x: fromCenter.x + (toCenter.x - fromCenter.x) * e,
                                       y: fromCenter.y + (toCenter.y - fromCenter.y) * e)
                box.cornerRadius = fromRadius + (toRadius - fromRadius) * e
                for layer in [outgoing, incoming] {
                    layer.bounds = box.bounds
                    layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
                }
                // La foto de origen se desvanece en la primera mitad y la de destino aparece en la segunda; ya
                // es opaca cuando la ventana real empieza a aparecer debajo, así no se transparenta.
                outgoing.opacity = Float(1 - ramp(p, from: 0.2, to: 0.6))
                incoming.opacity = Float(ramp(p, from: 0.25, to: 0.72))
                // Después, la animación se desvanece sobre la ventana real: la foto no puede reproducir los
                // fondos translúcidos (tarjeta, barra lateral) y así el paso es un fundido, no un salto.
                if handoff > 0 { box.opacity = Float(1 - ramp(elapsed, from: duration, to: duration + handoff)) }
                CATransaction.commit()

                if let destination {
                    // En los últimos instantes la ventana real aparece debajo (con su sombra, poco a poco).
                    destination.alphaValue = ramp(elapsed, from: duration - reveal, to: duration)
                }
                if elapsed >= duration, !finished {
                    finished = true
                    destination?.alphaValue = 1
                    completion()
                }
                guard elapsed >= duration + handoff else { return true }
                stage.orderOut(nil)
                return false
            }
        }

        // La animación empieza cuando la ventana temporal ya está en pantalla: si macOS tarda en mostrarla,
        // no se pierde el principio.
        waitUntilOnScreen(stage, beginMorph)
    }

    /// 0 antes de `from`, 1 después de `to` y en línea recta entre medias.
    private static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        min(1, max(0, (value - from) / (to - from)))
    }

    /// Llama a `action` en cuanto la ventana aparece en pantalla (como mucho espera 0,25 s).
    private static func waitUntilOnScreen(_ window: NSWindow, _ action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(0.25)
        func isOnScreen() -> Bool {
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]
            return (info?.first?[kCGWindowIsOnscreen as String] as? Bool) == true
        }
        if isOnScreen() { action(); return }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard isOnScreen() || Date() > deadline else { return }
                timer.invalidate()
                action()
            }
        }
    }

    /// Con "Reducir movimiento": la ventana de origen se desvanece y la de destino aparece en su sitio.
    static func crossfade(from source: NSWindow, to destination: NSWindow, show: () -> Void,
                          completion: @escaping () -> Void) {
        destination.alphaValue = 0
        show()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.Motion.modeFadeDuration
            source.animator().alphaValue = 0
            destination.animator().alphaValue = 1
        }, completionHandler: {
            MainActor.assumeIsolated {
                source.orderOut(nil)
                source.alphaValue = 1
                completion()
            }
        })
    }

    // MARK: Ayudantes

    private static func imageLayer(_ image: CGImage, size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        return layer
    }

    /// Rectángulo de los píxeles no transparentes (en píxeles, origen arriba a la izquierda).
    private static func opaqueBounds(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 2 {   // incluye la sombra entera, para que no quede cortada
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // En el búfer, la primera fila es la de arriba: ya está en "origen arriba".
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Curva de animación (Bézier cúbica, como las de CSS o Core Animation): convierte el tiempo (0…1) en avance.
struct CubicBezier {
    private let x1, y1, x2, y2: Double

    init(_ points: (Float, Float, Float, Float)) {
        (x1, y1, x2, y2) = (Double(points.0), Double(points.1), Double(points.2), Double(points.3))
    }

    func value(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        // Se busca el punto de la curva cuya x es `t` (método de Newton, con bisección de respaldo).
        var s = t
        for _ in 0..<8 {
            let x = sample(s, x1, x2) - t
            let slope = derivative(s, x1, x2)
            guard abs(x) > 1e-6, abs(slope) > 1e-6 else { break }
            s -= x / slope
        }
        if abs(sample(s, x1, x2) - t) > 1e-4 {
            var low = 0.0, high = 1.0
            s = t
            for _ in 0..<30 {
                let x = sample(s, x1, x2)
                if abs(x - t) < 1e-6 { break }
                if x < t { low = s } else { high = s }
                s = (low + high) / 2
            }
        }
        return sample(s, y1, y2)
    }

    private func sample(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }

    private func derivative(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b)
    }
}

/// Llama a `tick` en cada fotograma de la pantalla (con el reloj de Core Animation) hasta que devuelve `false`.
@MainActor
final class FrameDriver: NSObject {
    private static var running: Set<FrameDriver> = []
    private let tick: (CFTimeInterval) -> Bool
    private var link: AnyObject?
    private var timer: Timer?

    private init(tick: @escaping (CFTimeInterval) -> Bool) {
        self.tick = tick
    }

    static func start(on view: NSView, tick: @escaping (CFTimeInterval) -> Bool) {
        let driver = FrameDriver(tick: tick)
        running.insert(driver)
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: driver, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            driver.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                MainActor.assumeIsolated { driver.step() }
            }
            RunLoop.main.add(timer, forMode: .common)
            driver.timer = timer
        }
        driver.step()
    }

    @objc private func step() {
        guard tick(CACurrentMediaTime()) else { stop(); return }
    }

    private func stop() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        timer?.invalidate()
        link = nil
        timer = nil
        FrameDriver.running.remove(self)
    }
}
