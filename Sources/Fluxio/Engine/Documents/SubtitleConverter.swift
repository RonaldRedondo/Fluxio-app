import Foundation

/// Convierte subtítulos SRT ↔ VTT, o los pasa a texto plano (transcripción).
struct SubtitleConverter: Converter {
    let id = "subtitle.convert"
    let mode = WheelMode.convert

    private struct Cue {
        var start: String   // siempre "00:00:01.500"
        var end: String
        var text: [String]
    }

    /// SRT y VTT se convierten aquí mismo; ASS/SSA (karaoke, anime) y LRC (letras de canciones) pasan por ffmpeg.
    private static let viaFFmpeg = ["ass", "ssa", "lrc"]

    func options(for file: FileInfo) -> [WheelOption] {
        let ext = file.url.pathExtension.lowercased()
        guard ["srt", "vtt", "ass", "ssa", "lrc"].contains(ext) else { return [] }
        let all = [("srt", "SRT", "captions.bubble", "Convertir a SRT"),
                   ("vtt", "VTT", "captions.bubble", "Convertir a VTT"),
                   ("ass", "ASS", "captions.bubble.fill", "Convertir a ASS"),
                   ("lrc", "LRC", "music.note.list", "Convertir a letra LRC"),
                   ("txt", "Texto", "text.alignleft", "Extraer solo el texto")]
        return all.filter { $0.0 != ext && !(ext == "ssa" && $0.0 == "ass") }
            .map { option($0.0, $0.1, $0.2, $0.3) }
    }

    private func option(_ target: String, _ title: String, _ symbol: String, _ label: String) -> WheelOption {
        WheelOption(id: "\(id).\(target)", providerID: id, title: title, symbol: symbol, accessibilityLabel: label)
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        let target = String(option.id.dropFirst(id.count + 1))
        let sourceExt = file.url.pathExtension.lowercased()
        var input = file.url
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }

        // ASS/SSA/LRC de entrada: primero a SRT con ffmpeg.
        if Self.viaFFmpeg.contains(sourceExt) {
            let srt = context.temporaryURL(ext: "srt")
            cleanup.append(srt)
            try Self.ffmpeg(input, to: srt, context: context)
            input = srt
        }
        // ASS/LRC de salida: preparamos un SRT y ffmpeg lo convierte al final.
        if Self.viaFFmpeg.contains(target) {
            let srt = context.temporaryURL(ext: "srt")
            cleanup.append(srt)
            if input == file.url { try FileManager.default.copyItem(at: file.url, to: srt) } else {
                try FileManager.default.moveItem(at: input, to: srt)
            }
            if sourceExt == "vtt" {   // VTT → SRT antes de pasar a ffmpeg
                let text = try String(contentsOf: srt, encoding: .utf8)
                try srtText(parse(text)).write(to: srt, atomically: true, encoding: .utf8)
            }
            let out = context.temporaryURL(ext: target)
            cleanup.append(out)
            try Self.ffmpeg(srt, to: out, context: context)
            return [try context.finalize(temp: out, for: file.url, ext: target)]
        }

        guard let data = try? Data(contentsOf: input),
              var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ConversionError.unreadable(file.url.lastPathComponent)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let cues = parse(text)
        guard !cues.isEmpty else {
            throw ConversionError.message("No encontré subtítulos dentro de “\(file.url.lastPathComponent)”.")
        }

        let output: String
        switch target {
        case "vtt":
            output = "WEBVTT\n\n" + cues.map { "\($0.start) --> \($0.end)\n\($0.text.joined(separator: "\n"))" }
                .joined(separator: "\n\n") + "\n"
        case "srt":
            output = cues.enumerated().map { i, cue in
                "\(i + 1)\n\(cue.start.replacingOccurrences(of: ".", with: ",")) --> \(cue.end.replacingOccurrences(of: ".", with: ","))\n\(cue.text.joined(separator: "\n"))"
            }.joined(separator: "\n\n") + "\n"
        default:
            // Texto sin etiquetas como <i> o {\an8}.
            output = cues.map { $0.text.joined(separator: " ") }
                .map { $0.replacingOccurrences(of: #"<[^>]+>|\{[^}]+\}"#, with: "", options: .regularExpression) }
                .joined(separator: "\n") + "\n"
        }

        let temp = context.temporaryURL(ext: target)
        defer { try? FileManager.default.removeItem(at: temp) }
        try output.write(to: temp, atomically: true, encoding: .utf8)
        return [try context.finalize(temp: temp, for: file.url, ext: target)]
    }

    private static func ffmpeg(_ input: URL, to output: URL, context: JobContext) throws {
        let ffmpeg = try ExternalTool.require("ffmpeg", engine: "FFmpeg")
        try ExternalTool.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y", "-i", input.path, output.path],
                             context: context)
    }

    private func srtText(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, cue in
            "\(i + 1)\n\(cue.start.replacingOccurrences(of: ".", with: ",")) --> \(cue.end.replacingOccurrences(of: ".", with: ","))\n\(cue.text.joined(separator: "\n"))"
        }.joined(separator: "\n\n") + "\n"
    }

    /// Lee bloques "inicio --> fin" + texto. Sirve para SRT y VTT.
    private func parse(_ text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = normalize(parts[0]),
                  let end = normalize(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            cues.append(Cue(start: start, end: end, text: Array(lines[(timingIndex + 1)...])))
        }
        return cues
    }

    /// "1:02,5" / "01:02.500" / "00:01:02,500" → "00:01:02.500"
    private func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let pieces = s.components(separatedBy: ":")
        guard pieces.count == 2 || pieces.count == 3 else { return nil }
        let secParts = pieces.last!.components(separatedBy: ".")
        guard let sec = Int(secParts[0]) else { return nil }
        let millis = Int((secParts.count > 1 ? secParts[1] : "0").padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3)) ?? 0
        let minutes = Int(pieces[pieces.count - 2]) ?? 0
        let hours = pieces.count == 3 ? (Int(pieces[0]) ?? 0) : 0
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, sec, millis)
    }
}
