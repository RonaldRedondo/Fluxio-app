import ImageIO
import AppKit
import Foundation

/// Herramientas de audio y video (rueda ⌘): comprimir, cortar, quitar el sonido y unir varios videos.
struct MediaToolsConverter: Converter {
    let id = "media.tools"
    let mode = WheelMode.tools

    private enum Tool: String {
        case trim, compress, mute, join, speed, frames, split, crop, normalize, channels, bleep, waveform
    }

    /// Con varios videos aparece "Unir videos" (primero se elige el orden).
    func options(for files: [FileInfo]) -> [WheelOption] {
        var result: [WheelOption] = []
        if files.count > 1 && files.allSatisfy({ MediaFormat.kind(of: $0).isVideo }) {
            var join = option(.join, "Unir videos", "film.stack", "Unir los videos en uno solo")
            join.editor = .order
            result.append(join)
        }
        return result + commonOptions(for: files)
    }

    func options(for file: FileInfo) -> [WheelOption] {
        let kind = MediaFormat.kind(of: file)
        guard kind.isMedia else { return [] }
        let source = MediaFormat.detect(file)

        var trim = option(.trim, "Cortar…", "scissors", kind.isVideo ? "Cortar el video" : "Cortar el audio")
        trim.editor = .trim
        var result = [trim]
        if kind.isVideo {
            // Herramientas de video con ventana.
            for (tool, title, symbol, label, editor) in [
                (Tool.crop, "Recortar…", "crop", "Recortar el encuadre del video", EditorKind.crop),
                (.speed, "Velocidad…", "gauge.with.dots.needle.67percent", "Cambiar la velocidad del video", .speed),
                (.frames, "Fotogramas…", "camera", "Guardar fotogramas como imágenes", .frames),
                (.split, "Dividir…", "film.stack", "Dividir el video en partes", .split),
            ] {
                var o = option(tool, title, symbol, label)
                o.editor = editor
                result.append(o)
            }
        }
        if !kind.isVideo {
            // Herramientas de audio con ventana, y la imagen de la onda (sin ventana).
            for (tool, title, symbol, label, editor) in [
                (Tool.normalize, "Normalizar…", "speaker.wave.3", "Normalizar el volumen", EditorKind.normalize),
                (.channels, "Canales…", "speaker.wave.2.circle", "Mono o estéreo y volumen de cada lado", .channels),
                (.bleep, "Pitido…", "waveform.badge.exclamationmark", "Tapar tramos con un pitido", .bleep),
            ] {
                var o = option(tool, title, symbol, label)
                o.editor = editor
                result.append(o)
            }
            result.append(option(.waveform, "Onda", "waveform", "Crear una imagen de la onda"))
        }
        if source != .flac {
            result.append(option(.compress, "Comprimir", "arrow.down.right.and.arrow.up.left",
                                 kind.isVideo ? "Comprimir el video" : "Comprimir el audio"))
        }
        if kind.isVideo {
            result.append(option(.mute, "Sin audio", "speaker.slash", "Quitar el sonido del video"))
        }
        return result
    }

    private func option(_ tool: Tool, _ title: String, _ symbol: String, _ label: String) -> WheelOption {
        WheelOption(id: "\(id).\(tool.rawValue)", providerID: id, title: title, symbol: symbol, accessibilityLabel: label)
    }

    // MARK: Unir videos

    func runBatch(_ option: WheelOption, on files: [FileInfo], context: JobContext) throws -> [URL]? {
        guard Tool(rawValue: action(of: option)) == .join else { return nil }
        let ffmpeg = try ExternalTool.require("ffmpeg", engine: "FFmpeg")
        let clips = context.parameters["ordered"] == 1 ? files
            : files.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        // El primer clip marca el tamaño y la fluidez del resultado; los demás se encajan con bandas negras si hace falta.
        let canvas = VideoCanvas.read(clips[0].url)
        let probes = clips.map { MediaProbe.read($0.url) }
        let total = probes.reduce(0) { $0 + $1.duration }

        var args = ["-hide_banner", "-nostdin", "-y"]
        for clip in clips { args += ["-i", clip.url.path] }
        // Silencio para los clips sin sonido (así el resultado tiene audio continuo).
        let silent = clips.count
        args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]

        var filters: [String] = []
        var inputs = ""
        for (i, probe) in probes.enumerated() {
            filters.append("[\(i):v:0]scale=\(canvas.width):\(canvas.height):force_original_aspect_ratio=decrease,"
                + "pad=\(canvas.width):\(canvas.height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(canvas.fps),format=yuv420p[v\(i)]")
            if probe.hasAudio {
                filters.append("[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)]")
            } else {
                filters.append("[\(silent):a]atrim=0:\(String(format: "%.3f", max(probe.duration, 0.04))),asetpts=PTS-STARTPTS[a\(i)]")
            }
            inputs += "[v\(i)][a\(i)]"
        }
        filters.append("\(inputs)concat=n=\(clips.count):v=1:a=1[v][a]")

