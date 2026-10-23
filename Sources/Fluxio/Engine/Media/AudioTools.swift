import Foundation

/// Herramientas de audio: normalizar, canales, pitido y la imagen de la onda. Cada una es un filtro de FFmpeg;
/// el mismo filtro sirve para la vista previa de las ventanas (los primeros segundos) y para la copia final.
enum AudioFilters {
    static func normalize(loudness: Double, range: Double, peak: Double) -> String {
        String(format: "loudnorm=I=%.1f:LRA=%.1f:TP=%.1f", loudness, range, peak)
    }

    /// Mono o estéreo con el volumen de cada lado (1 = 100 %). Con audio mono, los dos lados salen del mismo canal.
    static func channels(mono: Bool, left: Double, right: Double, sourceChannels: Int) -> String {
        let r = sourceChannels >= 2 ? "c1" : "c0"
        // FFmpeg no deja usar el mismo canal dos veces en una salida («c0+c0»): con audio mono se suman los volúmenes.
        if mono && sourceChannels < 2 { return String(format: "pan=mono|c0=%.3f*c0", (left + right) / 2) }
        if mono { return String(format: "pan=mono|c0=%.3f*c0+%.3f*c1", left / 2, right / 2) }
        return String(format: "pan=stereo|c0=%.3f*c0|c1=%.3f*%@", left, right, r)
    }

    /// Solo un canal (para escucharlo aparte).
    static func solo(left: Bool, sourceChannels: Int) -> String {
        left || sourceChannels < 2 ? "pan=stereo|c0=c0|c1=c0" : "pan=stereo|c0=c1|c1=c1"
    }

    /// En cada tramo, el sonido se cambia por un pitido de 1 kHz.
    static func bleep(_ ranges: [(Double, Double)]) -> String {
        guard !ranges.isEmpty else { return "anull" }
        let inRange = ranges.map { String(format: "between(t,%.3f,%.3f)", $0.0, $0.1) }.joined(separator: "+")
        return "aeval=exprs='if(\(inRange),0.25*sin(2*PI*1000*t),val(ch))':c=same"
    }
}

enum AudioAnalysis {
    /// Número de canales del primer audio.
    static func channelCount(_ url: URL) -> Int {
        guard let ffprobe = ExternalTool.find("ffprobe"),
              let text = try? ExternalTool.capture(ffprobe, arguments: ["-v", "error", "-select_streams", "a:0",
                                                                         "-show_entries", "stream=channels", "-of", "csv=p=0", url.path])
        else { return 2 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 2
    }

    /// Picos de la onda: `bins` valores de 0 a 1 por canal (uno o dos canales).
    static func peaks(_ url: URL, channels: Int, bins: Int) -> [[Float]] {
        guard let ffmpeg = ExternalTool.find("ffmpeg"),
              let data = try? ExternalTool.captureData(ffmpeg, arguments: ["-v", "error", "-i", url.path, "-map", "0:a:0",
                                                                            "-ac", "\(channels)", "-ar", "4000", "-f", "f32le", "-"]),
              !data.isEmpty else { return Array(repeating: [], count: channels) }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = samples.count / channels
        guard frames > 0 else { return Array(repeating: [], count: channels) }
        var out = Array(repeating: [Float](repeating: 0, count: bins), count: channels)
        for f in 0..<frames {
            let bin = min(bins - 1, f * bins / frames)
            for c in 0..<channels { out[c][bin] = max(out[c][bin], abs(samples[f * channels + c])) }
        }
        let top = max(0.001, out.flatMap { $0 }.max() ?? 1)
        return out.map { $0.map { min(1, $0 / top) } }
    }

    /// Volumen actual (LUFS integrados), con el medidor de FFmpeg.
    static func loudness(_ url: URL) -> Double? {
        guard let ffmpeg = ExternalTool.find("ffmpeg") else { return nil }
        let text = (try? ExternalTool.captureStderr(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:a:0",
                                                                         "-af", "loudnorm=print_format=json", "-f", "null", "-"])) ?? ""
        guard let start = text.lastIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let value = (json["input_i"] as? String).flatMap(Double.init), value.isFinite else { return nil }
        return value
    }

    /// Vista previa: los primeros `seconds` segundos con el filtro aplicado, en un M4A temporal.
    static func preview(_ url: URL, filter: String, seconds: Double = 30) throws -> URL {
        let ffmpeg = try ExternalTool.require("ffmpeg", engine: "FFmpeg")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fluxio-preview-\(UUID().uuidString).m4a")
        _ = try ExternalTool.captureData(ffmpeg, arguments: ["-v", "error", "-y", "-i", url.path, "-map", "0:a:0", "-t", String(seconds),
                                                             "-af", filter, "-c:a", "aac", "-b:a", "192k", out.path])
        guard FileManager.default.fileExists(atPath: out.path) else { throw ConversionError.writeFailed("M4A") }
        return out
    }
}

extension ExternalTool {
    /// Lo que la herramienta escribe en la salida de errores (FFmpeg pone ahí sus mediciones).
    static func captureStderr(_ tool: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.string
    }
}
