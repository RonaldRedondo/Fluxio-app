// Prepara el logo de texto para la barra lateral del modo Completo.
// El original tiene fondo oscuro: se separa en dos capas con fondo transparente:
//   - Wordmark-text.png: las letras (solo forma; Fluxio las pinta del color del texto, claro u oscuro).
//   - Wordmark-dot.png: el punto de color, con sus colores originales.
// Uso: swift Scripts/make_wordmark.swift <logo.png> <carpeta-de-salida>
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let src = NSBitmapImageRep(data: data) else { fatalError("Uso: swift Scripts/make_wordmark.swift <logo.png> <carpeta>") }
let w = src.pixelsWide, h = src.pixelsHigh

func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
    let c = src.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
}
// El color de fondo: la esquina de arriba a la izquierda.
let bg = rgb(2, 2)
let bgLuma = 0.3 * bg.0 + 0.59 * bg.1 + 0.11 * bg.2

var text = [Double](repeating: 0, count: w * h)
var dot = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: w * h)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let (r, g, b) = rgb(x, y)
        let luma = 0.3 * r + 0.59 * g + 0.11 * b
        let saturation = max(r, g, b) - min(r, g, b)
        let distance = max(abs(r - bg.0), abs(g - bg.1), abs(b - bg.2))
        guard distance > 0.06 else { continue }
        if saturation > 0.25 {
            // Punto de color: opacidad según lo que se separa del fondo.
            let a = min(1, distance / 0.6)
            dot[y * w + x] = (r, g, b, a)
        } else {
            text[y * w + x] = min(1, max(0, (luma - bgLuma) / (1 - bgLuma)))
        }
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let cw = maxX - minX + 1, ch = maxY - minY + 1

func save(_ name: String, _ pixel: (Int) -> [Int]) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<ch { for x in 0..<cw {
        var px = pixel((y + minY) * w + x + minX)
        rep.setPixel(&px, atX: x, y: y)
    } }
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
}
save("Wordmark-text.png") { i in [0, 0, 0, Int(text[i] * 255)] }
save("Wordmark-dot.png") { i in
    let (r, g, b, a) = dot[i]
    // Color sin premultiplicar.
    return a > 0 ? [Int(r * 255 * a), Int(g * 255 * a), Int(b * 255 * a), Int(a * 255)] : [0, 0, 0, 0]
}
print("Logo de texto preparado: \(cw)×\(ch) px")
