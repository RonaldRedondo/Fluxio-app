// Genera el icono de la barra de menú (Resources/MenuBarIcon.png) a partir de un logo con fondo transparente.
// Solo importa la forma (lo opaco): macOS la pinta en blanco o negro según el tema.
// Uso: swift Scripts/make_menubar_icon.swift <logo.png> <salida.png> [grosor]
//   grosor: cuántos píxeles del logo se engordan las líneas antes de reducirlo (0 = igual que el logo).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let src = NSBitmapImageRep(data: data) else {
    fatalError("Uso: swift Scripts/make_menubar_icon.swift <logo.png> <salida.png> [grosor]")
}
let thicken = args.count >= 4 ? Int(args[3]) ?? 0 : 0
let w = src.pixelsWide, h = src.pixelsHigh

// 1) Máscara: lo opaco que es cada píxel (0…255).
var alpha = [UInt8](repeating: 0, count: w * h)
for y in 0..<h {
    for x in 0..<w {
        alpha[y * w + x] = UInt8((src.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255)
    }
}

// 2) Engordar las líneas (cada píxel toma el máximo de su vecindad circular).
if thicken > 0 {
    var offsets: [(Int, Int)] = []
    for dy in -thicken...thicken { for dx in -thicken...thicken where dx * dx + dy * dy <= thicken * thicken {
        offsets.append((dx, dy))
    } }
    var out = alpha
    for y in 0..<h {
        for x in 0..<w where alpha[y * w + x] < 255 {
            var best = alpha[y * w + x]
            for (dx, dy) in offsets {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, alpha[ny * w + nx] > best { best = alpha[ny * w + nx] }
            }
            out[y * w + x] = best
        }
    }
    alpha = out
}

// 3) Recortar al área que ocupa el logo.
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 128 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
guard maxX >= minX else { fatalError("La imagen no tiene ninguna forma visible (¿el fondo es transparente?)") }

func canvas(_ cw: Int, _ ch: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}
let cw = maxX - minX + 1, ch = maxY - minY + 1
let mask = canvas(cw, ch)
for y in 0..<ch {
    for x in 0..<cw {
        var px = [0, 0, 0, Int(alpha[(y + minY) * w + x + minX])]
        mask.setPixel(&px, atX: x, y: y)
    }
}

// 4) Escalar a 36 px de alto (18 puntos en pantallas Retina).
let targetH = 36
let targetW = Int((Double(cw) / Double(ch) * Double(targetH)).rounded())
let menu = canvas(targetW, targetH)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: menu)
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.cgContext.draw(mask.cgImage!, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
NSGraphicsContext.restoreGraphicsState()
try! menu.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Icono de la barra de menú creado: \(targetW)×\(targetH) px")
