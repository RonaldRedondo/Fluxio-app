import Foundation

/// Convierte audio (MP3, M4A, WAV, FLAC, OGG, Opus, AIFF) y video (MP4, MOV, MKV, WebM, GIF) con ffmpeg.
struct MediaConverter: Converter {
    let id = "media.convert"
    let mode = WheelMode.convert

    private static let videoTargets: [MediaFormat] = [.mp4, .mov, .webm, .gif, .mkv, .avi, .apng]

    func options(for file: FileInfo) -> [WheelOption] {
        let kind = MediaFormat.kind(of: file)
        guard kind.isMedia else { return [] }
        let source = MediaFormat.detect(file)

        if kind.isVideo {
            var result = Self.videoTargets.filter { $0 != source }.map { option($0) }
            // Extraer solo el audio (mismo id que "convertir a MP3" para que funcione al mezclar audio y video).
            result.append(WheelOption(id: "\(id).mp3", providerID: id, title: "MP3 audio", symbol: "music.note",
                                      accessibilityLabel: "Extraer el audio en MP3"))
            result.append(WheelOption(id: "\(id).m4a", providerID: id, title: "M4A audio", symbol: "music.note.list",
                                      accessibilityLabel: "Extraer el audio en M4A", secondary: true))
            result.append(option(.subs).asSecondary)
            return result
        }
        return MediaFormat.allCases.filter { $0.isAudio && $0 != source }.map { option($0) }
    }

