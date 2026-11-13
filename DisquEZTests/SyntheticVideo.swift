import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

// All fixtures are generated locally. Tests run in a dedicated simulator photo library.
enum SyntheticVideo {
    enum HDR { case hlg, dolbyVision }

    static func make(size: CGSize = CGSize(width: 1_920, height: 1_080), frames: Int = 24,
                     rotated: Bool = false, audio: Bool = false, solid: Bool = false,
                     frameDuration: CMTime = CMTime(value: 1, timescale: 30), hdr: HDR? = nil) async throws -> URL {
        precondition(!audio || frameDuration == CMTime(value: 1, timescale: 30))
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var properties: [String: Any] = [AVVideoAverageBitRateKey: solid ? 20_000 : 18_000_000]
        var settings: [String: Any] = [
            AVVideoCodecKey: hdr == nil ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        if let hdr {
            properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            properties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] =
                hdr == .dolbyVision ? kVTHDRMetadataInsertionMode_Auto : kVTHDRMetadataInsertionMode_None
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
        settings[AVVideoCompressionPropertiesKey] = properties
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        if rotated { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0) }
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr == nil ? kCVPixelFormatType_32BGRA
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(video)
        var audioFormat: CMAudioFormatDescription?
        var audioInput: AVAssetWriterInput?
        if audio {
            var stream = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &stream, layoutSize: 0,
                                                  layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                  extensions: nil, formatDescriptionOut: &audioFormat) == noErr else {
                throw NSError(domain: "SyntheticVideo", code: 1)
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adapter.pixelBufferPool!, &buffer) == kCVReturnSuccess,
                  let buffer else { throw NSError(domain: "SyntheticVideo", code: 2) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if hdr == nil {
                let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<Int(size.height) {
                    for x in 0..<Int(size.width) {
                        let offset = y * rowBytes + x * 4
                        pixels[offset] = solid ? 70 : UInt8(truncatingIfNeeded: x / 3 + frame * 7)
                        pixels[offset + 1] = solid ? 110 : UInt8(truncatingIfNeeded: y / 2 + frame * 3)
                        pixels[offset + 2] = solid ? 150 : UInt8(truncatingIfNeeded: (x + y) / 4 + frame * 11)
                        pixels[offset + 3] = 255
                    }
                }
            } else {
                fillHDR(buffer, frame: frame)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adapter.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))) else {
                throw writer.error ?? NSError(domain: "SyntheticVideo", code: 3)
            }
            if let audioInput, let audioFormat {
                while !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let sample = try makeAudio(format: audioFormat, frame: frame)
                guard audioInput.append(sample) else { throw writer.error! }
            }
        }
        video.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        return url
    }

    private static func fillHDR(_ buffer: CVPixelBuffer, frame: Int) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        let ambient = Data([0x00, 0x00, 0xc3, 0x50, 0x3d, 0x13, 0x40, 0x42])
        CVBufferSetAttachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey, ambient as CFData, .shouldPropagate)
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) {
                let level = 64 + (x * 3 + y * 2 + frame * 17) % 876
                luma[y * lumaStride + x] = UInt16(level) << 6
            }
        }
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                chroma[y * chromaStride + 2 * x] = UInt16(384 + (y + frame * 2) % 256) << 6
                chroma[y * chromaStride + 2 * x + 1] = UInt16(384 + (x + frame * 3) % 256) << 6
            }
        }
    }

    private static func makeAudio(format: CMAudioFormatDescription, frame: Int) throws -> CMSampleBuffer {
        let count = 1_600
        let samples = (0..<count).map { offset in
            Int16(sin(Double(frame * count + offset) * 2 * .pi * 440 / 48_000) * 8_000)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                  blockLength: count * 2, blockAllocator: kCFAllocatorDefault,
                                                  customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
                                                  flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw NSError(domain: "SyntheticVideo", code: 4)
        }
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: count * 2)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 48_000),
                                       decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                         sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                         sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                         sampleBufferOut: &sample) == noErr, let sample else {
            throw NSError(domain: "SyntheticVideo", code: 5)
        }
        return sample
    }
}