        let temp = context.temporaryURL(ext: "mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
                 "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
                 "-progress", "pipe:1", "-nostats", temp.path]
        try ExternalTool.run(ffmpeg, arguments: args, context: context) { line in
            guard total > 0, line.hasPrefix("out_time_us="),
                  let micro = Double(line.dropFirst("out_time_us=".count)) else { return }
            context.report(micro / 1_000_000 / total)
        }
        let base = clips[0].url.deletingPathExtension().lastPathComponent
        return [try context.finalize(temp: temp, for: clips[0].url, ext: "mp4", tag: "unido", baseName: base)]
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let tool = Tool(rawValue: action(of: option)) else { throw ConversionError.unsupported }
        let ffmpeg = try ExternalTool.require("ffmpeg", engine: "FFmpeg")
        let probe = MediaProbe.read(file.url)
        let isVideo = MediaFormat.kind(of: file).isVideo
        // Formato de salida: el mismo que el original; si no lo conocemos (AVI, WMV…), MP4 o M4A.
        let source = MediaFormat.detect(file) ?? (isVideo ? .mp4 : .m4a)

        var inputArgs: [String] = []
        var recipe: [String]
        var ext = source.ext
        var duration = probe.duration
        let tag: String

        switch tool {
        case .trim:
            let start = max(0, context.parameters["start"] ?? 0)
            let end = context.parameters["end"] ?? probe.duration
            guard end > start else { throw ConversionError.message("El final del corte debe ir después del inicio.") }
            // "-ss" antes de "-i" salta rápido y, al recodificar, el corte es exacto.
            inputArgs = ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", end - start)]
            recipe = FFmpegRecipes.encode(to: source, quality: max(context.policy.quality, 0.9), options: context.policy.media)
            duration = end - start
            tag = "recorte"

        case .compress:
            tag = "comprimido"
            if isVideo {
                ext = "mp4"
                recipe = ["-map", "0:v:0", "-map", "0:a?",
                          "-vf", "scale='min(1920,iw)':-2",
                          "-c:v", "libx264", "-preset", "medium", "-crf", "28", "-pix_fmt", "yuv420p",
                          "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
            } else {
                switch source {
                case .wav, .aiff:
                    ext = "flac"   // compresión sin pérdida de calidad
                    recipe = ["-map", "0:a:0", "-vn", "-c:a", "flac", "-compression_level", "8"]
                case .mp3:
                    recipe = ["-map", "0:a:0", "-vn", "-c:a", "libmp3lame", "-b:a", "128k"]
                case .opus, .ogg:
                    recipe = ["-map", "0:a:0", "-vn", "-c:a", "libopus", "-b:a", "96k"]
                default:
                    ext = "m4a"
                    recipe = ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "128k"]
                }
            }

        case .join:
            throw ConversionError.message("Para unir videos, arrastra dos o más a la vez.")

        case .frames:
            return try saveFrames(file, ffmpeg: ffmpeg, context: context)

        case .waveform:
            return try waveformImage(file, ffmpeg: ffmpeg, context: context)

        case .normalize, .channels, .bleep:
            let p = context.parameters
            let filter: String
            switch tool {
            case .normalize:
                filter = AudioFilters.normalize(loudness: p["loudness"] ?? -16, range: p["range"] ?? 11, peak: p["peak"] ?? -1.5)
                tag = "normalizado"
            case .channels:
                let mono = (p["mono"] ?? 0) == 1
                filter = AudioFilters.channels(mono: mono, left: p["left"] ?? 1, right: p["right"] ?? 1,
                                               sourceChannels: AudioAnalysis.channelCount(file.url))
                tag = mono ? "mono" : "estereo"
            default:
                let ranges = (0..<Int(p["count"] ?? 0)).compactMap { i -> (Double, Double)? in
                    guard let s = p["s\(i)"], let e = p["e\(i)"] else { return nil }
                    return (s, e)
                }
                guard !ranges.isEmpty else { throw ConversionError.message("No has marcado ningún tramo para el pitido.") }
                filter = AudioFilters.bleep(ranges)
                tag = "pitido"
            }
            recipe = ["-af", filter] + FFmpegRecipes.encode(to: source, quality: max(context.policy.quality, 0.9), options: context.policy.media)

        case .split:
            return try split(file, ffmpeg: ffmpeg, probe: probe, source: source, context: context)

        case .speed:
            let speed = context.parameters["speed"] ?? 1
            guard speed > 0, speed != 1 else { throw ConversionError.message("Elige una velocidad distinta de 1×.") }
            // atempo admite de 0,5 a 2 en cada paso: 4× = 2 × 2; 0,25× = 0,5 × 0,5.
            var tempo: [String] = [], rest = speed
            while rest > 2 { tempo.append("atempo=2"); rest /= 2 }
            while rest < 0.5 { tempo.append("atempo=0.5"); rest /= 0.5 }
            tempo.append(String(format: "atempo=%.4f", rest))
            ext = "mp4"
            recipe = ["-map", "0:v:0", "-vf", String(format: "setpts=PTS/%.4f", speed),
                      "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
            recipe += probe.hasAudio ? ["-map", "0:a:0", "-af", tempo.joined(separator: ","), "-c:a", "aac", "-b:a", "192k"] : ["-an"]
            duration = probe.duration / speed
            tag = "velocidad-" + SpeedLabel.tag(speed)

        case .crop:
            let p = context.parameters
            let canvas = VideoCanvas.read(file.url)
            func even(_ v: Double) -> Int { max(2, Int(v) / 2 * 2) }
            let w = even((p["w"] ?? 1) * Double(canvas.width)), h = even((p["h"] ?? 1) * Double(canvas.height))
            let x = even((p["x"] ?? 0) * Double(canvas.width)), y = even((p["y"] ?? 0) * Double(canvas.height))
            ext = "mp4"
            recipe = ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "crop=\(w):\(h):\(x):\(y)",
                      "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                      "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
            tag = "encuadre"

        case .mute:
            guard probe.hasAudio else { throw ConversionError.message("Este video ya no tiene sonido.") }
            recipe = ["-map", "0:v:0", "-c:v", "copy", "-an"]
            tag = "sin-audio"
        }

        let temp = context.temporaryURL(ext: ext)
        defer { try? FileManager.default.removeItem(at: temp) }
        let args = ["-hide_banner", "-nostdin", "-y"] + inputArgs + ["-i", file.url.path] + recipe
            + ["-progress", "pipe:1", "-nostats", temp.path]
        try ExternalTool.run(ffmpeg, arguments: args, context: context) { line in
            guard duration > 0, line.hasPrefix("out_time_us="),
                  let micro = Double(line.dropFirst("out_time_us=".count)) else { return }
            context.report(micro / 1_000_000 / duration)
        }

        // Si "comprimir" no ahorra nada, mejor decirlo que crear un archivo más grande.
        if tool == .compress, let before = file.url.fileSize, let after = temp.fileSize, after >= before {
            throw ConversionError.message("“\(file.url.lastPathComponent)” ya está bien comprimido: no se pudo reducir más.")
        }
        return [try context.finalize(temp: temp, for: file.url, ext: ext, tag: tag)]
    }
}

