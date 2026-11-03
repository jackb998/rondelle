import Accelerate
import AVFoundation
import CLame
import CoreGraphics
import CoreImage
import CWebP
import Foundation

/// WebP output with the bundled libwebp (ImageIO can read WebP but not write it).
/// It only ever sees pixels ImageIO has already decoded and checked: no outside file reaches it.
enum WebPEncoder {
    /// WEBP_MAX_DIMENSION.
    static let maxSide = 16_383
    /// libwebp needs ≈ 14 bytes per pixel even in low-memory mode, and its analysis pass can't be cancelled
    /// (A1/A2): 30 MP ≈ 0.5 GB and «Annulla» within ≈ 2.6 s; 50 MP was 0.8 GB and ≈ 6 s.
    static let maxPixels = 30_000_000

    /// `orientation` is the EXIF one of `image`: it is applied while drawing, so the pixels exist once.
    static func data(_ image: CGImage, quality: CGFloat, orientation: CGImagePropertyOrientation = .up) throws -> Data {
        let sideways = orientation.rawValue >= 5
        let w = sideways ? image.height : image.width, h = sideways ? image.width : image.height
        guard w <= maxSide, h <= maxSide else {
            throw OpError.unsupported(L("WebP ammette al massimo %@ pixel per lato (questa immagine è %@ × %@)", maxSide, w, h))
        }
        guard w * h <= maxPixels else {
            throw OpError.unsupported(L("in WebP al massimo %@ megapixel: riduci prima la foto (es. «50%%»)", maxPixels / 1_000_000))
        }
        var config = WebPConfig()
        var picture = WebPPicture()
        guard WebPConfigInit(&config) != 0, WebPPictureInit(&picture) != 0 else { throw OpError.failed(L("avvio del codificatore WebP")) }
        defer { WebPPictureFree(&picture) }
        config.quality = Float(min(max(quality, 0), 1) * 100)
        config.low_memory = 1   // libwebp's own option: far less memory on big photos, a little slower
        picture.width = Int32(w)
        picture.height = Int32(h)

        // Straight (not premultiplied) sRGB RGBA, drawn upright; it lives only until libwebp has converted it
        // to its own format, so it is gone before the encoding (the most memory-hungry part) starts.
        // These steps take seconds on big photos and libwebp's hook doesn't cover them: «Annulla» is checked
        // between each of them (A2).
        try PDFOps.checkCancelled()
        try autoreleasepool {
            let bytesPerRow = w * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
            try pixels.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw OpError.failed(L("conversione dei pixel per WebP"))
                }
                ctx.concatenate(CIImage(cgImage: image).orientationTransform(for: orientation))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                try PDFOps.checkCancelled()
                var v = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: bytesPerRow)
                vImageUnpremultiplyData_RGBA8888(&v, &v, vImage_Flags(kvImageNoFlags))
                try PDFOps.checkCancelled()
                guard WebPPictureImportRGBA(&picture, base.assumingMemoryBound(to: UInt8.self), Int32(bytesPerRow)) != 0 else {
                    throw OpError.failed(L("conversione dei pixel per WebP"))
                }
            }
        }

        try PDFOps.checkCancelled()
        // «Annulla»: libwebp asks this hook as it goes and stops when it returns 0 — but not during its first
        // analysis pass, which always runs to the end (≈ 2.6 s at 30 MP): one reason for `maxPixels`.
        picture.progress_hook = { _, _ in Task.isCancelled ? 0 : 1 }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let ok = withUnsafeMutablePointer(to: &writer) { pointer -> Int32 in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(pointer)
            return WebPEncode(&config, &picture)
        }
        guard ok != 0, let mem = writer.mem, writer.size > 0 else {
            if Task.isCancelled { throw CancellationError() }
            throw OpError.failed(L("codifica WebP (errore %@)", picture.error_code.rawValue))
        }
        return Data(bytes: mem, count: writer.size)
    }
}

/// MP3 output with the bundled LAME encoder, fed with samples AVFoundation has already decoded.
/// VBR quality 2 (about 190 kbit/s), no ID3 tags.
enum MP3Encoder {
    static func convert(_ url: URL) throws -> [URL] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat   // 32-bit float, one buffer per channel
        let channels = Int(format.channelCount)
        guard channels == 1 || channels == 2 else {
            throw OpError.unsupported(L("l'MP3 ammette solo audio mono o stereo (questo file ha %@ canali)", channels))
        }
        guard (8_000...192_000).contains(format.sampleRate) else {
            throw OpError.unsupported(L("frequenza di campionamento di %@ Hz", Int(format.sampleRate)))
        }
        guard let lame = lame_init() else { throw OpError.failed(L("avvio del codificatore MP3")) }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(format.sampleRate))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        switch FormatSettings.mp3Quality {   // Settings → Conversioni → MP3
        case .cbr320, .cbr128:
            lame_set_VBR(lame, vbr_off)
            lame_set_brate(lame, FormatSettings.mp3Quality == .cbr320 ? 320 : 128)
        case .vbr0, .vbr2:
            lame_set_VBR(lame, vbr_default)
            lame_set_VBR_quality(lame, FormatSettings.mp3Quality == .vbr0 ? 0 : 2)
        }
        lame_set_write_id3tag_automatic(lame, 0)
        lame_set_bWriteVbrTag(lame, 1)
        guard lame_init_params(lame) >= 0 else { throw OpError.failed(L("impostazioni del codificatore MP3")) }

        let frames: AVAudioFrameCount = 1 << 14
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw OpError.failed(L("buffer audio")) }
        // LAME's worst case: 1.25 × samples + 7200 bytes.
        var mp3 = [UInt8](repeating: 0, count: Int(frames) * 5 / 4 + 7_200)

        let out = FileNaming.output(for: url, ext: "mp3")
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        func emit(_ count: Int32) throws {
            guard count >= 0 else { throw OpError.failed(L("codifica MP3 (errore %@)", count)) }
            if count > 0 { try handle.write(contentsOf: mp3.prefix(Int(count))) }
        }

        while input.framePosition < input.length {
            if Task.isCancelled { throw CancellationError() }
            try input.read(into: buffer)
            let n = Int32(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            // A float WAV/CAF can carry NaN, infinities or huge values: LAME stops on an assertion with those
            // (the whole app would quit). Silence what isn't a number and clip the rest to full scale.
            for ch in 0..<channels {
                for i in 0..<Int(n) {
                    let v = data[ch][i]
                    data[ch][i] = v.isFinite ? min(max(v, -1), 1) : 0
                }
            }
            let left = data[0], right = channels == 2 ? data[1] : data[0]
            try emit(mp3.withUnsafeMutableBufferPointer {
                lame_encode_buffer_ieee_float(lame, left, right, n, $0.baseAddress, Int32($0.count))
            })
        }
        try emit(mp3.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32($0.count)) })

        // The VBR header (length, seek table) goes into the empty first frame LAME left at the start.
        let tagSize = mp3.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        if tagSize > 0, tagSize <= mp3.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: mp3.prefix(tagSize))
        }
        return [out]
    }
}
