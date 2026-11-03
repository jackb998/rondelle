import AVFoundation
import Foundation

/// «Peso…» for a video: re-encoded so that the file stays under the size asked. What it costs comes out of the picture:
/// the bit rate is worked out from the length, and the resolution comes down when that rate couldn't keep it sharp.
enum VideoFit {
    /// Under this a video isn't worth watching: the job says so instead of making it.
    static let minVideoBitRate = 80_000
    /// Bits per pixel per frame that H.264 needs for a decent picture; below it, fewer pixels look better.
    private static let minBitsPerPixel = 0.05
    /// Encoders overshoot, the more the harder the picture, and the container takes its share: each attempt corrects the
    /// aim by how far the last one landed.
    private static let attempts = 4

    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    static func fit(_ url: URL, maxBytes: Int) async throws -> [URL] {
        guard FileNaming.fileSize(url) > maxBytes else { throw OpError.alreadySmall }
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw OpError.unsupported(L("nessun video in «%@»", url.lastPathComponent)) }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw OpError.unreadable(url) }
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let rate = Double(try await video.load(.nominalFrameRate))
        let label = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
        let tooSmall = OpError.failed(L("impossibile scendere sotto %@ con un video di questa durata", label))
        guard natural.width >= 2, natural.height >= 2 else { throw OpError.unreadable(url) }

        let out = FileNaming.output(for: url, ext: "mp4", suffix: label)
        let temp = FileNaming.scratchName(next: out)
        FileNaming.reservations?.add(temp)
        var share = 0.93
        for _ in 0..<attempts {
            let bits = Double(maxBytes) * 8 * share / seconds
            let audioRate = audio == nil ? 0 : bits > 600_000 ? 128_000 : bits > 200_000 ? 96_000 : 48_000
            let videoRate = Int(bits) - audioRate
            guard videoRate >= minVideoBitRate else { throw tooSmall }
            let size = pictureSize(natural, bitRate: videoRate, frameRate: rate > 0 ? rate : 30)
            try? FileManager.default.removeItem(at: temp)
            try await encode(asset, video: video, audio: audio, to: temp, size: size, natural: natural, transform: transform, videoRate: videoRate, audioRate: audioRate)
            if FileNaming.fileSize(temp) <= maxBytes {
                try FileNaming.replace(out, with: temp)
                return [out]
            }
            share *= Double(maxBytes) / Double(max(FileNaming.fileSize(temp), 1)) * 0.93
        }
        try? FileManager.default.removeItem(at: temp)
        throw tooSmall
    }

    /// The largest of the usual sizes this bit rate can keep sharp; never larger than the source.
    private static func pictureSize(_ natural: CGSize, bitRate: Int, frameRate: Double) -> CGSize {
        let long = max(natural.width, natural.height)
        for side in [long, 1920, 1280, 960, 640, 426, 320] where side <= long {
            let k = side / long
            let w = natural.width * k, h = natural.height * k
            if Double(bitRate) / (Double(w * h) * frameRate) >= minBitsPerPixel || side == 320 {
                // Encoders want even sizes.
                return CGSize(width: max(2, (w / 2).rounded() * 2), height: max(2, (h / 2).rounded() * 2))
            }
        }
        return natural
    }

    private static func encode(_ asset: AVAsset, video: AVAssetTrack, audio: AVAssetTrack?, to file: URL, size: CGSize, natural: CGSize,
                               transform: CGAffineTransform, videoRate: Int, audioRate: Int) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = []   // nothing of the source's: no place, no device, no date

        let pictureOut = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        pictureOut.alwaysCopiesSampleData = false
        guard reader.canAdd(pictureOut) else { throw OpError.failed("lettura del video") }
        reader.add(pictureOut)
        let pictureIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoRate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel] as [String: Any],
        ])
        // The rotation stays a flag, as in the source; its offsets are in pixels of the picture.
        let k = size.width / natural.width
        pictureIn.transform = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: transform.tx * k, ty: transform.ty * k)
        pictureIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(pictureIn) else { throw OpError.failed("scrittura del video") }
        writer.add(pictureIn)

        var soundOut: AVAssetReaderOutput?
        var soundIn: AVAssetWriterInput?
        if let audio, audioRate > 0 {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: [audio], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioRate,
            ])
            if reader.canAdd(mix), writer.canAdd(input) {
                reader.add(mix)
                writer.add(input)
                soundOut = mix
                soundIn = input
            }
        }
        guard reader.startReading(), writer.startWriting() else { throw writer.error ?? reader.error ?? OpError.failed("codifica del video") }
        writer.startSession(atSourceTime: .zero)

        let stop = Stop()
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                let work: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(pictureOut, pictureIn)] + (soundOut.flatMap { out in soundIn.map { (out, $0) } }.map { [$0] } ?? [])
                for (index, (output, input)) in work.enumerated() {
                    let box = Pair(output: output, input: input)
                    group.addTask {
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            box.input.requestMediaDataWhenReady(on: DispatchQueue(label: "Rondelle.VideoFit.\(index)")) {
                                while box.input.isReadyForMoreMediaData {
                                    guard !stop.isSet, let sample = box.output.copyNextSampleBuffer(), box.input.append(sample) else {
                                        box.input.markAsFinished()
                                        done.resume()
                                        return
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } onCancel: {
            stop.set()
        }
        if stop.isSet {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        }
        let failed = reader.status == .failed
        await writer.finishWriting()
        guard !failed, writer.status == .completed else { throw writer.error ?? reader.error ?? OpError.failed("codifica del video") }
    }

    private struct Pair: @unchecked Sendable { let output: AVAssetReaderOutput; let input: AVAssetWriterInput }
}