extension MediaToolsConverter {
    /// Imagen PNG de la onda con el degradado de Fluxio y fondo transparente ("audio-onda.png").
    fileprivate func waveformImage(_ file: FileInfo, ffmpeg: URL, context: JobContext) throws -> [URL] {
        let mask = context.temporaryURL(ext: "png")
        defer { try? FileManager.default.removeItem(at: mask) }
        // La onda llena el alto aunque el audio sea suave: se sube hasta que el pico llegue arriba.
        let detect = (try? ExternalTool.captureStderr(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-i", file.url.path, "-map", "0:a:0",
                                                                          "-af", "volumedetect", "-f", "null", "-"])) ?? ""
        let maxDB = detect.components(separatedBy: "max_volume:").last
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") } ?? 0
        let gain = String(format: "volume=%.2fdB", max(0, -maxDB - 0.5))
        try ExternalTool.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y", "-i", file.url.path,
                                                 "-filter_complex", "[0:a:0]aformat=channel_layouts=mono,\(gain),showwavespic=s=2400x600:colors=white:scale=lin",
                                                 "-frames:v", "1", mask.path], context: context) { _ in }
        context.report(0.6)
        guard let src = CGImageSourceCreateWithURL(mask as CFURL, nil), let white = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let colored = WaveformPainter.paint(white) else { throw ConversionError.writeFailed("PNG") }
        let temp = context.temporaryURL(ext: "png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ImageIOHelpers.write(colored, as: .png, metadata: [:], quality: 1, to: temp, context: context)
        return [try context.finalize(temp: temp, for: file.url, ext: "png", tag: "onda")]
    }
}

/// Pinta la onda blanca con el degradado cian-violeta, sobre fondo transparente.
enum WaveformPainter {
    static func paint(_ white: CGImage) -> CGImage? {
        let size = CGSize(width: white.width, height: white.height)
        return MarkupRenderer.render(size: size, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            let rect = CGRect(origin: .zero, size: size)
            cg.saveGState()
            // La onda (blanca sobre transparente) hace de máscara.
            cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
            cg.clip(to: rect, mask: white)
            cg.scaleBy(x: 1, y: -1); cg.translateBy(x: 0, y: -size.height)
            NSGradient(colors: BackgroundStyle.gradients[0])?.draw(in: rect, angle: 0)
            cg.restoreGState()
        }
    }
}

