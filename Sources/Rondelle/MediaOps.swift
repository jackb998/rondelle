import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaOps {
    // MARK: Video

    /// Changes container, using passthrough (no re-encoding, instant) when the codecs allow it.
    static func convertVideo(_ url: URL, to fileType: AVFileType, ext: String) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let format = ext.uppercased()   // Settings → Conversioni → MP4 / MOV / M4V
        var preset = FormatSettings.videoQuality(format).preset
        if preset == AVAssetExportPresetPassthrough, let probe = AVAssetExportSession(asset: asset, presetName: preset),
           !probe.supportedFileTypes.contains(fileType) {
            preset = AVAssetExportPresetHighestQuality
        }
        let keep = FormatSettings.keepMetadata(format)
        return try await export(asset, from: url, preset: preset, fileType: fileType, ext: ext, suffix: nil) { session in
            if !keep { neutralizeMetadata(session) }
        }
    }

    /// The asset's metadata minus its position (ISO 6709 coordinates, accuracy, ©xyz…); nil when there is none
    /// to remove. Never an empty list: in passthrough that would mean «copy the original's».
    private static func metadataWithoutLocation(_ asset: AVAsset) async -> [AVMetadataItem]? {
        guard let items = try? await asset.load(.metadata) else { return nil }
        func isLocation(_ item: AVMetadataItem) -> Bool {
            let id = (item.identifier?.rawValue ?? "").lowercased()
            return id.contains("location") || id.contains("xyz") || item.commonKey == .commonKeyLocation
        }
        guard items.contains(where: isLocation) else { return nil }
        let kept = items.filter { !isLocation($0) }
        if !kept.isEmpty { return kept }
        let neutral = AVMutableMetadataItem()
        neutral.identifier = .commonIdentifierSoftware
        neutral.value = "Rondelle" as NSString
        return [neutral]
    }

    /// Replaces location, device, dates and other personal data with a single neutral item.
    private static func neutralizeMetadata(_ session: AVAssetExportSession) {
        // An empty list means "copy the original's" in passthrough: one neutral item replaces them all.
        let neutral = AVMutableMetadataItem()
        neutral.identifier = .commonIdentifierSoftware
        neutral.value = "Rondelle" as NSString
        session.metadata = [neutral]
        session.metadataItemFilter = .forSharing()   // location and personal data, wherever else they are
    }

    static func compressVideo(_ url: URL, preset: String, suffix: String) async throws -> [URL] {
        let outs = try await export(AVURLAsset(url: url), from: url, preset: preset, fileType: .mp4, ext: "mp4", suffix: suffix)
        if let out = outs.first, FileNaming.fileSize(out) >= FileNaming.fileSize(url) {
            try? FileManager.default.removeItem(at: out)
            throw OpError.notSmaller
        }
        return outs
    }

    static func extractAudio(_ url: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw OpError.unsupported(L("il video non ha una traccia audio"))
        }
        let keep = FormatSettings.keepMetadata("M4A")
        return try await export(asset, from: url, preset: AVAssetExportPresetAppleM4A,
                         fileType: .m4a, ext: "m4a", suffix: nil) { if !keep { neutralizeMetadata($0) } }
    }

    static func removeAudio(_ url: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw OpError.unsupported(L("nessuna traccia video"))
        }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OpError.failed(L("composizione video"))
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        track.preferredTransform = try await video.load(.preferredTransform)
        return try await export(composition, from: url, preset: AVAssetExportPresetPassthrough,
                                fileType: .mov, ext: "mov", suffix: L("senza audio"))
    }

    /// Frame from the middle of the video, saved as PNG.
    static func snapshot(_ url: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2))
        let out = FileNaming.output(for: url, ext: "png", suffix: "fotogramma")
        try ImageOps.write(image, to: out, type: .png)
        return [out]
    }

    /// Animated GIF of the first 20 seconds, 10 fps, longest side 480 px.
    static func gif(_ url: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw OpError.unsupported(L("video senza durata valida")) }
        let seconds = min(duration, 20)
        let fps = FormatSettings.gifFPS   // Settings → Conversioni → GIF animata
        let frames = max(Int(seconds * fps), 1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: FormatSettings.gifWidth, height: FormatSettings.gifWidth)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let out = FileNaming.output(for: url, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw OpError.failed(L("creazione della GIF"))
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<frames {
            let (image, _) = try await generator.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(dest, image, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw OpError.failed(L("scrittura della GIF"))
        }
        return [out]
    }

    /// 2× = twice as fast. Audio keeps its pitch.
    static func changeSpeed(_ url: URL, factor: Double, suffix: String) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            if track.mediaType == .video { copy.preferredTransform = try await track.load(.preferredTransform) }
        }
        composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor))
        return try await export(composition, from: url, preset: AVAssetExportPresetHighestQuality,
                                fileType: .mp4, ext: "mp4", suffix: suffix) { $0.audioTimePitchAlgorithm = .spectral }
    }

    /// Keeps only `range`, without re-encoding when the format allows it.
    static func trim(_ url: URL, range: CMTimeRange) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let isAudio = FileKind(url) == .audio
        let ext = url.pathExtension.lowercased()
        let (fileType, outExt): (AVFileType, String) = isAudio
            ? (ext == "m4a" ? (.m4a, "m4a") : ext == "wav" ? (.wav, "wav") : ext.hasPrefix("aif") ? (.aiff, "aiff") : (.m4a, "m4a"))
            : (ext == "mov" ? (.mov, "mov") : ext == "m4v" ? (.m4v, "m4v") : (.mp4, "mp4"))
        var preset = AVAssetExportPresetPassthrough
        if let probe = AVAssetExportSession(asset: asset, presetName: preset), !probe.supportedFileTypes.contains(fileType) {
            preset = isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        }
        return try await export(asset, from: url, preset: preset, fileType: preset == AVAssetExportPresetAppleM4A ? .m4a : fileType,
                                ext: preset == AVAssetExportPresetAppleM4A ? "m4a" : outExt, suffix: "tagliato") {
            $0.timeRange = range
        }
    }

    /// A copy without the hidden data: location, device make and model, dates, software, user data.
    /// Passthrough (no re-encoding): same quality, done in seconds.
    static func stripMetadata(_ url: URL) async throws -> [URL] {
        let ext = url.pathExtension.lowercased()
        let (fileType, outExt): (AVFileType, String) = ext == "mov" ? (.mov, "mov") : ext == "m4v" ? (.m4v, "m4v") : (.mp4, "mp4")
        return try await export(AVURLAsset(url: url), from: url, preset: AVAssetExportPresetPassthrough,
                                fileType: fileType, ext: outExt, suffix: L("senza metadati")) { session in
            // An empty list means "copy the original's" in passthrough: one neutral item replaces them all.
            let neutral = AVMutableMetadataItem()
            neutral.identifier = .commonIdentifierSoftware
            neutral.value = "Rondelle" as NSString
            session.metadata = [neutral]
            session.metadataItemFilter = .forSharing()   // location and personal data, wherever else they are
        }
    }

    /// Joins videos end to end, in filename order.
    static func join(_ urls: [URL]) async throws -> [URL] {
        let sorted = FileNaming.sortedNaturally(urls)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OpError.failed(L("composizione video"))
        }
        var cursor = CMTime.zero
        for (i, url) in sorted.enumerated() {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                try video.insertTimeRange(range, of: track, at: cursor)
                if i == 0 { video.preferredTransform = try await track.load(.preferredTransform) }
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insertTimeRange(range, of: track, at: cursor)
            }
            cursor = cursor + duration
        }
        if audio.segments.isEmpty { composition.removeTrack(audio) }
        return try await export(composition, from: sorted[0], preset: AVAssetExportPresetHighestQuality,
                                fileType: .mp4, ext: "mp4", suffix: "uniti")
    }

    // MARK: Audio

    /// Audio without the hidden data (title, artist, album, comments, cover, software, location…), same sound:
    /// MP3/AAC lose their ID3 and APE tags byte for byte, M4A is copied without re-encoding, uncompressed and
    /// FLAC files are rewritten in the same format and bit depth (lossless).
    static func stripAudioMetadata(_ url: URL) async throws -> [URL] {
        switch url.pathExtension.lowercased() {
        case "mp3", "aac":
            return [try stripTags(url)]
        case "m4a", "m4b", "mp4":
            return try await export(AVURLAsset(url: url), from: url, preset: AVAssetExportPresetPassthrough,
                                    fileType: .m4a, ext: "m4a", suffix: L("senza metadati")) { session in
                let neutral = AVMutableMetadataItem()   // an empty list would copy the original's
                neutral.identifier = .commonIdentifierSoftware
                neutral.value = "Rondelle" as NSString
                session.metadata = [neutral]
                session.metadataItemFilter = .forSharing()
            }
        case "wav", "aif", "aiff", "aifc", "caf", "flac":
            return [try rewriteSameFormat(url)]
        default:
            throw OpError.unsupported(L("«Metadati» per i file .%@", url.pathExtension))
        }
    }

    /// Copies an MP3/AAC stream without the ID3v2 tags at the start and the ID3v1, APE and ID3v2-footer tags at the end.
    private static func stripTags(_ url: URL) throws -> URL {
        let input = try SafeFile.openForReading(url)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        // Every read is freed at once: a file made of millions of tiny tags would otherwise pile them up (0.8.1-B1/B2).
        func bytes(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            guard offset + UInt64(count) <= size else { return [] }
            return try autoreleasepool {
                try input.seek(toOffset: offset)
                return Array(try input.read(upToCount: count) ?? Data())
            }
        }
        func syncsafe(_ b: ArraySlice<UInt8>) -> UInt64 { b.reduce(0) { $0 << 7 | UInt64($1 & 0x7F) } }
        var start: UInt64 = 0
        // Real files have one or two tags at each end: past 64 the file is refused (bounded time, 0.8.1-B1/B2),
        // never written with tags still inside it (0.8.2-M1).
        var rounds = 0
        func counted() throws {
            rounds += 1
            if rounds > 64 { throw OpError.failed(L("troppi tag di metadati (oltre 64): il file non è stato creato")) }
        }
        while true {   // ID3v2 at the start (there can be more than one)
            if Task.isCancelled { throw CancellationError() }
            let h = try bytes(start, 10)
            guard h.count == 10, h[0] == 0x49, h[1] == 0x44, h[2] == 0x33 else { break }   // "ID3"
            try counted()
            start += 10 + syncsafe(h[6..<10]) + (h[5] & 0x10 != 0 ? 10 : 0)
        }
        var end = size
        rounds = 0   // 64 for each end
        while end > start {   // tags at the end, in any order; every round shortens the audio
            if Task.isCancelled { throw CancellationError() }
            if end >= 128, try bytes(end - 128, 3) == Array("TAG".utf8) {
                try counted()
                end -= 128
                if end >= 227, try bytes(end - 227, 4) == Array("TAG+".utf8) { end -= 227 }
                continue
            }
            if end >= 32, try bytes(end - 32, 8) == Array("APETAGEX".utf8) {
                let footer = try bytes(end - 32, 32)
                let tagSize = UInt64(footer[12]) | UInt64(footer[13]) << 8 | UInt64(footer[14]) << 16 | UInt64(footer[15]) << 24
                let hasHeader = footer[23] & 0x80 != 0
                // The size counts the 32-byte footer: smaller is a damaged (or hostile) tag. Stopping there kept every
                // tag before it in the copy (0.8.3-T1): refuse instead.
                guard tagSize >= 32 else { throw OpError.failed(L("tag di metadati danneggiato: il file non è stato creato")) }
                try counted()
                end -= min(end - start, tagSize + (hasHeader ? 32 : 0))
                continue
            }
            if end >= 10, try bytes(end - 10, 3) == Array("3DI".utf8) {
                let footer = try bytes(end - 10, 10)
                try counted()
                end -= min(end - start, 20 + syncsafe(footer[6..<10]))
                continue
            }
            break
        }
        guard end > start else { throw OpError.failed(L("il file non contiene audio")) }
        let out = FileNaming.output(for: url, ext: url.pathExtension.lowercased(), suffix: L("senza metadati"))
        let output = try FileHandle(forWritingTo: out)
        defer { try? output.close() }
        try input.seek(toOffset: start)
        var left = end - start
        while left > 0 {
            if Task.isCancelled { throw CancellationError() }
            let chunk = try autoreleasepool { try input.read(upToCount: Int(min(left, 1 << 20))) ?? Data() }
            guard !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            left -= UInt64(chunk.count)
        }
        return out
    }

    /// Same format, sample rate, channels and bit depth: only the audio is written, no metadata chunks.
    private static func rewriteSameFormat(_ url: URL) throws -> URL {
        // FLAC records its source bit depth only in the format flags (1 = 16, 2 = 20, 3 = 24, 4 = 32 bit), and the
        // system encoder follows the samples it is given: 16-bit FLAC is read and written as 16-bit integers.
        let probe = try AVAudioFile(forReading: url)
        let description = probe.fileFormat.streamDescription.pointee
        let flac16 = description.mFormatID == kAudioFormatFLAC && description.mFormatFlags == 1
        let input = flac16 ? try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false) : probe
        let format = input.processingFormat
        let out = FileNaming.output(for: url, ext: url.pathExtension.lowercased(), suffix: L("senza metadati"))
        let output = try AVAudioFile(forWriting: out, settings: input.fileFormat.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 15) else { throw OpError.failed(L("buffer audio")) }
        while input.framePosition < input.length {
            if Task.isCancelled { throw CancellationError() }
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        return out
    }

    static func toM4A(_ url: URL, suffix: String? = nil) async throws -> [URL] {
        let keep = FormatSettings.keepMetadata("M4A")
        return try await export(AVURLAsset(url: url), from: url, preset: AVAssetExportPresetAppleM4A,
                                fileType: .m4a, ext: "m4a", suffix: suffix) { if !keep { neutralizeMetadata($0) } }
    }

    enum PCMFormat { case wav, aiff, flac }

    static func convertAudio(_ url: URL, to format: PCMFormat) throws -> [URL] {
        let input = try AVAudioFile(forReading: url)
        let fmt = input.processingFormat
        let ext: String
        var settings: [String: Any] = [
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
        ]
        switch format {
        case .wav, .aiff:
            ext = format == .wav ? "wav" : "aiff"
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = FormatSettings.bitDepth(format == .wav ? "WAV" : "AIFF")
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            ext = "flac"
            settings[AVFormatIDKey] = kAudioFormatFLAC
        }
        let out = FileNaming.output(for: url, ext: ext)
        do {
            let output = try AVAudioFile(forWriting: out, settings: settings,
                                         commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 15) else {
                throw OpError.failed(L("buffer audio"))
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return [out]
    }

    /// Peak-normalises to −1 dBFS.
    static func normalize(_ url: URL) throws -> [URL] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 15) else { throw OpError.failed(L("buffer audio")) }

        var peak: Float = 0
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for ch in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[ch][i])) }
            }
        }
        guard peak > 0 else { throw OpError.failed(L("il file è silenzioso")) }
        let gain = 0.891 / peak  // −1 dB

        input.framePosition = 0
        return try rewrite(url, suffix: "normalizzato", channels: format.channelCount, sampleRate: format.sampleRate) { output in
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
                for ch in 0..<Int(format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { data[ch][i] *= gain }
                }
                try output.write(from: buffer)
            }
        }
    }

    /// Mixes all channels down to one.
    static func mono(_ url: URL) throws -> [URL] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 15),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1 << 15) else {
            throw OpError.failed(L("buffer audio"))
        }
        let channels = Int(format.channelCount)
        return try rewrite(url, suffix: "mono", channels: 1, sampleRate: format.sampleRate) { output in
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0, let src = buffer.floatChannelData, let dst = mono.floatChannelData else { break }
                for i in 0..<Int(buffer.frameLength) {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[ch][i] }
                    dst[0][i] = sum / Float(channels)
                }
                mono.frameLength = buffer.frameLength
                try output.write(from: mono)
            }
        }
    }

    /// Writes processed audio in the source format when it is uncompressed, otherwise as AAC.
    private static func rewrite(_ url: URL, suffix: String, channels: AVAudioChannelCount, sampleRate: Double,
                                body: (AVAudioFile) throws -> Void) throws -> [URL] {
        let ext = url.pathExtension.lowercased()
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        let outExt: String
        switch ext {
        case "wav", "aif", "aiff", "caf":
            outExt = ext
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = ext.hasPrefix("aif")
            settings[AVLinearPCMIsNonInterleaved] = false
        case "flac":
            outExt = ext
            settings[AVFormatIDKey] = kAudioFormatFLAC
        default:
            outExt = "m4a"
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = channels == 1 ? 128_000 : 256_000
        }
        let out = FileNaming.output(for: url, ext: outExt, suffix: suffix)
        do {
            let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try body(output)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return [out]
    }

    // MARK: Export

    private static func export(_ asset: AVAsset, from source: URL, preset: String, fileType: AVFileType,
                               ext: String, suffix: String?,
                               configure: ((AVAssetExportSession) -> Void)? = nil) async throws -> [URL] {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw OpError.unsupported(L("questo file non può essere convertito con AVFoundation"))
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw OpError.unsupported(L("formato .%@ per questo file", ext))
        }
        // Settings → Privacy: the source's metadata without its position (0.8-C2); `configure` may still replace it.
        let withoutLocation = Settings.removeLocation ? await metadataWithoutLocation(asset) : nil
        let out = FileNaming.output(for: source, ext: ext, suffix: suffix)
        // AVFoundation won't overwrite the claimed (empty) file: export beside it, then move it into place.
        let temp = FileNaming.scratchName(next: out)
        FileNaming.reservations?.add(temp)
        session.outputURL = temp
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let withoutLocation { session.metadata = withoutLocation }
        configure?(session)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: out)
            throw session.error ?? OpError.failed("esportazione")
        }
        try FileNaming.replace(out, with: temp)
        return [out]
    }
}
