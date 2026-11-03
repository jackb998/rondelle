import AVFoundation
import Foundation
import Speech

/// Subtitles from what is said in a video or an audio file, by macOS on this Mac (SpeechTranscriber, macOS 26 and later).
/// The language's model comes from Apple the first time, downloaded by macOS itself: Rondelle's own sandbox has no network.
@available(macOS 26.0, *)
enum Transcription {
    /// At most this long on one cue, and this many characters: two lines of what a subtitle should hold.
    private static let maxCueSeconds = 6.0
    private static let maxCueCharacters = 84
    /// A silence this long ends a cue.
    private static let pause = 0.7
    /// Peak under this (≈ −60 dB): nothing but silence.
    private static let silence: Int16 = 33

    static func subtitles(_ url: URL, language: TranslateLanguage) async throws -> [URL] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue)) else {
            throw OpError.unsupported(L("trascrizione in questa lingua su questo Mac"))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        // In the app's own folder: a copy of what is said in the file, gone at the end or at the next launch.
        let work = ArchiveOps.protectedZipWork.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let sound = try await extractAudio(url, format: format, to: work.appendingPathComponent("audio.caf"))

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results where result.isFinal { words += self.words(in: result.text) }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: sound)) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let words = try await collector.value
        try PDFOps.checkCancelled()
        guard !words.isEmpty else { throw OpError.failed(L("nessun parlato riconosciuto in «%@»", url.lastPathComponent)) }
        let out = FileNaming.output(for: url, ext: "srt")
        try SubtitleOps.srt(cues(from: words)).write(to: out, atomically: true, encoding: .utf8)
        return [out]
    }

    private struct Word { let text: String; let start: Double; let end: Double }

    private static func words(in text: AttributedString) -> [Word] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            let piece = String(text[run.range].characters)
            guard !piece.allSatisfy(\.isWhitespace) else { return nil }
            return Word(text: piece, start: range.start.seconds, end: range.end.seconds)
        }
    }

    private static func cues(from words: [Word]) -> [(start: Double, end: Double, text: String)] {
        var cues: [(start: Double, end: Double, text: String)] = []
        var text = "", start = 0.0, end = 0.0
        func flush() {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { cues.append((start, max(end, start + 0.5), clean)) }
            text = ""
        }
        for word in words {
            if !text.isEmpty, word.start - end > pause || word.end - start > maxCueSeconds || text.count + word.text.count > maxCueCharacters { flush() }
            if text.isEmpty { start = word.start }
            text += word.text
            end = word.end
            if let last = text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(last), text.count > 30 { flush() }
        }
        flush()
        return cues
    }

    /// The sound alone, in the format the transcriber wants: AVAudioFile can't read every video.
    private static func extractAudio(_ url: URL, format: AVAudioFormat?, to file: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { throw OpError.unreadable(url) }
        guard !tracks.isEmpty else { throw OpError.unsupported(L("nessun audio in «%@»", url.lastPathComponent)) }
        let rate = format?.sampleRate ?? 16_000
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw OpError.failed("lettura dell'audio") }
        reader.add(output)
        guard reader.startReading() else { throw OpError.unreadable(url) }
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true) else {
            throw OpError.failed("lettura dell'audio")
        }
        let target = try AVAudioFile(forWriting: file, settings: pcm.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var loudest: Int16 = 0
        while let sample = output.copyNextSampleBuffer() {
            try PDFOps.checkCancelled()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { continue }
            if let samples = buffer.int16ChannelData?[0] {
                for i in 0..<frames { loudest = max(loudest, samples[i] == .min ? .max : abs(samples[i])) }
            }
            try target.write(from: buffer)
        }
        guard reader.status == .completed else { throw OpError.unreadable(url) }
        // On silence the model makes up a word or two: nothing to transcribe is said plainly instead.
        guard loudest >= silence else { throw OpError.failed(L("nessun parlato riconosciuto in «%@»", url.lastPathComponent)) }
        return file
    }
}