/// "2×", "0,5×" → "2x", "0,5x" (para el nombre del archivo).
enum SpeedLabel {
    static func tag(_ speed: Double) -> String {
        (speed == speed.rounded() ? String(format: "%.0f", speed) : String(format: "%g", speed)).replacingOccurrences(of: ".", with: ",") + "x"
    }
}

extension MediaToolsConverter {
    /// Fotogramas exactos a tamaño completo, en PNG ("video-fotograma-0m01s60.png").
    fileprivate func saveFrames(_ file: FileInfo, ffmpeg: URL, context: JobContext) throws -> [URL] {
        let p = context.parameters
        let times = (0..<Int(p["count"] ?? 0)).compactMap { p["t\($0)"] }
        guard !times.isEmpty else { throw ConversionError.message("No has elegido ningún fotograma.") }
        var outputs: [URL] = []
        for (i, t) in times.enumerated() {
            try context.checkCancelled()
            let temp = context.temporaryURL(ext: "png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try ExternalTool.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-y", "-ss", String(format: "%.3f", t),
                                                     "-i", file.url.path, "-frames:v", "1", "-update", "1", temp.path],
                                 context: context) { _ in }
            let label = String(format: "fotograma-%dm%05.2fs", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                .replacingOccurrences(of: ".", with: ",")
            outputs.append(try context.finalize(temp: temp, for: file.url, ext: "png", tag: label))
            context.report(Double(i + 1) / Double(times.count))
        }
        return outputs
    }

    /// Cada parte se vuelve a codificar para que el corte sea exacto ("video-parte-1.mp4"…).
    fileprivate func split(_ file: FileInfo, ffmpeg: URL, probe: MediaProbe, source: MediaFormat, context: JobContext) throws -> [URL] {
        let p = context.parameters
        let cuts = (0..<Int(p["count"] ?? 0)).compactMap { p["c\($0)"] }.sorted()
        guard !cuts.isEmpty else { throw ConversionError.message("No has marcado ningún corte.") }
        let edges = [0] + cuts + [probe.duration]
        var outputs: [URL] = []
        for (i, (start, end)) in zip(edges, edges.dropFirst()).enumerated() where end - start > 0.05 {
            try context.checkCancelled()
            let temp = context.temporaryURL(ext: source.ext)
            defer { try? FileManager.default.removeItem(at: temp) }
            let recipe = FFmpegRecipes.encode(to: source, quality: max(context.policy.quality, 0.9), options: context.policy.media)
            let args = ["-hide_banner", "-nostdin", "-y", "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", end - start),
                        "-i", file.url.path] + recipe + ["-progress", "pipe:1", "-nostats", temp.path]
            let total = probe.duration
            try ExternalTool.run(ffmpeg, arguments: args, context: context) { line in
                guard total > 0, line.hasPrefix("out_time_us="), let micro = Double(line.dropFirst("out_time_us=".count)) else { return }
                context.report((start + micro / 1_000_000) / total)
            }
            outputs.append(try context.finalize(temp: temp, for: file.url, ext: source.ext, tag: "parte-\(i + 1)"))
        }
        return outputs
    }
}

/// Tamaño y fluidez del primer video (el "lienzo" al unir varios; también para recortar el encuadre).
struct VideoCanvas {
    var width = 1920, height = 1080
    var fps = "30"

    static func read(_ url: URL) -> VideoCanvas {
        var canvas = VideoCanvas()
        guard let ffprobe = ExternalTool.find("ffprobe"),
              let text = try? ExternalTool.capture(ffprobe, arguments: [
                "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,r_frame_rate:stream_side_data=rotation",
                "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let stream = (json["streams"] as? [[String: Any]])?.first
        else { return canvas }
        if let w = stream["width"] as? Int, let h = stream["height"] as? Int, w > 0, h > 0 {
            // Videos de móvil grabados en vertical: vienen girados 90°.
            let rotation = ((stream["side_data_list"] as? [[String: Any]])?.first?["rotation"] as? Int) ?? 0
            let turned = abs(rotation) % 180 == 90
            // libx264 necesita medidas pares.
            canvas.width = (turned ? h : w) / 2 * 2
            canvas.height = (turned ? w : h) / 2 * 2
        }
        if let rate = stream["r_frame_rate"] as? String, rate != "0/0" { canvas.fps = rate }
        return canvas
    }
}

extension URL {
    /// Tamaño del archivo en bytes.
    var fileSize: Int? {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
