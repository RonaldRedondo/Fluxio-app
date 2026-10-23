// Dibuja el fondo de la ventana del instalador (Fluxio.dmg): degradado de Fluxio con grano, una tarjeta clara
// donde Finder pone el icono de Fluxio y la carpeta Aplicaciones, una flecha ondulada entre los dos y el texto
// «Arrastra Fluxio a Aplicaciones».
// Uso: swift Scripts/make_dmg_background.swift <carpeta-de-salida>
//      → fondo.png (1x) y fondo@2x.png; make_dmg.sh los junta en fondo.tiff.
// Las posiciones de los iconos están en make_dmg.sh (deben coincidir con `iconLeft` e `iconRight`).
import AppKit
import CoreText

let window = CGSize(width: 660, height: 400)     // tamaño de la ventana en puntos
let iconLeft = CGPoint(x: 170, y: 160)            // centro del icono de Fluxio (desde arriba a la izquierda)
let iconRight = CGPoint(x: 490, y: 160)           // centro de la carpeta Aplicaciones
let card = CGRect(x: 40, y: 40, width: 580, height: 250)
let cyan = NSColor(srgbRed: 0x00 / 255, green: 0xB9 / 255, blue: 0xFD / 255, alpha: 1)
let violet = NSColor(srgbRed: 0x83 / 255, green: 0x63 / 255, blue: 0xFB / 255, alpha: 1)
let cardColor = NSColor(srgbRed: 0.985, green: 0.982, blue: 0.965, alpha: 1)

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Resources/Fonts/InterVariable.ttf") as CFURL, .process, nil)

func inter(_ size: CGFloat, weight: CGFloat) -> NSFont {
    let wght = 0x77676874   // eje «wght» de la fuente variable
    let descriptor = NSFontDescriptor(fontAttributes: [
        .family: "Inter",
        NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight],
    ])
    return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: .heavy)
}

func render(scale: CGFloat) -> Data {
    let px = CGSize(width: window.width * scale, height: window.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = window
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Coordenadas desde arriba a la izquierda, como Finder.
    cg.translateBy(x: 0, y: window.height)
    cg.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = flipped

    // Fondo: degradado cian → violeta en diagonal.
    let all = CGRect(origin: .zero, size: window)
    NSGradient(starting: cyan, ending: violet)!.draw(in: all, angle: 35)

    // Grano fino, como el papel del ejemplo.
    var generator = SystemRandomNumberGenerator()
    let dot = 1 / scale
    for _ in 0..<Int(px.width * px.height * 0.18) {
        let x = CGFloat.random(in: 0..<window.width, using: &generator)
        let y = CGFloat.random(in: 0..<window.height, using: &generator)
        let light = Bool.random(using: &generator)
        (light ? NSColor.white : NSColor.black).withAlphaComponent(0.07).setFill()
        CGRect(x: x, y: y, width: dot, height: dot).fill()
    }

    // Tarjeta clara con sombra suave.
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    cardColor.setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Flecha ondulada con el degradado de Fluxio.
    let start = CGPoint(x: iconLeft.x + 92, y: iconLeft.y)
    let end = CGPoint(x: iconRight.x - 98, y: iconLeft.y)
    let wave = CGMutablePath()
    wave.move(to: start)
    let waves = 4
    let step = (end.x - start.x - 14) / CGFloat(waves)
    for i in 0..<waves {
        let x0 = start.x + CGFloat(i) * step
        wave.addCurve(to: CGPoint(x: x0 + step, y: start.y),
                      control1: CGPoint(x: x0 + step * 0.3, y: start.y - 14),
                      control2: CGPoint(x: x0 + step * 0.7, y: start.y + 14))
    }
    wave.addLine(to: end)
    wave.move(to: CGPoint(x: end.x - 13, y: end.y - 14))
    wave.addLine(to: end)
    wave.addLine(to: CGPoint(x: end.x - 13, y: end.y + 14))
    let stroke = wave.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10)
    cg.saveGState()
    cg.addPath(stroke)
    cg.clip()
    NSGradient(starting: cyan, ending: violet)!.draw(in: stroke.boundingBox.insetBy(dx: -2, dy: -2), angle: 0)
    cg.restoreGState()

    // Texto de abajo.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let title = NSAttributedString(string: "Arrastra Fluxio a Aplicaciones", attributes: [
        .font: inter(30, weight: 800), .foregroundColor: NSColor.white, .kern: -0.9, .paragraphStyle: paragraph,
    ])
    let height = title.size().height
    title.draw(in: CGRect(x: 0, y: 342 - height / 2, width: window.width, height: height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try! render(scale: 1).write(to: out.appendingPathComponent("fondo.png"))
try! render(scale: 2).write(to: out.appendingPathComponent("fondo@2x.png"))
print("✅ Fondo en \(out.path)")
