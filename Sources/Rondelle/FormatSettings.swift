import AVFoundation
import Foundation

/// Settings → Conversioni: options for each output format, stored as "format.<FORMAT>.<option>".
/// Unset options keep the behaviour Rondelle had before these settings existed.
enum FormatSettings {
    /// The formats with their own page in Settings, by group (titles are the wheel's format names).
    static let groups: [(title: String, formats: [String])] = [
        ("Immagini", ["JPG", "PNG", "HEIC", "WebP", "TIFF", "GIF", "BMP"]),
        ("PDF", ["PDF → immagini"]),
        ("Video", ["MP4", "MOV", "M4V", "GIF animata"]),
        ("Audio", ["M4A", "MP3", "WAV", "AIFF"]),
        ("Fogli di calcolo", ["CSV"]),
    ]

    static let imageQualityFormats: Set<String> = ["JPG", "HEIC", "WebP"]
    static let videoFormats: Set<String> = ["MP4", "MOV", "M4V"]

    /// «JPG» was shown as «JPEG» until 0.9.6: its settings stay under the old name.
    static func key(_ format: String, _ option: String) -> String { "format.\(format == "JPG" ? "JPEG" : format).\(option)" }

    private static var defaults: UserDefaults { .standard }

    private static func value<T>(_ format: String, _ option: String, _ fallback: T) -> T {
        defaults.object(forKey: key(format, option)) as? T ?? fallback
    }

    static func reset(_ format: String) {
        for (k, _) in defaults.dictionaryRepresentation() where k.hasPrefix("format.\(format).") {
            defaults.removeObject(forKey: k)
        }
    }

    static func resetAll() {
        for (k, _) in defaults.dictionaryRepresentation() where k.hasPrefix("format.") { defaults.removeObject(forKey: k) }
    }

    // MARK: Images

    /// Longest side choices in pixels (0 = original size).
    static let sideChoices = [0, 3840, 2560, 1920, 1280, 1024]

    struct Image {
        let keepMetadata: Bool
        let maxSide: Int?
        let quality: CGFloat
    }

    /// Preferences can be written by other local programs: every value is brought back to the choices of
    /// Settings (D2), so a tampered one can't ask for 300 frames a second or a 1 000 000-pixel side.
    private static func choice<T: Equatable>(_ v: T, in choices: [T], else fallback: T) -> T {
        choices.contains(v) ? v : fallback
    }

    static func image(_ format: String) -> Image {
        let side = choice(value(format, "maxSide", 0), in: sideChoices, else: 0)
        let quality = value(format, "quality", Double(Settings.imageQuality))
        return Image(keepMetadata: value(format, "keepMetadata", true),
                     maxSide: side > 0 ? side : nil,
                     quality: CGFloat(quality.isFinite ? min(max(quality, 0.3), 1) : 0.9))
    }

    /// PDF → PNG/JPEG: resolution of the pages.
    static let dpiChoices = [72, 150, 300]
    static var pdfImagesDPI: CGFloat { CGFloat(choice(value("PDF → immagini", "dpi", 150), in: dpiChoices, else: 150)) }

    // MARK: Video

    enum VideoQuality: String, CaseIterable {
        /// No re-encoding when the format allows it (fast, same quality).
        case original, highest, p1080, p720, p480

        var preset: String {
            switch self {
            case .original: return AVAssetExportPresetPassthrough
            case .highest: return AVAssetExportPresetHighestQuality
            case .p1080: return AVAssetExportPreset1920x1080
            case .p720: return AVAssetExportPreset1280x720
            case .p480: return AVAssetExportPreset640x480
            }
        }

        var label: String {
            switch self {
            case .original: return L("Originale (senza ricodifica se possibile)")
            case .highest: return L("Massima (ricodifica)")
            case .p1080: return "1080p"
            case .p720: return "720p"
            case .p480: return "480p"
            }
        }
    }

    static func videoQuality(_ format: String) -> VideoQuality {
        VideoQuality(rawValue: value(format, "quality", VideoQuality.original.rawValue)) ?? .original
    }

    static func keepMetadata(_ format: String) -> Bool { value(format, "keepMetadata", true) }

    static let gifWidths = [320, 480, 640, 800]
    static let gifRates = [10, 15]
    static var gifWidth: Int { choice(value("GIF animata", "width", 480), in: gifWidths, else: 480) }
    static var gifFPS: Double { Double(choice(value("GIF animata", "fps", 10), in: gifRates, else: 10)) }

    // MARK: Audio

    enum MP3Quality: String, CaseIterable {
        case cbr320, vbr0, vbr2, cbr128

        var label: String {
            switch self {
            case .cbr320: return L("Massima (320 kbps)")
            case .vbr0: return L("Alta (VBR, circa 245 kbps)")
            case .vbr2: return L("Standard (VBR, circa 190 kbps)")
            case .cbr128: return L("Ridotta (128 kbps)")
            }
        }
    }

    static var mp3Quality: MP3Quality { MP3Quality(rawValue: value("MP3", "quality", MP3Quality.vbr2.rawValue)) ?? .vbr2 }

    // MARK: Spreadsheets

    /// CSV written with commas (international) or semicolons (Excel in Italian, French, German…).
    static var csvSeparator: Character { value("CSV", "separator", ",") == ";" ? ";" : "," }
    /// A UTF-8 mark at the start, so that Excel reads accents correctly.
    static var csvBOM: Bool { value("CSV", "bom", true) }

    /// WAV and AIFF: 16 or 24 bits per sample.
    static func bitDepth(_ format: String) -> Int { value(format, "bits", 16) == 24 ? 24 : 16 }
}
