import Foundation
import UniformTypeIdentifiers

/// Formatos de audio y video.
enum MediaFormat: String, CaseIterable {
    // Audio
    case mp3, m4a, wav, flac, ogg, opus, aiff, aac, alac
    // Video
    case mp4, mov, mkv, webm, gif, avi, apng
    /// Extraer los subtítulos que lleva dentro un video (a SRT).
    case subs

    var isAudio: Bool {
        switch self {
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .aac, .alac: return true
        default: return false
        }
    }

    /// Los más usados van en la rueda principal; el resto, dentro de "Más…".
    var isPrimary: Bool { [.mp3, .m4a, .wav, .flac, .mp4, .mov, .webm, .gif].contains(self) }

    var ext: String {
        switch self {
        case .alac: return "m4a"   // ALAC (sin pérdida de Apple) va dentro de un .m4a
        case .subs: return "srt"
        default: return rawValue
        }
    }

    var title: String {
        switch self {
        case .opus: return "Opus"
        case .alac: return "ALAC"
        case .subs: return "Subtítulos"
        case .webm: return "WebM"
        default: return rawValue.uppercased()
        }
    }

    var symbol: String {
        switch self {
        case .mp3: return "music.note"
        case .m4a: return "music.note.list"
        case .wav: return "waveform"
        case .flac: return "hifispeaker"
        case .ogg: return "music.quarternote.3"
        case .opus: return "dot.radiowaves.forward"
        case .aiff: return "pianokeys"
        case .mp4: return "film"
        case .mov: return "play.rectangle"
        case .mkv: return "shippingbox"
        case .webm: return "globe"
        case .gif: return "photo.stack"
        case .aac: return "music.mic"
        case .alac: return "hifispeaker"
        case .avi: return "film.stack"
        case .apng: return "photo.on.rectangle.angled"
        case .subs: return "captions.bubble"
        }
    }

    /// Extensiones de archivo que reconocemos como cada formato.
    private var sourceExtensions: [String] {
        switch self {
        case .m4a: return ["m4a", "m4b"]
        case .alac, .apng, .subs: return []   // solo se usan como destino
        case .ogg: return ["ogg", "oga"]
        case .aiff: return ["aiff", "aif"]
        case .mp4: return ["mp4", "m4v"]
        default: return [rawValue]
        }
    }

    /// Formato de un archivo por su extensión (o `nil`).
    static func detect(_ file: FileInfo) -> MediaFormat? {
        let ext = file.url.pathExtension.lowercased()
        return allCases.first { $0.sourceExtensions.contains(ext) }
    }

    /// Otros formatos que ffmpeg lee aunque macOS no siempre los reconozca.
    private static let extraVideo = ["wmv", "flv", "f4v", "mpg", "mpeg", "ts", "m2ts", "mts", "3gp", "3g2", "ogv",
                                     "vob", "asf", "rm", "rmvb", "divx", "dv"]
    private static let extraAudio = ["wma", "amr", "ape", "wv", "ac3", "eac3", "dts", "mka", "tta", "dsf", "dff",
                                     "caf", "au", "oga", "mp2", "spx", "w64", "mid"]

    /// Si el archivo es audio o video que ffmpeg pueda leer (incluye AVI, WMV…).
    static func kind(of file: FileInfo) -> (isMedia: Bool, isVideo: Bool) {
        if let format = detect(file) {
            if format == .gif { return (false, false) }   // los GIF los trata el conversor de imágenes
            return (true, !format.isAudio)
        }
        let ext = file.url.pathExtension.lowercased()
        if extraVideo.contains(ext) || file.conforms(to: .movie) || file.conforms(to: .video) { return (true, true) }
        if extraAudio.contains(ext) || file.conforms(to: .audio) { return (true, false) }
        return (false, false)
    }
}
