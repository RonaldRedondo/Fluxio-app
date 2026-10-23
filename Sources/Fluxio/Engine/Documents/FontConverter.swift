import Foundation

/// Fuentes tipográficas: TTF ↔ OTF ↔ WOFF ↔ WOFF2, con fontTools (motor «FontTools» de Ajustes → Motores, o el de Homebrew).
/// TTF ↔ OTF convierte de verdad las curvas de cada letra (cuadráticas ↔ cúbicas).
struct FontConverter: Converter {
    let id = "font.convert"
    let mode = WheelMode.convert

    static let formats = ["ttf", "otf", "woff", "woff2"]

    func options(for file: FileInfo) -> [WheelOption] {
        let ext = file.url.pathExtension.lowercased()
        guard Self.formats.contains(ext) else { return [] }
        return Self.formats.filter { $0 != ext }.map { target in
            WheelOption(id: "\(id).\(target)", providerID: id, title: target.uppercased(), symbol: "textformat",
                        accessibilityLabel: "Convertir la fuente a \(target.uppercased())")
        }
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let target = action(of: option)
        guard Self.formats.contains(target) else { throw ConversionError.unsupported }
        let python = try Self.fontToolsPython()
        let temp = context.temporaryURL(ext: target)
        defer { try? FileManager.default.removeItem(at: temp) }
        context.report(0.1)
        try ExternalTool.run(python, arguments: ["-c", Self.script, file.url.path, temp.path, target], context: context)
        return [try context.finalize(temp: temp, for: file.url, ext: target)]
    }

    /// El Python con fontTools y brotli: el del motor de Fluxio o el que trae fonttools de Homebrew.
    static func fontToolsPython() throws -> URL {
        if FileManager.default.isExecutableFile(atPath: Engines.pythonInFluxio.path) { return Engines.pythonInFluxio }
        guard let launcher = ExternalTool.find("fonttools") else {
            throw ConversionError.missingTool(name: "fonttools", install: "FontTools")
        }
        let real = launcher.resolvingSymlinksInPath()
        if let first = (try? String(contentsOf: real, encoding: .utf8))?.split(separator: "\n").first,
           first.hasPrefix("#!") {
            let path = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        throw ConversionError.missingTool(name: "fonttools", install: "FontTools")
    }

    /// Script de conversión (basado en los ejemplos oficiales de fonttools: otf2ttf y ttf2otf).
    static let script = #"""
import sys
from fontTools.ttLib import TTFont, newTable

src, dst, target = sys.argv[1], sys.argv[2], sys.argv[3]
font = TTFont(src)
font.flavor = None
is_cff = "CFF " in font or "CFF2" in font

def otf_to_ttf(font):
    from fontTools.pens.cu2quPen import Cu2QuPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    order = font.getGlyphOrder()
    glyph_set = font.getGlyphSet()
    glyphs = {}
    for name in order:
        tt_pen = TTGlyphPen(glyph_set)
        glyph_set[name].draw(Cu2QuPen(tt_pen, 1.0, reverse_direction=True))
        glyphs[name] = tt_pen.glyph()
    for tag in ("CFF ", "CFF2", "VORG"):
        if tag in font:
            del font[tag]
    font["loca"] = newTable("loca")
    glyf = font["glyf"] = newTable("glyf")
    glyf.glyphOrder = order
    glyf.glyphs = glyphs
    maxp = font["maxp"] = newTable("maxp")
    maxp.tableVersion = 0x00010000
    for attr in ("maxZones", "maxTwilightPoints", "maxStorage", "maxFunctionDefs", "maxInstructionDefs",
                 "maxStackElements", "maxSizeOfInstructions", "maxComponentElements"):
        setattr(maxp, attr, 0)
    maxp.maxZones = 1
    post = font["post"]
    post.formatType = 2.0
    post.extraNames = []
    post.mapping = {}
    post.glyphOrder = order
    font["head"].glyphDataFormat = 0
    font.sfntVersion = "\x00\x01\x00\x00"

def ttf_to_otf(font):
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.t2CharStringPen import T2CharStringPen
    order = font.getGlyphOrder()
    glyph_set = font.getGlyphSet()
    hmtx = font["hmtx"]
    char_strings = {}
    for name in order:
        pen = T2CharStringPen(hmtx[name][0], glyph_set)
        glyph_set[name].draw(pen)
        char_strings[name] = pen.getCharString()
    for tag in ("glyf", "loca", "fpgm", "prep", "cvt ", "gasp", "hdmx", "LTSH", "VDMX"):
        if tag in font:
            del font[tag]
    ps_name = font["name"].getDebugName(6) or "Font"
    fb = FontBuilder(font=font, isTTF=False)
    fb.setupCFF(ps_name, {"FullName": font["name"].getDebugName(4) or ps_name}, char_strings, {})
    maxp = font["maxp"] = newTable("maxp")
    maxp.tableVersion = 0x00005000
    maxp.numGlyphs = len(order)
    font["post"].formatType = 3.0
    font.sfntVersion = "OTTO"

if target == "ttf" and is_cff:
    otf_to_ttf(font)
elif target == "otf" and not is_cff:
    ttf_to_otf(font)
if target in ("woff", "woff2"):
    font.flavor = target
font.save(dst)
"""#
}
