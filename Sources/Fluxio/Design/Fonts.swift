import AppKit
import CoreText
import SwiftUI

/// Inter va dentro de la app (Resources/Fonts/InterVariable.ttf, licencia libre OFL) y funciona sin internet.
/// Es una fuente "variable": un solo archivo con todos los pesos, que se eligen con su eje de grosor (wght).
enum Fonts {
    private static let postScriptName = "InterVariable"
    /// Ejes de una fuente variable (identificadores de 4 letras convertidos a número).
    private static let weightAxis = 0x7767_6874      // 'wght'
    private static let opticalSizeAxis = 0x6F70_737A // 'opsz'

    /// Registra las fuentes incluidas en la app. Se llama una vez al arrancar.
    static func registerBundled() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static var isInterAvailable: Bool { NSFont(name: postScriptName, size: 13) != nil }

    /// Fuente de un estilo de texto. Si Inter no estuviera (por ejemplo, en pruebas), usa SF Pro.
    static func font(_ style: DesignTokens.Typography.Style) -> Font {
        Font(nsFont(style))
    }

    static func nsFont(_ style: DesignTokens.Typography.Style) -> NSFont {
        if style.monospaced {
            return NSFont.monospacedSystemFont(ofSize: style.size, weight: systemWeight(style.weight))
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: postScriptName,
            .variation: [weightAxis: style.weight.rawValue,
                         opticalSizeAxis: min(32, max(14, style.size))],
            // Rasgos tipográficos del sistema de diseño: ligaduras y alternativas "ss03".
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kStylisticAlternativesType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kStylisticAltThreeOnSelector]],
        ])
        if isInterAvailable, let font = NSFont(descriptor: descriptor, size: style.size) {
            return font
        }
        return NSFont.systemFont(ofSize: style.size, weight: systemWeight(style.weight))
    }

    private static func systemWeight(_ weight: DesignTokens.Typography.Weight) -> NSFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}