    private func option(_ format: MediaFormat) -> WheelOption {
        WheelOption(id: "\(id).\(format.rawValue)", providerID: id, title: format.title, symbol: format.symbol,
                    accessibilityLabel: format == .subs ? "Extraer los subtítulos en SRT" : "Convertir a \(format.title)",
                    secondary: !format.isPrimary)
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let target = MediaFormat(rawValue: String(option.id.dropFirst(id.count + 1))) else {
            throw ConversionError.unsupported
        }
        let ffmpeg = try ExternalTool.require("ffmpeg", engine: "FFmpeg")
        let probe = MediaProbe.read(file.url)

        // FFprobe no encuentra ni imagen ni sonido: el archivo está dañado o a medias (no es que falte la opción).
        if !probe.hasVideo && !probe.hasAudio {
            throw ConversionError.message("No pude leer “\(file.url.lastPathComponent)”: parece dañado o incompleto "
                                          + "(por ejemplo, una descarga que no terminó).")
        }
        if target == .subs && !probe.hasSubtitles {
            throw ConversionError.message("“\(file.url.lastPathComponent)” no lleva subtítulos dentro.")
        }
        if target.isAudio && !probe.hasAudio {
            throw ConversionError.message("“\(file.url.lastPathComponent)” no tiene sonido que extraer.")
        }
        if !target.isAudio && target != .subs && !probe.hasVideo {
            throw ConversionError.message("“\(file.url.lastPathComponent)” no tiene imagen: solo se puede pasar a formatos de audio.")
        }

        let temp = context.temporaryURL(ext: target.ext)
        do {
            // Primero intentamos copiar sin recodificar (instantáneo y sin pérdida). Si no se puede, recodificamos.
            if let copyArgs = FFmpegRecipes.streamCopy(to: target, probe: probe, options: context.policy.media) {
                do {
                    try encode(ffmpeg, file.url, copyArgs, temp, probe, context)
                } catch ConversionError.toolFailed {
                    try encode(ffmpeg, file.url, FFmpegRecipes.encode(to: target, quality: context.policy.quality, options: context.policy.media),
                               temp, probe, context)
                }
            } else {
                try encode(ffmpeg, file.url, FFmpegRecipes.encode(to: target, quality: context.policy.quality, options: context.policy.media),
                           temp, probe, context)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return [try context.finalize(temp: temp, for: file.url, ext: target.ext)]
    }

    private func encode(_ ffmpeg: URL, _ input: URL, _ recipe: [String], _ output: URL,
                        _ probe: MediaProbe, _ context: JobContext) throws {
        try context.checkCancelled()
        let args = ["-hide_banner", "-nostdin", "-y", "-i", input.path]
            + recipe
            + ["-progress", "pipe:1", "-nostats", output.path]
        try ExternalTool.run(ffmpeg, arguments: args, context: context) { line in
            // ffmpeg informa "out_time_us=12345678" (microsegundos procesados).
            guard probe.duration > 0, line.hasPrefix("out_time_us="),
                  let micro = Double(line.dropFirst("out_time_us=".count)) else { return }
            context.report(micro / 1_000_000 / probe.duration)
        }
    }
}

/// Qué contiene un archivo de audio/video (lo pregunta a ffprobe).
struct MediaProbe {
    var duration: Double = 0
    var videoCodec: String?
    var audioCodec: String?

    var hasSubtitles = false

    var hasVideo: Bool { videoCodec != nil }
    var hasAudio: Bool { audioCodec != nil }

    static func read(_ url: URL) -> MediaProbe {
        var probe = MediaProbe()
        guard let ffprobe = ExternalTool.find("ffprobe"),
              let text = try? ExternalTool.capture(ffprobe, arguments: [
                "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name:stream_disposition=attached_pic",
                "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
            // Sin ffprobe asumimos que tiene de todo; ffmpeg dará el error si no.
            probe.videoCodec = "?"; probe.audioCodec = "?"
            return probe
        }
        if let format = json["format"] as? [String: Any], let d = format["duration"] as? String {
            probe.duration = Double(d) ?? 0
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            let codec = stream["codec_name"] as? String ?? "?"
            // Las carátulas de los MP3 aparecen como "video": las ignoramos.
            let isCover = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
            if type == "video", !isCover, probe.videoCodec == nil { probe.videoCodec = codec }
            if type == "audio", probe.audioCodec == nil { probe.audioCodec = codec }
            if type == "subtitle" { probe.hasSubtitles = true }
        }
        return probe
    }
}

/// "Recetas" de ffmpeg para cada formato. Aquí se ajusta la calidad de audio y video.
enum FFmpegRecipes {

    /// Codificadores disponibles en el ffmpeg instalado (se consulta una vez).
    static let encoders: Set<String> = {
        guard let ffmpeg = ExternalTool.find("ffmpeg"),
              let text = try? ExternalTool.capture(ffmpeg, arguments: ["-hide_banner", "-encoders"]) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count >= 2 ? String(parts[1]) : nil
        })
    }()

    /// Copia directa de las pistas cuando el formato de destino las admite tal cual.
    /// Copia directa de las pistas cuando el formato de destino las admite tal cual
    /// y los Ajustes no piden cambiar resolución ni códec.
    static func streamCopy(to target: MediaFormat, probe: MediaProbe, options: MediaOptions = MediaOptions()) -> [String]? {
        let video = probe.videoCodec ?? ""
        let audio = probe.audioCodec
        guard options.resolution == .original, options.audioBitrate == 0 else { return nil }
        // Si se pidió un códec concreto, solo copiamos si el video ya está en ese códec.
        switch options.codec {
        case .original: break
        case .h264: guard video == "h264" else { return nil }
        case .hevc: guard video == "hevc" else { return nil }
        case .av1: guard video == "av1" else { return nil }
        }
        switch target {
        case .mkv:
            return ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        case .mp4, .mov:
            let videoOK = ["h264", "hevc", "av1"].contains(video)
            let audioOK = audio == nil || ["aac", "mp3", "alac"].contains(audio!) && !(target == .mp4 && audio == "alac")
            guard videoOK && audioOK else { return nil }
            var args = ["-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart"]
            if video == "hevc" { args += ["-tag:v", "hvc1"] }   // para que QuickTime lo abra
            return args
        default:
            return nil
        }
    }

    /// Filtro de tamaño: limita la altura (720p…) y deja ancho y alto en números pares (lo exigen los códecs).
    private static func scaleFilter(_ resolution: MediaOptions.Resolution) -> String {
        resolution == .original
            ? "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            : "scale=-2:'trunc(min(\(resolution.rawValue),ih)/2)*2'"
    }

    /// Códec de video para MP4, MOV y MKV según Ajustes → Video.
    private static func videoCodecArgs(_ options: MediaOptions, container: MediaFormat) -> [String] {
        let q = options.quality
        switch options.codec {
        case .original, .h264:
            let crf = q == .high ? "18" : q == .balanced ? "22" : "28"
            return ["-c:v", "libx264", "-preset", "fast", "-crf", crf, "-pix_fmt", "yuv420p"]
        case .hevc:
            let crf = q == .high ? "22" : q == .balanced ? "26" : "30"
            var args = ["-c:v", "libx265", "-preset", "fast", "-crf", crf, "-pix_fmt", "yuv420p"]
            if container != .mkv { args += ["-tag:v", "hvc1"] }   // para que QuickTime lo abra
            return args
        case .av1:
            let crf = q == .high ? "28" : q == .balanced ? "35" : "42"
            return ["-c:v", "libsvtav1", "-preset", "8", "-crf", crf, "-pix_fmt", "yuv420p"]
        }
    }

    /// Bitrate de audio: el de Ajustes, o el automático de cada formato.
    private static func bitrate(_ options: MediaOptions, default kbps: Int) -> [String] {
        ["-b:a", "\(options.audioBitrate > 0 ? options.audioBitrate : kbps)k"]
    }

    /// Recodificación completa.
    static func encode(to target: MediaFormat, quality: Double, options: MediaOptions = MediaOptions()) -> [String] {
        let audioOnly = ["-map", "0:a:0", "-vn"]
        // Calidad del ajuste (0.5…1) → escala VBR de MP3 (0 = mejor, 9 = peor).
        let mp3Quality = String(max(0, min(6, Int(((1 - quality) * 10).rounded()))))
        let size = ["-vf", scaleFilter(options.resolution)]

        switch target {
        case .mp3:
            return audioOnly + ["-c:a", "libmp3lame"]
                + (options.audioBitrate > 0 ? ["-b:a", "\(options.audioBitrate)k"] : ["-q:a", mp3Quality])
        case .m4a:  return audioOnly + ["-c:a", encoders.contains("aac_at") ? "aac_at" : "aac"] + bitrate(options, default: 256)
        case .wav:  return audioOnly + ["-c:a", "pcm_s16le"]
        case .flac: return audioOnly + ["-c:a", "flac"]
        case .aiff: return audioOnly + ["-c:a", "pcm_s16be"]
        case .opus: return audioOnly + ["-c:a", "libopus"] + bitrate(options, default: 160)
        case .aac:  return audioOnly + ["-c:a", encoders.contains("aac_at") ? "aac_at" : "aac"] + bitrate(options, default: 192)
        case .alac: return audioOnly + ["-c:a", "alac"]
        case .subs: return ["-map", "0:s:0", "-c:s", "srt"]
        case .avi:
            // MPEG-4 (Xvid) + MP3: la combinación que abren casi todos los reproductores antiguos.
            let q = options.quality == .high ? "2" : options.quality == .balanced ? "4" : "7"
            return ["-map", "0:v:0", "-map", "0:a?", "-vf", scaleFilter(options.resolution),
                    "-c:v", "mpeg4", "-q:v", q, "-vtag", "xvid", "-c:a", "libmp3lame"] + bitrate(options, default: 192)
        case .apng:
            // Como el GIF, pero con millones de colores y transparencia.
            let width = options.resolution == .p480 ? 480 : 640
            return ["-filter_complex", "[0:v:0]fps=12,scale='min(\(width),iw)':-1:flags=lanczos[out]",
                    "-map", "[out]", "-an", "-plays", "0", "-f", "apng"]
        case .ogg:
            // Vorbis si está disponible; si no, Opus dentro de .ogg (también estándar).
            if encoders.contains("libvorbis") && options.audioBitrate == 0 {
                return audioOnly + ["-c:a", "libvorbis", "-q:a", "6"]
            }
            return audioOnly + ["-c:a", encoders.contains("libvorbis") ? "libvorbis" : "libopus"] + bitrate(options, default: 160)
        case .mp4, .mov:
            return ["-map", "0:v:0", "-map", "0:a?"] + size + videoCodecArgs(options, container: target)
                + ["-c:a", "aac"] + bitrate(options, default: 192) + ["-movflags", "+faststart"]
        case .mkv:
            return ["-map", "0:v:0", "-map", "0:a?"] + size + videoCodecArgs(options, container: .mkv)
                + ["-c:a", "aac"] + bitrate(options, default: 192)
        case .webm:
            let crf = options.quality == .high ? "28" : options.quality == .balanced ? "32" : "38"
            return ["-map", "0:v:0", "-map", "0:a?"] + size
                + ["-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                   "-c:a", "libopus"] + bitrate(options, default: 128)
        case .gif:
            // 12 fotogramas por segundo, máximo 640 px de ancho (o menos si se eligió 480p), paleta optimizada.
            let width = options.resolution == .p480 ? 480 : 640
            return ["-filter_complex",
                    "[0:v:0]fps=12,scale='min(\(width),iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4[out]",
                    "-map", "[out]", "-an", "-loop", "0"]
        }
    }
}
