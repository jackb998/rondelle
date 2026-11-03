import Foundation
import AVFoundation
import CoreVideo
// 2560×1440 noisy H.264 at a high bitrate with an AAC tone: big enough for 1080p/720p to make a smaller copy.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
let w = try! AVAssetWriter(outputURL: out, fileType: .mov)
let W = 2560, H = 1440, fps: Int32 = 30, frames = 90
let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000]])
let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
var asbd = AudioChannelLayout(); asbd.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
vi.expectsMediaDataInRealTime = false; ai.expectsMediaDataInRealTime = false
w.add(vi); w.add(ai)
w.startWriting(); w.startSession(atSourceTime: .zero)
var seed: UInt32 = 1
func videoFrame(_ f: Int) {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt32.self)
    let n = CVPixelBufferGetBytesPerRow(pb!) / 4 * H
    for i in 0..<n { seed = seed &* 1664525 &+ 1013904223; base[i] = seed }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
}
// 3 s of 440 Hz, 16-bit mono PCM handed to the AAC encoder.
let rate = 44100.0, total = Int(rate * 3)
var fmt = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
var desc: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &fmt, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
var pos = 0
func audioChunk() {
    let count = min(4096, total - pos)
    var samples = [Int16](repeating: 0, count: count)
    for i in 0..<count { samples[i] = Int16(8000 * sin(2 * .pi * 440 * Double(pos + i) / rate)) }
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block)
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count * 2) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: desc!, sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(pos), timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sb)
    ai.append(sb!)
    pos += count
}
var f = 0
while f < frames || pos < total {
    var did = false
    if f < frames && vi.isReadyForMoreMediaData { videoFrame(f); f += 1; did = true; if f == frames { vi.markAsFinished() } }
    if pos < total && ai.isReadyForMoreMediaData { audioChunk(); did = true; if pos >= total { ai.markAsFinished() } }
    if !did { usleep(1000) }
}
let sem = DispatchSemaphore(value: 0)
w.finishWriting { sem.signal() }
sem.wait()
print(w.status == .completed ? "ok" : "ERR \(String(describing: w.error))")
