// Genera los iconos de Fluxio a partir del logo (Resources/Fluxio-logo.png):
//   - AppIcon.png: icono de la app, en el cuadrado redondeado estándar de macOS.
//   - MenuBarIcon.png: silueta monocroma para la barra de menú (macOS la pinta en blanco o negro).
// Uso: swift Scripts/make_icon.swift <logo.png> <carpeta-de-salida>
// Lo llama build_and_run.sh cuando falta Resources/AppIcon.icns.
import AppKit

let logoPath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
guard let logo = NSImage(contentsOfFile: logoPath),
      let logoCG = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("No pude leer el logo en \(logoPath)")
}

func savePNG(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

func canvas(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

// MARK: Icono de la app (1024 × 1024, rejilla de Apple: 824 px de forma y 100 px de margen)

let side = min(logoCG.width, logoCG.height)
let square = logoCG.cropping(to: CGRect(x: (logoCG.width - side) / 2, y: (logoCG.height - side) / 2,
                                        width: side, height: side))!
let app = canvas(1024, 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: app)
let shapeRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: shapeRect, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(srgbRed: 0.01, green: 0.02, blue: 0.06, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
shape.addClip()
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.cgContext.draw(square, in: shapeRect)
NSGraphicsContext.restoreGraphicsState()
savePNG(app, "AppIcon.png")

// MARK: Silueta para la barra de menú (36 px de alto = 18 pt en pantallas Retina)

// 1) Lo que brilla sobre el fondo oscuro es el logo: lo convertimos en negro con transparencia.
let w = logoCG.width, h = logoCG.height
let src = canvas(w, h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: src)
NSGraphicsContext.current?.cgContext.draw(logoCG, in: CGRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

let mask = canvas(w, h)
var minX = w, minY = h, maxX = 0, maxY = 0
let border = 8   // se ignoran los bordes de la imagen (a veces traen líneas sueltas)
for y in border..<(h - border) {
    for x in border..<(w - border) {
        var px = [Int](repeating: 0, count: 4)
        src.getPixel(&px, atX: x, y: y)
        let brightness = max(px[0], px[1], px[2])
        let alpha = min(255, max(0, (brightness - 45) * 255 / 70))
        var out = [0, 0, 0, alpha]
        mask.setPixel(&out, atX: x, y: y)
        if alpha > 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}

// 2) Recortamos al tamaño del logo y lo escalamos a 36 px de alto.
let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let maskCG = mask.cgImage!.cropping(to: bounds)!
let targetH = 36
let targetW = Int((Double(bounds.width) / Double(bounds.height) * Double(targetH)).rounded())
let menu = canvas(targetW, targetH)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: menu)
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.cgContext.draw(maskCG, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
NSGraphicsContext.restoreGraphicsState()
savePNG(menu, "MenuBarIcon.png")
print("Iconos creados: AppIcon.png (1024×1024) y MenuBarIcon.png (\(targetW)×\(targetH))")
