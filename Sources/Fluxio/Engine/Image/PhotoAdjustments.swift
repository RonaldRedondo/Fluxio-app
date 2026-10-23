import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Ajustes de "Editar foto": luz, color y detalle. Los mismos cálculos sirven para la vista previa (pequeña)
/// y para guardar la copia (a tamaño completo). Todo con Core Image, sin internet.
struct PhotoAdjustments {
    /// Un control de la ventana. Los valores van de `range.lowerBound` a `range.upperBound`; `0` no cambia nada.
    struct Control: Identifiable {
        let id: String
        let title: String
        let range: ClosedRange<Double>
        /// Cómo se muestra el número ("+12", "0.50 EV", "15°").
        let format: (Double) -> String

        init(_ id: String, _ title: String, _ range: ClosedRange<Double> = -100...100,
             format: @escaping (Double) -> String = { String(format: "%+.0f", $0) }) {
            self.id = id; self.title = title; self.range = range; self.format = format
        }
    }

    struct Group: Identifiable {
        let id: String
        let title: String
        let controls: [Control]
    }

    static let groups: [Group] = [
        Group(id: "light", title: "Luz", controls: [
            Control("exposure", "Exposición", -3...3, format: { String(format: "%+.2f EV", $0) }),
            Control("brightness", "Brillo"),
            Control("contrast", "Contraste"),
            Control("highlights", "Altas luces"),
            Control("shadows", "Sombras"),
            Control("whites", "Blancos"),
            Control("blacks", "Negros"),
            Control("gamma", "Gamma"),
        ]),
        Group(id: "color", title: "Color", controls: [
            Control("temperature", "Temperatura"),
            Control("tint", "Matiz"),
            Control("saturation", "Saturación"),
            Control("vibrance", "Intensidad"),
            Control("hue", "Tono", -180...180, format: { String(format: "%+.0f°", $0) }),
        ]),
        Group(id: "detail", title: "Detalle", controls: [
            Control("clarity", "Claridad", 0...100, format: { String(format: "%.0f", $0) }),
            Control("dehaze", "Quitar neblina", 0...100, format: { String(format: "%.0f", $0) }),
            Control("sharpness", "Nitidez", 0...100, format: { String(format: "%.0f", $0) }),
            Control("noise", "Reducir ruido", 0...100, format: { String(format: "%.0f", $0) }),
            Control("grain", "Grano", 0...100, format: { String(format: "%.0f", $0) }),
            Control("vignette", "Viñeta", 0...100, format: { String(format: "%.0f", $0) }),
        ]),
    ]

    var values: [String: Double]

    init(_ values: [String: Double] = [:]) { self.values = values }

    var isIdentity: Bool { values.values.allSatisfy { $0 == 0 } }

    private func v(_ id: String) -> Double { values[id] ?? 0 }
    /// De -100…100 a -1…1.
    private func unit(_ id: String) -> Double { v(id) / 100 }

    /// Aplica los ajustes. `scale` es el tamaño relativo de la imagen frente al original (la vista previa es
    /// más pequeña): los efectos con radio (claridad, grano) se escalan para que se vean igual.
    func apply(to input: CIImage, scale: Double = 1) -> CIImage {
        var image = input
        let extent = input.extent

        if v("exposure") != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = image; f.ev = Float(v("exposure"))
            image = f.outputImage ?? image
        }
        // Brillo, contraste y saturación.
        if v("brightness") != 0 || v("contrast") != 0 || v("saturation") != 0 {
            let f = CIFilter.colorControls(); f.inputImage = image
            f.brightness = Float(unit("brightness") * 0.25)
            f.contrast = Float(1 + unit("contrast") * 0.5)
            f.saturation = Float(1 + unit("saturation"))
            image = f.outputImage ?? image
        }
        // Negros, sombras, altas luces y blancos: una curva de tonos con cinco puntos.
        if ["blacks", "shadows", "highlights", "whites", "dehaze"].contains(where: { v($0) != 0 }) {
            let haze = v("dehaze") / 100
            let f = CIFilter.toneCurve(); f.inputImage = image
            f.point0 = CGPoint(x: 0, y: max(0, unit("blacks") * 0.15))
            f.point1 = CGPoint(x: 0.25, y: 0.25 + unit("shadows") * 0.12 - haze * 0.06)
            f.point2 = CGPoint(x: 0.5, y: 0.5 - haze * 0.03)
            f.point3 = CGPoint(x: 0.75, y: 0.75 + unit("highlights") * 0.12)
            f.point4 = CGPoint(x: 1, y: min(1, 1 + unit("whites") * 0.15))
            // Negros o blancos negativos: el extremo se acerca al centro.
            if unit("blacks") < 0 { f.point0 = CGPoint(x: -unit("blacks") * 0.15, y: 0) }
            if unit("whites") < 0 { f.point4 = CGPoint(x: 1 + unit("whites") * 0.15, y: 1) }
            image = f.outputImage ?? image
        }
        if v("gamma") != 0 {
            let f = CIFilter.gammaAdjust(); f.inputImage = image; f.power = Float(pow(2, -unit("gamma")))
            image = f.outputImage ?? image
        }
        if v("temperature") != 0 || v("tint") != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - unit("temperature") * 2500, y: -unit("tint") * 60)
            image = f.outputImage ?? image
        }
        if v("vibrance") != 0 || v("dehaze") != 0 {
            let f = CIFilter.vibrance(); f.inputImage = image
            f.amount = Float(unit("vibrance") + v("dehaze") / 100 * 0.3)
            image = f.outputImage ?? image
        }
        if v("hue") != 0 {
            let f = CIFilter.hueAdjust(); f.inputImage = image; f.angle = Float(v("hue") * .pi / 180)
            image = f.outputImage ?? image
        }
        // Claridad y neblina: contraste local (máscara de enfoque con radio grande).
        let local = v("clarity") / 100 * 0.6 + v("dehaze") / 100 * 0.4
        if local > 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = image
            f.radius = Float(max(2, 24 * scale)); f.intensity = Float(local)
            image = f.outputImage ?? image
        }
        if v("noise") > 0 {
            let f = CIFilter.noiseReduction(); f.inputImage = image
            f.noiseLevel = Float(v("noise") / 100 * 0.06); f.sharpness = 0.4
            image = f.outputImage ?? image
        }
        if v("sharpness") > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = image
            f.sharpness = Float(v("sharpness") / 100 * 1.5); f.radius = Float(max(0.5, 1.5 * scale))
            image = f.outputImage ?? image
        }
        if v("grain") > 0 {
            image = addGrain(to: image, amount: v("grain") / 100, scale: scale)
        }
        if v("vignette") > 0 {
            let f = CIFilter.vignette(); f.inputImage = image
            f.intensity = Float(v("vignette") / 100 * 1.6); f.radius = 1.6
            image = f.outputImage ?? image
        }
        return image.cropped(to: extent)
    }

    /// Grano de película: ruido gris mezclado suavemente.
    private func addGrain(to image: CIImage, amount: Double, scale: Double) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let gray = noise
            .transformed(by: CGAffineTransform(scaleX: max(0.5, scale), y: max(0.5, scale)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.35)),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            .cropped(to: image.extent)
        return gray.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }
}

/// Un solo contexto de Core Image para la vista previa y para guardar (crearlo cada vez es lento).
enum PhotoRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false])
}
